import Foundation

@MainActor
final class WatchDownloads: ObservableObject {
    static let shared = WatchDownloads()

    struct Record: Codable, Identifiable {
        let video: WatchVideo
        let fileExtension: String
        let savedAt: Date
        var id: String { video.id }
    }

    @Published private(set) var records: [Record] = []
    @Published private(set) var downloadingID: String?
    @Published private(set) var progress: Double = 0
    @Published var message: String?

    private let manifestKey = "watch-download-manifest"
    private var activeTask: Task<Void, Never>?

    private init() {
        if let data = UserDefaults.standard.data(forKey: manifestKey),
           let saved = try? JSONDecoder().decode([Record].self, from: data) {
            records = saved.filter { FileManager.default.fileExists(atPath: Self.fileURL(for: $0.id,
                                                                                         extension: $0.fileExtension).path) }
        }
    }

    nonisolated static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WatchAudio", isDirectory: true)
    }

    nonisolated static func fileURL(for id: String, extension fileExtension: String) -> URL {
        root.appendingPathComponent("\(id).\(fileExtension)")
    }

    nonisolated static func incomingURL(for id: String) -> URL {
        fileURL(for: id, extension: "mp4")
    }

    func localURL(for video: WatchVideo) -> URL? {
        guard let record = records.first(where: { $0.id == video.id }) else { return nil }
        let url = Self.fileURL(for: record.id, extension: record.fileExtension)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func register(_ video: WatchVideo, extension fileExtension: String) {
        if let old = records.first(where: { $0.id == video.id }), old.fileExtension != fileExtension {
            try? FileManager.default.removeItem(at: Self.fileURL(for: old.id, extension: old.fileExtension))
        }
        records.removeAll { $0.id == video.id }
        records.insert(Record(video: video, fileExtension: fileExtension, savedAt: .now), at: 0)
        persist()
        message = "Disponible hors ligne sur la montre."
    }

    func delete(_ video: WatchVideo) {
        if WatchPlayer.shared.current?.id == video.id { WatchPlayer.shared.stop() }
        if let record = records.first(where: { $0.id == video.id }) {
            try? FileManager.default.removeItem(at: Self.fileURL(for: video.id, extension: record.fileExtension))
        }
        records.removeAll { $0.id == video.id }
        persist()
    }

    func transferFromPhone(_ video: WatchVideo) {
        activeTask = Task {
            do {
                _ = try await WatchBridge.shared.request("transferDownload", videoID: video.id)
                message = "Transfert demandé à l’iPhone. Il peut prendre quelques minutes."
            } catch { message = error.localizedDescription }
        }
    }

    func downloadOnWatch(_ video: WatchVideo) {
        guard downloadingID == nil else { return }
        downloadingID = video.id
        progress = 0
        message = nil
        activeTask = Task {
            defer { downloadingID = nil; activeTask = nil }
            do {
                let reply = try await WatchBridge.shared.request("prepareAudio", videoID: video.id)
                guard let text = reply[WatchMessage.mediaURL] as? String,
                      let url = URL(string: text), url.scheme == "https",
                      let length = (reply[WatchMessage.byteCount] as? NSNumber)?.int64Value,
                      length > 0 else { throw WatchBridgeError.badReply }
                try await fetchInRanges(from: url, length: length, video: video)
                register(video, extension: "m4a")
            } catch {
                message = Task.isCancelled
                    ? "Téléchargement interrompu. Réessaie pour reprendre."
                    : error.localizedDescription
            }
        }
    }

    func cancelDownload() {
        activeTask?.cancel()
        message = "Téléchargement interrompu. Réessaie pour reprendre."
    }

    private func fetchInRanges(from url: URL, length: Int64, video: WatchVideo) async throws {
        try FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
        let partial = Self.root.appendingPathComponent("\(video.id).m4a.partial")
        let marker = Self.root.appendingPathComponent("\(video.id).m4a.partial.length")
        let previousLength = (try? String(contentsOf: marker, encoding: .utf8)).flatMap(Int64.init)
        if previousLength != length {
            try? FileManager.default.removeItem(at: partial)
        }
        try String(length).write(to: marker, atomically: true, encoding: .utf8)
        if !FileManager.default.fileExists(atPath: partial.path) {
            FileManager.default.createFile(atPath: partial.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }
        var offset = Int64(try handle.seekToEnd())
        if offset > length {
            try handle.truncate(atOffset: 0)
            offset = 0
        }
        progress = Double(offset) / Double(length)
        let available = (try? FileManager.default.attributesOfFileSystem(forPath: Self.root.path)[.systemFreeSize]
            as? NSNumber)?.int64Value ?? 0
        guard available == 0 || available > length - offset + 20 * 1_048_576 else {
            throw WatchBridgeError.phone("Espace insuffisant sur la montre pour ce fichier audio.")
        }
        let block: Int64 = 4 * 1_048_576
        while offset < length {
            try Task.checkCancellation()
            let end = min(length - 1, offset + block - 1)
            var request = URLRequest(url: url)
            request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
            request.timeoutInterval = 60
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 206,
                  data.count == Int(end - offset + 1) else {
                throw WatchCatalogueError.invalidResponse
            }
            try handle.write(contentsOf: data)
            offset = end + 1
            progress = Double(offset) / Double(length)
        }
        let final = Self.fileURL(for: video.id, extension: "m4a")
        if FileManager.default.fileExists(atPath: final.path) { try FileManager.default.removeItem(at: final) }
        try FileManager.default.moveItem(at: partial, to: final)
        try? FileManager.default.removeItem(at: marker)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = final
        try? mutableURL.setResourceValues(values)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: manifestKey)
        }
    }
}
