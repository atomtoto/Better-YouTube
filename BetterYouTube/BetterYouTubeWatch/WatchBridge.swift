import Foundation
import WatchConnectivity

enum WatchBridgeError: LocalizedError {
    case phoneUnavailable
    case badReply
    case phone(String)

    var errorDescription: String? {
        switch self {
        case .phoneUnavailable: "L’iPhone doit être joignable pour préparer ou transférer ce téléchargement."
        case .badReply: "L’iPhone n’a pas envoyé de réponse exploitable."
        case .phone(let message): message
        }
    }
}

@MainActor
final class WatchBridge: NSObject, ObservableObject {
    static let shared = WatchBridge()

    @Published private(set) var snapshot: WatchSnapshot = .empty
    @Published private(set) var localLibrary: WatchLocalLibrary?
    @Published private(set) var apiKey = WatchKeychain.loadAPIKey()
    @Published private(set) var isReachable = false
    @Published var message: String?

    private let session = WCSession.default
    private let cacheKey = "watch-iphone-snapshot"

    nonisolated private static var localLibraryURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("watch-local-library.json")
    }

    private override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: cacheKey),
           let cached = try? JSONDecoder().decode(WatchSnapshot.self, from: data) {
            snapshot = cached
        }
        reloadLocalLibrary()
    }

    func start() {
        guard WCSession.isSupported() else { return }
        session.delegate = self
        session.activate()
        apply(session.receivedApplicationContext)
    }

    func refresh() async {
        _ = try? await request("refresh")
    }

    func request(_ command: String, videoID: String? = nil) async throws -> [String: Any] {
        guard session.activationState == .activated, session.isReachable else {
            throw WatchBridgeError.phoneUnavailable
        }
        var payload: [String: Any] = [WatchMessage.command: command]
        if let videoID { payload[WatchMessage.videoID] = videoID }
        let reply: [String: Any] = try await withCheckedThrowingContinuation { continuation in
            session.sendMessage(payload, replyHandler: { continuation.resume(returning: $0) },
                                errorHandler: { continuation.resume(throwing: $0) })
        }
        if let error = reply[WatchMessage.error] as? String { throw WatchBridgeError.phone(error) }
        apply(reply)
        return reply
    }

    private func apply(_ context: [String: Any]) {
        if let data = context[WatchMessage.localLibrary] as? Data,
           let decoded = try? JSONDecoder().decode(WatchLocalLibrary.self, from: data) {
            localLibrary = decoded
            try? data.write(to: Self.localLibraryURL, options: .atomic)
        }
        if let data = context[WatchMessage.snapshot] as? Data,
           let decoded = try? JSONDecoder().decode(WatchSnapshot.self, from: data) {
            let wasSignedIn = snapshot.accountSignedIn
            snapshot = decoded
            UserDefaults.standard.set(data, forKey: cacheKey)
            if !decoded.accountSignedIn { WatchAccountLibraryStore.shared.clear() }
            else if !wasSignedIn { WatchAccountLibraryStore.shared.reload() }
        }
        if let key = context[WatchMessage.apiKey] as? String, key != apiKey {
            WatchKeychain.saveAPIKey(key)
            apiKey = key
        }
    }

    private func updateReachability() {
        isReachable = session.activationState == .activated && session.isReachable
    }

    private func reloadLocalLibrary() {
        guard let data = try? Data(contentsOf: Self.localLibraryURL),
              let decoded = try? JSONDecoder().decode(WatchLocalLibrary.self, from: data) else { return }
        localLibrary = decoded
    }
}

extension WatchBridge: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            self.updateReachability()
            self.apply(session.receivedApplicationContext)
            if state == .activated { await self.refresh() }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.updateReachability() }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        Task { @MainActor in self.apply(context) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in self.apply(message) }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        if file.metadata?["kind"] as? String == "localLibrary" {
            do {
                try FileManager.default.createDirectory(at: Self.localLibraryURL.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: Self.localLibraryURL.path) {
                    try FileManager.default.removeItem(at: Self.localLibraryURL)
                }
                try FileManager.default.moveItem(at: file.fileURL, to: Self.localLibraryURL)
                Task { @MainActor in self.reloadLocalLibrary() }
            } catch {
                Task { @MainActor in self.message = error.localizedDescription }
            }
            return
        }
        if file.metadata?["kind"] as? String == "accountLibrary" {
            let destination = WatchAccountLibraryStore.fileURL
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: file.fileURL, to: destination)
                Task { @MainActor in
                    if self.snapshot.accountSignedIn {
                        WatchAccountLibraryStore.shared.reload()
                    } else if self.snapshot.updatedAt != .distantPast {
                        WatchAccountLibraryStore.shared.clear()
                    }
                }
            } catch {
                Task { @MainActor in self.message = error.localizedDescription }
            }
            return
        }
        guard let data = file.metadata?["video"] as? Data,
              let video = try? JSONDecoder().decode(WatchVideo.self, from: data),
              video.id.count == 11 else { return }
        let destination = WatchDownloads.incomingURL(for: video.id)
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: file.fileURL, to: destination)
            Task { @MainActor in WatchDownloads.shared.register(video, extension: "mp4") }
        } catch {
            Task { @MainActor in self.message = error.localizedDescription }
        }
    }
}
