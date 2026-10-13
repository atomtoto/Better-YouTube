import Combine
import Foundation

/// Loads the signed-in account's library: subscriptions, playlists and liked videos.
///
/// It opens on the copy `AccountLibraryCache` kept from last time, then refreshes underneath.
/// Every source is shown as soon as it answers, and one that fails or is still loading keeps
/// what it showed before — so the playlists never drop to only the account's own, or to none,
/// while youtube.com is still being read.
@MainActor
final class LibraryViewModel: ObservableObject {
    @Published private(set) var account: Channel?
    @Published private(set) var subscriptions: [Channel] = []
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var likedVideos: [Video] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let service: YouTubeAPIService
    /// None during a demo: its account is not the user's, and neither is its library.
    private let cache: AccountLibraryCache?
    /// What `playlists` is merged from, kept apart so that each source only ever replaces its own.
    private var ownedPlaylists: [Playlist] = []
    private var webPlaylists: [Playlist] = []
    /// Bumped by every load, so one that was overtaken can't write over the newer one's results.
    private var generation = 0
    private var signInObservations = Set<AnyCancellable>()

    init(service: YouTubeAPIService = .shared, cache: AccountLibraryCache? = DemoMode.isRunning ? nil : .shared) {
        self.service = service
        self.cache = cache
        if let snapshot = cache?.load() {
            account = snapshot.account
            subscriptions = snapshot.subscriptions
            likedVideos = snapshot.likedVideos
            ownedPlaylists = snapshot.ownedPlaylists
            webPlaylists = snapshot.webPlaylists
            mergePlaylists()
        }

        // Each half belongs to the sign-in it was loaded under. Forget it the moment that one
        // ends or is replaced, whether or not Library is on screen to reload: otherwise the next
        // account would open on the previous one's library. Synchronously — both publish on the
        // main actor — so it is done before the load the change sets off begins.
        GoogleAuthService.shared.$isSignedIn.removeDuplicates().dropFirst()
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.forgetAccount() } }
            .store(in: &signInObservations)
        YouTubeWebSession.shared.$feedGeneration.dropFirst()
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.forgetWebPlaylists() } }
            .store(in: &signInObservations)
    }

    private enum Part: Sendable {
        case account(Result<Channel?, Error>)
        case subscriptions(Result<[Channel], Error>)
        case ownedPlaylists(Result<[Playlist], Error>)
        case likedVideos(Result<[Video], Error>)
        case webPlaylists(Result<[Playlist], Error>)
    }

    func load(apiSignedIn: Bool, webSignedIn: Bool) async {
        generation += 1
        let generation = generation
        isLoading = true
        errorMessage = nil

        // A sign-in that has ended takes its half with it; the other half stays on screen until
        // its fresh copy arrives.
        if !apiSignedIn { forgetAccount() }
        if !webSignedIn { forgetWebPlaylists() }

        // All at once, each applied as it lands: the account is one quick call and shouldn't
        // wait on a thousand subscriptions, nor anything on youtube.com's page.
        var failures: [String] = []
        await withTaskGroup(of: Part.self) { group in
            let service = service
            if apiSignedIn {
                group.addTask { .account(await Self.capture { try await service.myChannel() }) }
                group.addTask { .subscriptions(await Self.capture { try await service.mySubscriptions() }) }
                group.addTask { .ownedPlaylists(await Self.capture { try await service.myPlaylists() }) }
                group.addTask { .likedVideos(await Self.capture { try await service.likedVideos() }) }
            }
            if webSignedIn {
                group.addTask {
                    .webPlaylists(await Self.capture { try await YouTubeWebPlaylistService.shared.playlists() })
                }
            }
            for await part in group {
                guard generation == self.generation, !Task.isCancelled else { continue }
                if let failure = apply(part) { failures.append(failure) }
            }
        }

        guard generation == self.generation else { return }
        isLoading = false
        // A load cut short is replaced by the next one, which reports its own errors.
        guard !Task.isCancelled else { return }
        errorMessage = failures.first
        cache?.save(AccountLibrarySnapshot(
            account: account,
            subscriptions: subscriptions,
            ownedPlaylists: ownedPlaylists,
            likedVideos: likedVideos,
            webPlaylists: webPlaylists
        ))
    }

    /// Shows one source's answer, or returns why it had none. A failure leaves that source's
    /// last copy in place.
    private func apply(_ part: Part) -> String? {
        do {
            switch part {
            case .account(let result): account = try result.get()
            case .subscriptions(let result): subscriptions = try result.get()
            case .likedVideos(let result): likedVideos = try result.get()
            case .ownedPlaylists(let result):
                ownedPlaylists = try result.get()
                mergePlaylists()
            case .webPlaylists(let result):
                webPlaylists = try result.get()
                mergePlaylists()
            }
            return nil
        } catch is CancellationError {
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// youtube.com's aggregation holds owned, saved and system playlists in its own order; the
    /// API only the owned ones, with better metadata. So: YouTube's order and every playlist in
    /// it, the API's copy wherever it has one, and owned playlists YouTube hasn't listed last.
    private func mergePlaylists() {
        let owned = Dictionary(ownedPlaylists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        playlists = (webPlaylists + ownedPlaylists).compactMap { playlist in
            guard !playlist.isLikedVideos, seen.insert(playlist.id).inserted else { return nil }
            return owned[playlist.id] ?? playlist
        }
    }

    private nonisolated static func capture<Value: Sendable>(
        _ operation: () async throws -> Value
    ) async -> Result<Value, Error> {
        do { return .success(try await operation()) }
        catch { return .failure(error) }
    }

    func reset() {
        generation += 1
        isLoading = false
        errorMessage = nil
        forgetAccount()
        forgetWebPlaylists()
    }

    private func forgetAccount() {
        account = nil
        subscriptions = []
        likedVideos = []
        ownedPlaylists = []
        mergePlaylists()
    }

    private func forgetWebPlaylists() {
        webPlaylists = []
        mergePlaylists()
    }
}

/// The account's library as Library last showed it.
///
/// Two halves, one per sign-in: what the Data API returns for the Google account, and the
/// playlists only youtube.com lists — saved and system ones. Each is dropped when its sign-in
/// ends, so nothing of one account is shown under another.
struct AccountLibrarySnapshot: Codable, Equatable {
    var account: Channel?
    var subscriptions: [Channel] = []
    var ownedPlaylists: [Playlist] = []
    var likedVideos: [Video] = []
    var webPlaylists: [Playlist] = []

    var isEmpty: Bool {
        account == nil && subscriptions.isEmpty && ownedPlaylists.isEmpty && likedVideos.isEmpty
            && webPlaylists.isEmpty
    }
}

struct AccountLibraryCache: Sendable {
    static let shared = AccountLibraryCache()

    let url: URL

    init(url: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("youtube-library-v1.json")) {
        self.url = url
    }

    func load() -> AccountLibrarySnapshot? {
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(AccountLibrarySnapshot.self, from: data),
              !snapshot.isEmpty else { return nil }
        return snapshot
    }

    func save(_ snapshot: AccountLibrarySnapshot) {
        guard !snapshot.isEmpty else { return clear() }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// The Google account's half: on signing out, and on a sign-in that may be another account.
    func clearAccount() {
        guard var snapshot = load() else { return }
        snapshot.account = nil
        snapshot.subscriptions = []
        snapshot.ownedPlaylists = []
        snapshot.likedVideos = []
        save(snapshot)
    }

    /// youtube.com's half, whenever its session ends or is replaced.
    func clearWebPlaylists() {
        guard var snapshot = load() else { return }
        snapshot.webPlaylists = []
        save(snapshot)
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
