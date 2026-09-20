import Foundation
#if os(iOS)
import UIKit
#endif

/// Local and server downloads share the same background transfer queue. Split local streams
/// are downloaded in sequence, persisted between stages, then muxed by AVFoundation.
@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()
    @Published private(set) var progress: [String: Double] = [:]
    @Published var lastError: String?

    #if os(iOS)
    var backgroundCompletionHandler: (() -> Void)?
    private var backgroundWork: [String: UIBackgroundTaskIdentifier] = [:]
    #endif

    private static let maxConcurrent = 2
    private let chunkSize: Int64
    private static let freeSpaceFloor: Int64 = 500_000_000
    private let store: DownloadStore
    private let resolve: (Video, DownloadQuality, DownloadSourceSnapshot) async throws -> ResolvedMedia
    private var session: URLSession!
    private let sessionDelegate = DownloadSessionDelegate()
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var work: [String: Task<Void, Never>] = [:]
    /// A removed/re-added video is a new attempt; late callbacks may never mutate it.
    private var generations: [String: UUID] = [:]
    private var retries: [String: Int] = [:]
    private var restoring = true

    init(
        store: DownloadStore? = nil,
        configuration: URLSessionConfiguration = .background(withIdentifier: "com.atomtoto.BetterYouTube.downloads"),
        chunkSize: Int64 = 4 * 1024 * 1024,
        resolve: @escaping (Video, DownloadQuality, DownloadSourceSnapshot) async throws -> ResolvedMedia = {
            try await DownloadResolver.shared.resolve(video: $0, quality: $1, source: $2)
        }
    ) {
        self.chunkSize = max(1, chunkSize)
        self.store = store ?? .shared
        self.resolve = resolve
        sessionDelegate.staging = self.store.paths.staging
        #if os(iOS)
        configuration.sessionSendsLaunchEvents = true
        #endif
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        configuration.allowsCellularAccess = true
        session = URLSession(configuration: configuration, delegate: sessionDelegate, delegateQueue: nil)
        sessionDelegate.manager = self
        adoptTasksFromPreviousLaunch()
    }

    func isDownloading(_ videoId: String) -> Bool { store.state(for: videoId)?.isActive == true }

    func download(_ video: Video) {
        guard store.record(for: video.id) == nil else { return }
        guard DownloadSettings.shared.isConfigured else {
            lastError = DownloadError.notConfigured.localizedDescription
            return
        }
        store.upsert(DownloadRecord(video: video, quality: DownloadSettings.shared.quality))
        Task { await store.cachePoster(for: video) }
        pump()
    }

    /// Explicit retry discards expired media links and partial tracks before resolving again.
    func retry(_ videoId: String) {
        guard let record = store.record(for: videoId), !record.state.isActive else { return }
        clearPartialFiles(videoId)
        retries[videoId] = nil
        store.update(videoId) {
            $0.state = .queued
            $0.transfer = nil
            $0.receivedBytes = 0
            $0.totalBytes = 0
        }
        pump()
    }

    func pause(_ videoId: String) {
        guard store.state(for: videoId)?.isActive == true else { return }
        work.removeValue(forKey: videoId)?.cancel()
        endBackgroundWork(videoId)
        let generation = UUID()
        generations[videoId] = generation
        store.update(videoId) { $0.state = .paused }
        progress[videoId] = nil
        if let task = tasks.removeValue(forKey: videoId) {
            if store.record(for: videoId)?.transfer?.usesByteRanges == true {
                // Completed chunks are durable; restart just the current chunk on Resume.
                task.cancel()
                pump()
                return
            }
            task.cancel { [weak self] data in
                Task { @MainActor in
                    guard let self, self.generations[videoId] == generation,
                          self.store.state(for: videoId) == .paused, let data else { return }
                    self.saveResumeData(data, videoId: videoId)
                }
            }
        }
        pump()
    }

    func resume(_ videoId: String) {
        guard let record = store.record(for: videoId), !record.state.isActive, !record.isReady else { return }
        store.update(videoId) { $0.state = .queued }
        pump()
    }

    func remove(_ videoId: String) {
        stop(videoId)
        store.remove(videoId)
        pump()
    }

    func removeAll() {
        for id in store.records.map(\.id) { stop(id) }
        store.removeAll()
    }

    private func stop(_ id: String) {
        generations[id] = UUID()
        work.removeValue(forKey: id)?.cancel()
        tasks.removeValue(forKey: id)?.cancel()
        retries[id] = nil
        progress[id] = nil
        endBackgroundWork(id)
    }

    private var busyCount: Int { tasks.count + work.count }

    private func pump() {
        guard !restoring else { return }
        for record in store.records.filter({ $0.state == .queued }).sorted(by: { $0.addedAt < $1.addedAt }) {
            guard busyCount < Self.maxConcurrent else { break }
            guard tasks[record.id] == nil, work[record.id] == nil else { continue }
            start(record)
        }
    }

    private func start(_ record: DownloadRecord) {
        let id = record.id
        let generation = UUID()
        generations[id] = generation
        let videoFile = store.paths.componentURL(for: id, audio: false)
        let audioFile = store.paths.componentURL(for: id, audio: true)
        if let transfer = record.transfer, transfer.usesByteRanges == true,
           let offset = transfer.offset, let total = transfer.currentByteCount, let url = record.mediaURL,
           offset >= 0, offset <= total,
           Self.size(of: store.paths.componentURL(for: id, audio: transfer.downloadingAudio)) == offset {
            if offset == total {
                componentFinished(id, generation: generation)
            } else {
                beginTransfer(id, url: url, wifiOnly: transfer.wifiOnly)
            }
            return
        }
        if record.transfer?.usesByteRanges != true, record.transfer?.audioURL != nil,
           FileManager.default.fileExists(atPath: videoFile.path),
           FileManager.default.fileExists(atPath: audioFile.path) {
            assemble(id, generation: generation)
            return
        }
        if let data = try? Data(contentsOf: store.paths.resumeDataURL(for: id)), !data.isEmpty {
            try? FileManager.default.removeItem(at: store.paths.resumeDataURL(for: id))
            launch(session.downloadTask(withResumeData: data), for: id)
            return
        }

        clearPartialFiles(id)
        store.update(id) {
            $0.state = .resolving
            $0.transfer = nil
            $0.receivedBytes = 0
            $0.totalBytes = 0
        }
        let source = DownloadSettings.shared.snapshot
        let resolver = resolve
        beginBackgroundWork(id)
        work[id] = Task { [weak self] in
            do {
                let media = try await resolver(record.video, record.quality, source)
                try Task.checkCancellation()
                guard let self, self.generations[id] == generation else { return }
                self.work[id] = nil
                self.endBackgroundWork(id)
                self.store.update(id) {
                    $0.transfer = DownloadTransfer(audioURL: media.audioURL, wifiOnly: source.wifiOnly,
                                                   usesByteRanges: media.usesByteRanges,
                                                   videoByteCount: media.byteCount, audioByteCount: media.audioByteCount,
                                                   offset: media.usesByteRanges ? 0 : nil)
                    $0.mediaURL = media.url
                }
                self.beginTransfer(id, url: media.url, byteCount: media.byteCount, wifiOnly: source.wifiOnly)
            } catch {
                guard let self, self.generations[id] == generation else { return }
                self.fail(id, error: error)
            }
        }
    }

    private func beginTransfer(_ id: String, url: URL, byteCount: Int64? = nil, wifiOnly: Bool) {
        guard store.record(for: id) != nil else { pump(); return }
        if let size = byteCount, let error = spaceProblem(for: size) { fail(id, error: error); return }
        var request = URLRequest(url: url)
        request.allowsCellularAccess = !wifiOnly
        request.allowsExpensiveNetworkAccess = !wifiOnly
        request.timeoutInterval = 60
        let transfer = store.record(for: id)?.transfer
        if transfer?.usesByteRanges == true, let total = transfer?.currentByteCount {
            let start = transfer?.offset ?? 0
            guard start < total else { fail(id, error: DownloadError.noMedia); return }
            let end = start + min(chunkSize, total - start) - 1
            request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        }
        store.update(id) {
            $0.mediaURL = url
            $0.receivedBytes = transfer?.offset ?? 0
            $0.totalBytes = transfer?.usesByteRanges == true ? (transfer?.currentByteCount ?? 0) : (byteCount ?? 0)
        }
        launch(session.downloadTask(with: request), for: id)
    }

    private func launch(_ task: URLSessionDownloadTask, for id: String) {
        task.taskDescription = id
        tasks[id] = task
        store.update(id) { $0.state = .downloading }
        progress[id] = store.record(for: id)?.fraction ?? 0
        task.resume()
    }

    private func accepts(_ task: URLSessionTask) -> String? {
        guard let id = task.taskDescription, store.record(for: id) != nil else { return nil }
        // A background event may arrive before getTasksWithCompletionHandler at launch.
        if restoring, generations[id] == nil, tasks[id] == nil, let download = task as? URLSessionDownloadTask {
            tasks[id] = download
            generations[id] = UUID()
        }
        guard tasks[id]?.taskIdentifier == task.taskIdentifier else { return nil }
        return id
    }

    fileprivate func report(task: URLSessionDownloadTask, received: Int64, expected: Int64) {
        guard let id = accepts(task), let record = store.record(for: id) else { return }
        let offset = record.transfer?.usesByteRanges == true ? (record.transfer?.offset ?? 0) : 0
        let total = record.transfer?.usesByteRanges == true ? (record.transfer?.currentByteCount ?? expected) : expected
        if total > 0 {
            let fraction = min(1, max(0, Double(offset + received) / Double(total)))
            progress[id] = record.transfer?.audioURL == nil ? fraction
                : (record.transfer?.downloadingAudio == true ? 0.8 + fraction * 0.15 : fraction * 0.8)
        }
        guard total != record.totalBytes || offset + received - record.receivedBytes > 1_000_000 else { return }
        // The existing partial video is included in bytesOnDisk while the audio arrives.
        if let error = spaceProblem(for: max(received, expected), remaining: max(0, expected - received)) {
            task.cancel()
            fail(id, error: error)
            return
        }
        store.update(id) {
            $0.receivedBytes = offset + received
            if total > 0 { $0.totalBytes = total }
        }
    }

    fileprivate func finish(task: URLSessionDownloadTask, staged: URL, byteCount: Int64) {
        guard let id = accepts(task), let record = store.record(for: id) else {
            try? FileManager.default.removeItem(at: staged)
            return
        }
        tasks[id] = nil
        let generation = generations[id] ?? UUID()
        generations[id] = generation
        do {
            // A download with no progress callback still has to respect the quota.
            store.invalidateSize()
            if let error = spaceProblem(for: byteCount, remaining: 0, excludingOnDisk: byteCount) { throw error }
            if let transfer = record.transfer, transfer.usesByteRanges == true {
                defer { try? FileManager.default.removeItem(at: staged) }
                try appendChunk(id, transfer: transfer, response: task.response, staged: staged, byteCount: byteCount)
                componentFinished(id, generation: generation)
            } else if let transfer = record.transfer, let audioURL = transfer.audioURL {
                let destination = store.paths.componentURL(for: id, audio: transfer.downloadingAudio)
                try FileManager.default.createDirectory(at: store.paths.folder(for: id), withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: staged, to: destination)
                store.invalidateSize()
                if transfer.downloadingAudio {
                    assemble(id, generation: generation)
                } else {
                    store.update(id) { $0.transfer?.downloadingAudio = true }
                    beginTransfer(id, url: audioURL, wifiOnly: transfer.wifiOnly)
                }
            } else {
                validateAndInstall(id, staged: staged, byteCount: byteCount, generation: generation)
            }
        } catch {
            try? FileManager.default.removeItem(at: staged)
            fail(id, error: error)
        }
    }

    private func appendChunk(_ id: String, transfer: DownloadTransfer, response: URLResponse?, staged: URL, byteCount: Int64) throws {
        let offset = transfer.offset ?? 0
        guard let total = transfer.currentByteCount,
              let http = response as? HTTPURLResponse, http.statusCode == 206,
              let range = MediaByteRange(header: http.value(forHTTPHeaderField: "Content-Range")),
              range.start == offset, range.total == total,
              range.end == offset + min(chunkSize, total - offset) - 1,
              byteCount == range.end - range.start + 1 else {
            throw DownloadError.service("The media server returned an incomplete or unexpected byte range. Retry the download.")
        }
        let destination = store.paths.componentURL(for: id, audio: transfer.downloadingAudio)
        try FileManager.default.createDirectory(at: store.paths.folder(for: id), withIntermediateDirectories: true)
        if offset == 0 {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: staged, to: destination)
        } else {
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            // A crash between appending a chunk and persisting its offset is safe to replay.
            try output.truncate(atOffset: UInt64(offset))
            try output.seek(toOffset: UInt64(offset))
            let input = try FileHandle(forReadingFrom: staged)
            defer { try? input.close() }
            while let data = try input.read(upToCount: 256 * 1024), !data.isEmpty {
                try output.write(contentsOf: data)
            }
            try output.synchronize()
        }
        store.invalidateSize()
        store.update(id) {
            $0.transfer?.offset = range.end + 1
            $0.receivedBytes = range.end + 1
            $0.totalBytes = total
        }
    }

    private func componentFinished(_ id: String, generation: UUID) {
        guard let record = store.record(for: id), let transfer = record.transfer,
              let total = transfer.currentByteCount, let offset = transfer.offset else { return }
        if offset < total {
            guard let url = record.mediaURL else { fail(id, error: DownloadError.noMedia); return }
            beginTransfer(id, url: url, wifiOnly: transfer.wifiOnly)
        } else if let audioURL = transfer.audioURL, !transfer.downloadingAudio {
            store.update(id) { $0.transfer?.downloadingAudio = true; $0.transfer?.offset = 0 }
            beginTransfer(id, url: audioURL, wifiOnly: transfer.wifiOnly)
        } else if transfer.audioURL != nil {
            assemble(id, generation: generation)
        } else {
            validateAndInstall(id, staged: store.paths.componentURL(for: id, audio: false), byteCount: total, generation: generation)
        }
    }

    private func assemble(_ id: String, generation: UUID) {
        let video = store.paths.componentURL(for: id, audio: false)
        let audio = store.paths.componentURL(for: id, audio: true)
        let bytes = Self.size(of: video) + Self.size(of: audio)
        // Both inputs and output coexist until the atomic install completes.
        if let error = spaceProblem(for: bytes) { fail(id, error: error); return }
        let output = store.paths.staging.appendingPathComponent("\(UUID().uuidString).mp4")
        store.update(id) { $0.state = .processing }
        progress[id] = 0.95
        beginBackgroundWork(id)
        work[id] = Task { [weak self] in
            defer { try? FileManager.default.removeItem(at: output) }
            do {
                try await DownloadMediaAssembler.merge(video: video, audio: audio, output: output)
                try Task.checkCancellation()
                guard let self, self.generations[id] == generation else { return }
                try self.install(id, staged: output, byteCount: Self.size(of: output))
            } catch {
                guard let self, self.generations[id] == generation else { return }
                self.fail(id, error: error)
            }
        }
    }

    private func validateAndInstall(_ id: String, staged: URL, byteCount: Int64, generation: UUID) {
        store.update(id) { $0.state = .processing }
        beginBackgroundWork(id)
        work[id] = Task { [weak self] in
            defer { try? FileManager.default.removeItem(at: staged) }
            do {
                try await DownloadMediaAssembler.validate(staged)
                try Task.checkCancellation()
                guard let self, self.generations[id] == generation else { return }
                try self.install(id, staged: staged, byteCount: byteCount)
            } catch {
                guard let self, self.generations[id] == generation else { return }
                self.fail(id, error: error)
            }
        }
    }

    private func install(_ id: String, staged: URL, byteCount: Int64) throws {
        try store.install(id, from: staged, byteCount: byteCount)
        clearPartialFiles(id)
        work[id] = nil
        progress[id] = nil
        retries[id] = nil
        endBackgroundWork(id)
        pump()
    }

    fileprivate func complete(task: URLSessionTask, error: Error?) {
        // Successful completion follows finish, which may already have started the next stage.
        guard let error, let id = accepts(task) else { return }
        if store.record(for: id)?.transfer?.usesByteRanges != true,
           let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            saveResumeData(data, videoId: id)
        }
        let failure = error as NSError
        let transient = failure.domain == NSURLErrorDomain && [
            NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet,
            NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed, NSURLErrorResourceUnavailable
        ].contains(failure.code)
        let attempt = retries[id] ?? 0
        if transient && attempt < 2 {
            tasks[id] = nil
            retries[id] = attempt + 1
            let generation = generations[id]
            work[id] = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(attempt == 0 ? 2 : 6)) } catch { return }
                guard let self, self.generations[id] == generation else { return }
                self.work[id] = nil
                self.store.update(id) { $0.state = .queued }
                self.pump()
            }
        } else {
            fail(id, error: error)
        }
    }

    private func fail(_ id: String, error: Error) {
        tasks[id] = nil
        work[id] = nil
        progress[id] = nil
        endBackgroundWork(id)
        store.update(id) { $0.state = .failed(error.localizedDescription) }
        pump()
    }

    private func clearPartialFiles(_ id: String) {
        for url in [store.paths.resumeDataURL(for: id), store.paths.componentURL(for: id, audio: false), store.paths.componentURL(for: id, audio: true)] {
            try? FileManager.default.removeItem(at: url)
        }
        store.invalidateSize()
    }

    private func saveResumeData(_ data: Data, videoId: String) {
        guard !data.isEmpty else { return }
        try? FileManager.default.createDirectory(at: store.paths.folder(for: videoId), withIntermediateDirectories: true)
        try? data.write(to: store.paths.resumeDataURL(for: videoId), options: .atomic)
    }

    private static func size(of url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    private func spaceProblem(for bytes: Int64, remaining: Int64? = nil, excludingOnDisk: Int64 = 0) -> DownloadError? {
        let free = try? store.paths.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        if let free, (remaining ?? bytes) + Self.freeSpaceFloor > free { return .noSpace }
        if let limit = DownloadSettings.shared.storageLimitBytes, store.bytesOnDisk() - excludingOnDisk + bytes > limit {
            return .overStorageLimit("This would exceed the Downloads storage limit. Raise it in Settings or remove a download. Assembling separate tracks also needs temporary space.")
        }
        return nil
    }

    private func adoptTasksFromPreviousLaunch() {
        session.getTasksWithCompletionHandler { [weak self] _, _, downloads in
            Task { @MainActor in
                guard let self else { return }
                for task in downloads where task.state == .running || task.state == .suspended {
                    guard let id = task.taskDescription, self.store.record(for: id) != nil,
                          self.work[id] == nil,
                          self.tasks[id] == nil || self.tasks[id]?.taskIdentifier == task.taskIdentifier else {
                        task.cancel()
                        continue
                    }
                    self.tasks[id] = task
                    if self.generations[id] == nil { self.generations[id] = UUID() }
                    self.store.update(id) { $0.state = .downloading }
                    if task.state == .suspended { task.resume() }
                }
                self.restoring = false
                self.pump()
            }
        }
    }

    private func beginBackgroundWork(_ id: String) {
        #if os(iOS)
        endBackgroundWork(id)
        backgroundWork[id] = UIApplication.shared.beginBackgroundTask(withName: "Finish download") { [weak self] in
            Task { @MainActor in self?.pause(id) }
        }
        #endif
    }

    private func endBackgroundWork(_ id: String) {
        #if os(iOS)
        if let token = backgroundWork.removeValue(forKey: id), token != .invalid {
            UIApplication.shared.endBackgroundTask(token)
        }
        #endif
    }

    #if os(iOS)
    fileprivate func finishedBackgroundEvents() {
        backgroundCompletionHandler?()
        backgroundCompletionHandler = nil
    }
    #endif
}

