import Combine
import Foundation

/// Loads the signed-in account's library: subscriptions, playlists and liked videos.
///
/// It opens on what `AccountLibraryCache` kept from last time, then refreshes underneath.
/// Every source is shown — and kept — as soon as it answers, and one that fails or is still
/// loading keeps what it showed before: so the playlists never drop to only the account's own,
/// or to none, while youtube.com is still being read.
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
    /// The load under way, and the sign-ins it is loading for.
    private var loading: (signIns: SignIns, id: UUID, task: Task<Void, Never>)?
    private var signInObservations = Set<AnyCancellable>()

    private struct SignIns: Equatable {
        let api: Bool
        let web: Bool
    }

    init(service: YouTubeAPIService = .shared, cache: AccountLibraryCache? = DemoMode.isRunning ? nil : .shared) {
        self.service = service
        self.cache = cache
        if let cache {
            account = cache.load(.account)
            subscriptions = cache.load(.subscriptions) ?? []
            likedVideos = cache.load(.likedVideos) ?? []
            ownedPlaylists = cache.load(.ownedPlaylists) ?? []
            webPlaylists = cache.load(.webPlaylists) ?? []
            mergePlaylists()
        }

        // Each half belongs to the sign-in it was loaded under. Forget it the moment that one
        // ends or is replaced, whether or not Library is on screen to reload: otherwise the next
        // account would open on the previous one's library. Synchronously — both publish on the
        // main actor — so it is done before the load the change sets off begins.
        GoogleAuthService.shared.$isSignedIn.removeDuplicates().dropFirst()
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.cancelLoad()
                    self?.forgetAccount()
                }
            }
            .store(in: &signInObservations)
        YouTubeWebSession.shared.$feedGeneration.dropFirst()
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.cancelLoad()
                    self?.forgetWebPlaylists()
                }
            }
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
        let signIns = SignIns(api: apiSignedIn, web: webSignedIn)
        // Coming back to Library, or pulling, while a load runs waits for that one rather than
        // starting it all over.
        if let loading, loading.signIns == signIns { return await loading.task.value }
        cancelLoad()

        // A sign-in that has ended takes its half with it; the other half stays on screen until
        // its fresh copy arrives.
        if !apiSignedIn { forgetAccount() }
        if !webSignedIn { forgetWebPlaylists() }

        // Not tied to the screen: leaving Library before youtube.com has answered shouldn't
        // throw away what was on its way, which is then there the next time.
        isLoading = true
        errorMessage = nil
        let id = UUID()
        let task = Task { await fetch(signIns, id: id) }
        loading = (signIns, id, task)
        await task.value
    }

    private func fetch(_ signIns: SignIns, id: UUID) async {
        // All at once, each applied as it lands: the account is one quick call and shouldn't
        // wait on a thousand subscriptions, nor anything on youtube.com's page.
        var failures: [String] = []
        await withTaskGroup(of: Part.self) { group in
            let service = service
            if signIns.api {
                group.addTask { .account(await Self.capture { try await service.myChannel() }) }
                group.addTask { .subscriptions(await Self.capture { try await service.mySubscriptions() }) }
                group.addTask { .ownedPlaylists(await Self.capture { try await service.myPlaylists() }) }
                group.addTask { .likedVideos(await Self.capture { try await service.likedVideos() }) }
            }
            if signIns.web {
                group.addTask {
                    .webPlaylists(await Self.capture { try await YouTubeWebPlaylistService.shared.playlists() })
                }
            }
            // Only a change of sign-in cancels a load, and that has already cleared what this
            // one was loading for.
            for await part in group where !Task.isCancelled {
                if let failure = apply(part) { failures.append(failure) }
            }
        }

        guard !Task.isCancelled, loading?.id == id else { return }
        loading = nil
        isLoading = false
        errorMessage = failures.first
    }

    /// Shows one source's answer and keeps it for next time, or returns why it had none. A
    /// failure leaves that source's last copy in place.
    private func apply(_ part: Part) -> String? {
        do {
            switch part {
            case .account(let result):
                account = try result.get()
                cache?.save(account, as: .account)
            case .subscriptions(let result):
                subscriptions = try result.get()
                cache?.save(subscriptions, as: .subscriptions)
            case .likedVideos(let result):
                likedVideos = try result.get()
                cache?.save(likedVideos, as: .likedVideos)
            case .ownedPlaylists(let result):
                ownedPlaylists = try result.get()
                cache?.save(ownedPlaylists, as: .ownedPlaylists)
                mergePlaylists()
            case .webPlaylists(let result):
                webPlaylists = try result.get()
                cache?.save(webPlaylists, as: .webPlaylists)
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
        cancelLoad()
        errorMessage = nil
        forgetAccount()
        forgetWebPlaylists()
    }

    private func cancelLoad() {
        loading?.task.cancel()
        loading = nil
        isLoading = false
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

/// The account's library as last loaded, so Library opens on it rather than on spinners.
///
/// Each source sits in a file of its own and is saved the moment it arrives, so a load cut short
/// still keeps what it got. The files come in two halves, one per sign-in: what the Data API
/// returns for the Google account, and what only youtube.com lists — saved and system
/// playlists, and the real Watch Later. Each half is dropped when its sign-in ends, so nothing
/// of one account is ever shown under another.
struct AccountLibraryCache: Sendable {
    static let shared = AccountLibraryCache()

    enum Item: String, CaseIterable, Sendable {
        // The Google account's, through the Data API. Home's two feeds go with them: signed in
        // they are read from the account, and either way they are dropped when it changes.
        case account, subscriptions, likedVideos, ownedPlaylists, homeFeeds
        // youtube.com's.
        case webPlaylists, watchLater

        var belongsToWebSession: Bool { self == .webPlaylists || self == .watchLater }
    }

    let folder: URL

    init(folder: URL = Platform.cachesFolder.appendingPathComponent("youtube-library", isDirectory: true)) {
        self.folder = folder
    }

    func load<Value: Decodable>(_ item: Item) -> Value? {
        guard let data = try? Data(contentsOf: url(of: item)) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    /// Saving `nil` forgets the item.
    func save<Value: Encodable>(_ value: Value?, as item: Item) {
        guard let value, let data = try? JSONEncoder().encode(value) else { return remove([item]) }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: url(of: item), options: .atomic)
    }

    /// The Google account's half: on signing out, and on a sign-in that may be another account.
    func clearAccount() {
        remove(Item.allCases.filter { !$0.belongsToWebSession })
    }

    /// youtube.com's half, whenever its session ends or is replaced.
    func clearWebSession() {
        remove(Item.allCases.filter(\.belongsToWebSession))
    }

    private func remove(_ items: [Item]) {
        for item in items { try? FileManager.default.removeItem(at: url(of: item)) }
    }

    private func url(of item: Item) -> URL {
        folder.appendingPathComponent("\(item.rawValue)-v1.json")
    }
}
