import Foundation

@MainActor
final class WatchAccountLibraryStore: ObservableObject {
    static let shared = WatchAccountLibraryStore()

    @Published private(set) var library: WatchAccountLibrary = .empty
    @Published var message: String?
    private var videoCache: [String: [WatchVideo]] = [:]
    private let videoCacheKey = "watch-account-video-cache"

    nonisolated static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("watch-account-library.json")
    }

    private init() {
        reload()
        if let data = UserDefaults.standard.data(forKey: videoCacheKey),
           let cached = try? JSONDecoder().decode([String: [WatchVideo]].self, from: data) {
            videoCache = cached
        }
    }

    func reload() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let decoded = try? JSONDecoder().decode(WatchAccountLibrary.self, from: data) else { return }
        library = decoded
        message = nil
    }

    func clear() {
        library = .empty
        videoCache = [:]
        try? FileManager.default.removeItem(at: Self.fileURL)
        UserDefaults.standard.removeObject(forKey: videoCacheKey)
    }

    func cachedVideos(kind: String, id: String) -> [WatchVideo] {
        videoCache["\(kind):\(id)"] ?? []
    }

    func loadVideos(kind: String, id: String, apiKey: String) async -> [WatchVideo] {
        let key = "\(kind):\(id)"
        do {
            let videos: [WatchVideo]
            if kind == "channel" {
                videos = try await WatchCatalogue.shared.channelVideos(id, apiKey: apiKey)
            } else {
                videos = try await WatchCatalogue.shared.playlistVideos(id, apiKey: apiKey)
            }
            videoCache[key] = videos
            persistCache()
            message = nil
            return videos
        } catch {
            do {
                let command = kind == "channel" ? "channelVideos" : "playlistVideos"
                let reply = try await WatchBridge.shared.request(command, videoID: id)
                guard let data = reply[WatchMessage.videos] as? Data,
                      let videos = try? JSONDecoder().decode([WatchVideo].self, from: data) else {
                    throw WatchBridgeError.badReply
                }
                videoCache[key] = videos
                persistCache()
                message = nil
                return videos
            } catch {
                message = error.localizedDescription
                return videoCache[key] ?? []
            }
        }
    }

    private func persistCache() {
        if let data = try? JSONEncoder().encode(videoCache) {
            UserDefaults.standard.set(data, forKey: videoCacheKey)
        }
    }
}
