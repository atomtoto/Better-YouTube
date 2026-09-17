import Foundation

/// Runs the download queue.
///
/// Transfers go through a *background* `URLSession`, which is the whole reason this is reliable:
/// iOS owns the transfer rather than the app, so it carries on with the app backgrounded, keeps
/// going if the app is killed, and relaunches the app when it finishes. Nothing here depends on
/// the user keeping a screen open.
///
/// The steps a download goes through, and what survives each of them:
///
/// 1. **Resolve** — ask the configured service where the media is. The answer is short-lived, so
///    it is used at once and re-asked for on every restart rather than trusted from the manifest.
/// 2. **Transfer** — a background task, progress written through to the manifest as it goes.
/// 3. **Install** — the finished file is moved into `Downloads/<id>/video.mp4` and the record
///    becomes playable. Only at that point does anything in the app treat the video as downloaded.
///
/// A transfer interrupted anywhere in there leaves resume data on disk and reads as paused, so the
/// next tap carries on from the bytes already fetched instead of starting again.
@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    /// Live progress, 0...1, for the transfers currently running. Kept apart from the store's
    /// records because it ticks many times a second: the manifest is only written at the coarse
    /// steps below, while this drives the bars.
    @Published private(set) var progress: [String: Double] = [:]

    /// Set when the app itself refused to start something — no service configured, no space. A
    /// failure the service reported lives on the record instead, where the retry button is.
    @Published var lastError: String?

    #if os(iOS)
    /// Called when iOS has finished delivering background events, handed over by the app
    /// delegate. Calling it is what lets the system stop holding the app awake.
    ///
    /// iOS only, and not for want of porting: the handshake exists because iOS *relaunches* a
    /// suspended app to tell it a transfer finished. A Mac app that started a transfer is still
    /// running when it lands, so there is nobody to hand anything back to.
    var backgroundCompletionHandler: (() -> Void)?
    #endif

    private static let sessionIdentifier = "com.atomtoto.BetterYouTube.downloads"
    /// Two at a time. Enough to keep a fast connection busy, few enough that a queue of ten
    /// doesn't leave every one of them crawling.
    private static let maxConcurrent = 2
    /// Never fill the disk: leave this much free whatever the user's own limit says.
    private static let freeSpaceFloor: Int64 = 500_000_000

    private let store = DownloadStore.shared
    private var session: URLSession!
    private let sessionDelegate = DownloadSessionDelegate()
    /// Video ids with a transfer currently running, and the tasks behind them.
    private var tasks: [String: URLSessionDownloadTask] = [:]
    /// Video ids whose media URL is being asked for. They hold a slot like a transfer does:
    /// without this the queue starts everything at once, since a resolve has no task yet.
    private var resolving: Set<String> = []
    /// Consecutive transport failures per video, which is what decides whether to try again.
    private var retries: [String: Int] = [:]

    private init() {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        #if os(iOS)
        // Lets iOS relaunch the app to tell it a transfer finished, rather than the app finding
        // out whenever it is next opened. The setting is iOS's alone — a Mac app is not
        // relaunched for a transfer because it was never suspended.
        configuration.sessionSendsLaunchEvents = true
        #endif
        // Downloads are asked for, not speculative, so they shouldn't wait for the system to
        // decide the moment is convenient.
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        // Whether a *particular* transfer may use mobile data is set per request, so changing the
        // setting takes effect on the next download instead of needing a new session.
        configuration.allowsCellularAccess = true

        session = URLSession(configuration: configuration, delegate: sessionDelegate, delegateQueue: nil)
        sessionDelegate.manager = self

        adoptTasksFromPreviousLaunch()
    }

    // MARK: - What the UI calls

    func isDownloading(_ videoId: String) -> Bool {
        store.state(for: videoId)?.isActive == true
    }

    /// Queues a video, or does nothing if it is already here. The caller doesn't have to check.
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

    /// Starts a failed or paused download over. Always re-resolves: a media URL from the last
    /// attempt has almost certainly expired, and a stale one fails in a way that looks like the
    /// service is broken.
    func retry(_ videoId: String) {
        guard let record = store.record(for: videoId), !record.state.isActive else { return }
        retries[videoId] = 0
        store.update(videoId) { $0.state = .queued }
        pump()
    }

    func pause(_ videoId: String) {
        guard let task = tasks[videoId] else {
            // Queued but not started: it never had a task, so stopping it is just a state change.
            store.update(videoId) { if $0.state.isActive { $0.state = .paused } }
            return
        }
        tasks[videoId] = nil
        progress[videoId] = nil
        task.cancel { data in
            guard let data else { return }
            try? FileManager.default.createDirectory(
                at: DownloadStore.folder(for: videoId),
                withIntermediateDirectories: true
            )
            try? data.write(to: DownloadStore.resumeDataURL(for: videoId), options: .atomic)
        }
        store.update(videoId) { $0.state = .paused }
        pump()
    }

    func resume(_ videoId: String) {
        guard let record = store.record(for: videoId), !record.state.isActive else { return }
        store.update(videoId) { $0.state = .queued }
        pump()
    }

    /// Stops a transfer and forgets the video entirely, folder and all.
    func remove(_ videoId: String) {
        tasks[videoId]?.cancel()
        tasks[videoId] = nil
        resolving.remove(videoId)
        progress[videoId] = nil
        retries[videoId] = nil
        store.remove(videoId)
        pump()
    }

    func removeAll() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        resolving.removeAll()
        progress.removeAll()
        retries.removeAll()
        store.removeAll()
    }

    /// Everything that is queued or running, stopped where it stands. For the app reset.
    func cancelAllTransfers() {
        for (videoId, task) in tasks {
            task.cancel()
            store.update(videoId) { $0.state = .paused }
        }
        tasks.removeAll()
        resolving.removeAll()
        progress.removeAll()
    }

    // MARK: - The queue

    /// Starts whatever can be started. Called after anything that could free a slot or add work.
    private func pump() {
        guard busyCount < Self.maxConcurrent else { return }

        let waiting = store.records
            .filter { $0.state == .queued }
            .sorted { $0.addedAt < $1.addedAt }

        for record in waiting {
            guard busyCount < Self.maxConcurrent else { return }
            guard tasks[record.id] == nil, !resolving.contains(record.id) else { continue }
            start(record)
        }
    }

    private var busyCount: Int { tasks.count + resolving.count }

    private func start(_ record: DownloadRecord) {
        let videoId = record.id
        // Claimed before the resolve goes out, so a second pump can't start the same video twice.
        resolving.insert(videoId)
        store.update(videoId) { $0.state = .resolving }

        // Resume data from an interrupted transfer skips the resolve entirely — it carries its
        // own URL, and the bytes already on disk are only worth anything against that URL.
        if let data = try? Data(contentsOf: DownloadStore.resumeDataURL(for: videoId)), !data.isEmpty {
            try? FileManager.default.removeItem(at: DownloadStore.resumeDataURL(for: videoId))
            resolving.remove(videoId)
            launch(session.downloadTask(withResumeData: data), for: videoId)
            return
        }

        let settings = DownloadSettings.shared
        let source = settings.snapshot
        let quality = record.quality
        let video = record.video

        Task { [weak self] in
            do {
                let media = try await DownloadResolver.shared.resolve(
                    video: video,
                    quality: quality,
                    source: source
                )
                self?.beginTransfer(videoId: videoId, media: media, wifiOnly: source.wifiOnly)
            } catch {
                self?.fail(videoId: videoId, reason: Self.describe(error), retryable: false)
            }
        }
    }

    private func beginTransfer(videoId: String, media: ResolvedMedia, wifiOnly: Bool) {
        resolving.remove(videoId)
        // Gone while the resolve was in flight.
        guard store.record(for: videoId) != nil else {
            pump()
            return
        }

        if let expected = media.byteCount, let problem = spaceProblem(for: expected) {
            fail(videoId: videoId, reason: problem.localizedDescription, retryable: false)
            return
        }

        var request = URLRequest(url: media.url)
        request.allowsCellularAccess = !wifiOnly
        request.timeoutInterval = 60

        store.update(videoId) { record in
            record.mediaURL = media.url
            if let expected = media.byteCount { record.totalBytes = expected }
        }

        launch(session.downloadTask(with: request), for: videoId)
    }

    private func launch(_ task: URLSessionDownloadTask, for videoId: String) {
        // How every delegate callback finds its way back to a record.
        task.taskDescription = videoId
        tasks[videoId] = task
        store.update(videoId) { $0.state = .downloading }
        progress[videoId] = store.record(for: videoId)?.fraction ?? 0
        task.resume()
    }

    /// Whether there is room for `bytes`, against both the device's free space and the ceiling
    /// set in Settings.
    private func spaceProblem(for bytes: Int64) -> DownloadError? {
        if let free = Self.freeDiskSpace(), bytes + Self.freeSpaceFloor > free {
            return .noSpace
        }
        if let limit = DownloadSettings.shared.storageLimitBytes {
            let used = store.bytesOnDisk()
            if used + bytes > limit {
                let limitText = ByteCountFormatter.string(fromByteCount: limit, countStyle: .file)
                return .overStorageLimit(
                    "This would take the Downloads folder past its \(limitText) limit. Raise the limit in Settings, or remove a download."
                )
            }
        }
        return nil
    }

    private static func freeDiskSpace() -> Int64? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    // MARK: - Reports from the session

    fileprivate func report(videoId: String, received: Int64, expected: Int64) {
        if expected > 0 {
            progress[videoId] = min(1, max(0, Double(received) / Double(expected)))
        }

        // Most services never say how big the file is, so this is usually the first moment the
        // size is known — and therefore the only chance to enforce the storage limit before the
        // whole thing has already been written.
        if expected > 0, store.record(for: videoId)?.totalBytes == 0,
           let problem = spaceProblem(for: expected) {
            tasks[videoId]?.cancel()
            fail(videoId: videoId, reason: problem.localizedDescription, retryable: false)
            return
        }

        // The manifest is only worth writing at the coarse steps: this arrives many times a
        // second, and a JSON file rewritten at that rate is how a download comes to cost more
        // battery than it saves.
        guard let record = store.record(for: videoId) else { return }
        let shouldPersist = expected != record.totalBytes
            || received - record.receivedBytes > 4_000_000
        guard shouldPersist else { return }

        store.update(videoId) { stored in
            stored.receivedBytes = received
            if expected > 0 { stored.totalBytes = expected }
        }
    }

    /// A transfer landed. The file is already parked in the staging folder by the delegate, which
    /// has to move it before it returns.
    fileprivate func finish(videoId: String, stagedAt staged: URL, byteCount: Int64) {
        tasks[videoId] = nil
        resolving.remove(videoId)
        progress[videoId] = nil
        retries[videoId] = nil

        guard let record = store.record(for: videoId) else {
            // Removed while it was still coming down: drop what arrived.
            try? FileManager.default.removeItem(at: staged)
            pump()
            return
        }

        do {
            try store.install(videoId, from: staged, byteCount: byteCount)
            Task { await store.cachePoster(for: record.video) }
        } catch {
            try? FileManager.default.removeItem(at: staged)
            fail(videoId: videoId, reason: "Couldn't save the file: \(error.localizedDescription)", retryable: false)
            return
        }
        pump()
    }

    /// A transfer stopped without landing.
    fileprivate func complete(videoId: String, error: Error?) {
        tasks[videoId] = nil
        resolving.remove(videoId)
        progress[videoId] = nil

        guard let error else { return }          // Success already went through `finish`.
        guard store.record(for: videoId) != nil else { pump(); return }

        let code = (error as NSError).code
        // Cancelling is how pause and remove are implemented; neither is a failure.
        if (error as NSError).domain == NSURLErrorDomain && code == NSURLErrorCancelled {
            pump()
            return
        }

        fail(videoId: videoId, reason: error.localizedDescription, retryable: Self.isTransient(code))
    }

    /// Marks a download failed — or, for the kind of failure that usually passes on its own,
    /// queues it to be tried again shortly.
    ///
    /// Only twice, and only for transport errors. A service answering "no" will answer "no" just
    /// as firmly in four seconds' time, and the user is better told than made to wait for it.
    private func fail(videoId: String, reason: String, retryable: Bool) {
        tasks[videoId] = nil
        resolving.remove(videoId)
        progress[videoId] = nil

        let attempt = retries[videoId] ?? 0
        if retryable && attempt < 2 {
            retries[videoId] = attempt + 1
            store.update(videoId) { $0.state = .queued }
            let delay = attempt == 0 ? 2.0 : 6.0
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                self?.pump()
            }
            return
        }

        retries[videoId] = nil
        store.update(videoId) { $0.state = .failed(reason) }
        pump()
    }

    private static func isTransient(_ code: Int) -> Bool {
        [
            NSURLErrorTimedOut,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorNotConnectedToInternet,
            NSURLErrorCannotConnectToHost,
            NSURLErrorDNSLookupFailed,
            NSURLErrorResourceUnavailable
        ].contains(code)
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// Picks up transfers iOS was still running when the app was last killed, so they show as
    /// live rather than as a queue that mysteriously stalled.
    private func adoptTasksFromPreviousLaunch() {
        session.getTasksWithCompletionHandler { [weak self] _, _, downloads in
            Task { @MainActor in
                guard let self else { return }
                for task in downloads {
                    guard let videoId = task.taskDescription,
                          self.store.record(for: videoId) != nil else {
                        task.cancel()
                        continue
                    }
                    guard task.state == .running || task.state == .suspended else { continue }
                    self.tasks[videoId] = task
                    self.store.update(videoId) { $0.state = .downloading }
                    if task.state == .suspended { task.resume() }
                }
                self.pump()
            }
        }
    }

    #if os(iOS)
    fileprivate func finishedBackgroundEvents() {
        backgroundCompletionHandler?()
        backgroundCompletionHandler = nil
    }
    #endif
}