private final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate {
    weak var manager: DownloadManager?
    var staging = DownloadStore.staging

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        Task { @MainActor [weak self] in
            self?.manager?.report(task: downloadTask, received: totalBytesWritten, expected: totalBytesExpectedToWrite)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
        Task { @MainActor [weak self] in
            self?.manager?.report(task: downloadTask, received: fileOffset, expected: expectedTotalBytes)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // URLSession treats an HTTP error page as a successful download. Never install one.
        if let response = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(response.statusCode) {
            Task { @MainActor [weak self] in
                self?.manager?.complete(task: downloadTask, error: DownloadError.http(response.statusCode))
            }
            return
        }
        // Move synchronously: URLSession removes its temporary file as soon as this returns.
        let staged = staging.appendingPathComponent("\(UUID().uuidString).tmp")
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: location, to: staged)
            let size = Int64((try? staged.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            Task { @MainActor [weak self] in
                self?.manager?.finish(task: downloadTask, staged: staged, byteCount: size)
            }
        } catch {
            Task { @MainActor [weak self] in self?.manager?.complete(task: downloadTask, error: error) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        Task { @MainActor [weak self] in self?.manager?.complete(task: task, error: error) }
    }

    #if os(iOS)
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor [weak self] in self?.manager?.finishedBackgroundEvents() }
    }
    #endif
}