/// The background session's delegate.
///
/// Separate from the manager, and off the main actor, because that is where `URLSession` delivers:
/// on a queue of its own, in a process iOS may have relaunched for the purpose. Each callback does
/// the one thing that cannot wait — moving the finished file out of the temporary location before
/// the method returns, which is the system's rule — and hands the rest to the main actor.
private final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate {
    /// Set immediately after the session is built. Weak, though in practice the manager is a
    /// singleton that outlives everything.
    weak var manager: DownloadManager?

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let videoId = downloadTask.taskDescription else { return }
        Task { @MainActor [weak self] in
            self?.manager?.report(
                videoId: videoId,
                received: totalBytesWritten,
                expected: totalBytesExpectedToWrite
            )
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didResumeAtOffset fileOffset: Int64,
        expectedTotalBytes: Int64
    ) {
        guard let videoId = downloadTask.taskDescription else { return }
        Task { @MainActor [weak self] in
            self?.manager?.report(videoId: videoId, received: fileOffset, expected: expectedTotalBytes)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let videoId = downloadTask.taskDescription else { return }

        // iOS deletes this file the moment the method returns, so the move happens here,
        // synchronously, rather than after a hop to the main actor.
        let staged = DownloadStore.staging.appendingPathComponent("\(videoId).tmp")
        let files = FileManager.default
        try? files.createDirectory(at: DownloadStore.staging, withIntermediateDirectories: true)
        try? files.removeItem(at: staged)
        do {
            try files.moveItem(at: location, to: staged)
        } catch {
            Task { @MainActor [weak self] in
                self?.manager?.complete(videoId: videoId, error: error)
            }
            return
        }

        let size = (try? staged.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        Task { @MainActor [weak self] in
            self?.manager?.finish(videoId: videoId, stagedAt: staged, byteCount: size)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let videoId = task.taskDescription else { return }

        // A cancel that produced resume data leaves it in the error; keeping it is what makes
        // "pause" resume from where it stopped even when the system was the one to stop it.
        if let failure = error as NSError?,
           let data = failure.userInfo[NSURLSessionDownloadTaskResumeData] as? Data, !data.isEmpty {
            try? FileManager.default.createDirectory(
                at: DownloadStore.folder(for: videoId),
                withIntermediateDirectories: true
            )
            try? data.write(to: DownloadStore.resumeDataURL(for: videoId), options: .atomic)
        }

        Task { @MainActor [weak self] in
            self?.manager?.complete(videoId: videoId, error: error)
        }
    }

    #if os(iOS)
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor [weak self] in
            self?.manager?.finishedBackgroundEvents()
        }
    }
    #endif
}
