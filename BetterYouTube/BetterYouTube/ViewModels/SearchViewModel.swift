import Foundation

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query: String = ""
    /// Whether the search field is up. Leaving the search tab by a link — a channel opening in
    /// Home, say — puts it away, or it would stay open over the screen arrived at.
    @Published var isPresented = false
    @Published private(set) var results: [SearchResult] = []
    @Published private(set) var isSearching = false
    @Published private(set) var hasSearched = false
    @Published var errorMessage: String?
    @Published private(set) var isLoadingMore = false
    @Published private(set) var loadMoreError: String?
    /// Sort order, length and upload date. Changing them re-runs the search on screen, the way
    /// YouTube's own filter sheet does.
    @Published var filters = SearchFilters() {
        didSet {
            guard filters != oldValue, let lastQuery, hasSearched else { return }
            run(lastQuery)
        }
    }

    /// What YouTube suggests for the text in the field, fetched as you type. Empty when that is
    /// turned off, or when the field holds a link.
    @Published private(set) var remoteSuggestions: [String] = []
    /// The text of the search last run, while the field still holds it. Suggestions step aside
    /// for its results until the text is edited again.
    @Published private(set) var submittedQuery: String?
    /// A channel or playlist opened from a pasted link, which Search pushes onto its own stack.
    @Published var linkedChannel: Channel?
    @Published var linkedPlaylist: Playlist?
    @Published var linkError: String?

    /// Whether the field asks YouTube for suggestions as you type. On by default; Settings →
    /// Library turns it off.
    static let remoteSuggestionsKey = "search_youtube_suggestions"

    private let service: YouTubeAPIService
    private let recents: RecentSearchStore
    private var searchTask: Task<Void, Never>?
    private var suggestionTask: Task<Void, Never>?
    /// The text the results on screen are for, which is what a further page continues.
    private var lastQuery: String?
    private var nextPageToken: String?

    init(service: YouTubeAPIService = .shared, recents: RecentSearchStore? = nil) {
        self.service = service
        self.recents = recents ?? .shared
    }

    var videos: [Video] {
        results.compactMap { result -> Video? in
            if case .video(let video) = result { return video }
            return nil
        }
    }

    var channels: [Channel] {
        results.compactMap { result -> Channel? in
            if case .channel(let channel) = result { return channel }
            return nil
        }
    }

    /// More results exist for the search on screen. Each further page is another 100 units, so
    /// the screen asks for one with a button rather than as you scroll.
    var canLoadMore: Bool { nextPageToken != nil }

    /// The query as a YouTube link, if it is one — which Search opens rather than searches for.
    var link: YouTubeLink? { YouTubeLink(string: query) }

    /// Searching is explicit — `search.list` costs 100 of the 10,000 daily quota units, so it
    /// runs when you submit, never while you type.
    func submit() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        run(trimmed)
    }

    func search(term: String) {
        query = term
        submit()
    }

    /// What the field's Search key does: opens a pasted link, or searches for the text.
    func submitOrOpen() {
        if let link {
            open(link)
        } else {
            submit()
        }
    }

    /// Follows the field as it changes. Emptying it — its clear button, or Cancel — clears the
    /// results with it; anything else is new text to suggest completions for.
    func queryChanged(_ text: String) {
        if text.isEmpty {
            clear()
        } else if text.trimmingCharacters(in: .whitespacesAndNewlines) != submittedQuery {
            submittedQuery = nil
            fetchSuggestions(for: text)
        }
    }

    /// The suggestions to offer under the field: the recent searches that match first, then
    /// YouTube's, without repeating one, and only as many as fit above a phone's keyboard.
    func suggestions(recents terms: [String]) -> [SearchSuggestion] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, link == nil, submittedQuery == nil else { return [] }
        let recent = terms
            .filter { $0.localizedStandardContains(text) && $0.caseInsensitiveCompare(text) != .orderedSame }
            .prefix(3)
            .map { SearchSuggestion(text: $0, isRecent: true) }
        let remote = remoteSuggestions
            .filter { term in
                term.caseInsensitiveCompare(text) != .orderedSame
                    && !recent.contains { $0.text.caseInsensitiveCompare(term) == .orderedSame }
            }
            .map { SearchSuggestion(text: $0, isRecent: false) }
        return Array((recent + remote).prefix(8))
    }

    func clear() {
        searchTask?.cancel()
        searchTask = nil
        suggestionTask?.cancel()
        suggestionTask = nil
        remoteSuggestions = []
        submittedQuery = nil
        query = ""
        results = []
        hasSearched = false
        errorMessage = nil
        lastQuery = nil
        nextPageToken = nil
        loadMoreError = nil
        // The cancelled search returns without touching state, so this is the only place left
        // to say it stopped — otherwise clearing mid-search leaves a spinner up for good.
        isSearching = false
        isLoadingMore = false
    }

    func loadMore() async {
        guard let token = nextPageToken, let lastQuery, !isLoadingMore, !isSearching else { return }
        isLoadingMore = true
        loadMoreError = nil
        do {
            let page = try await service.search(query: lastQuery, filters: filters, pageToken: token)
            // A new search may have started meanwhile; its first page owns the list now.
            guard lastQuery == self.lastQuery, !isSearching else { return }
            let known = Set(results.map(\.id))
            results += page.items.filter { !known.contains($0.id) }
            nextPageToken = page.nextPageToken
        } catch {
            loadMoreError = error.localizedDescription
        }
        isLoadingMore = false
    }

    /// A pasted link goes straight to what it names — one unit at most, against the 100 a
    /// search for it would cost, and exactly the thing that was shared.
    private func open(_ link: YouTubeLink) {
        switch link {
        case .video(let id, let start):
            Task { await PlayerManager.shared.open(videoId: id, startTime: start) }
        case .playlist(let id):
            linkedPlaylist = Playlist(id: id, title: "", description: "", thumbnailURL: nil)
        case .channel(let id):
            linkedChannel = Channel(id: id, title: "", description: "", thumbnailURL: nil)
        case .handle(let handle):
            Task {
                do {
                    if let channel = try await service.channel(handle: handle) {
                        linkedChannel = channel
                    } else {
                        linkError = String(localized: "YouTube has no channel called \(handle).")
                    }
                } catch {
                    linkError = error.localizedDescription
                }
            }
        }
    }

    /// Asks YouTube what people search for that starts this way, once typing pauses. Free of
    /// quota — it is the suggestion service YouTube's own search box uses, not the Data API.
    private func fetchSuggestions(for text: String) {
        suggestionTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let enabled = UserDefaults.standard.object(forKey: Self.remoteSuggestionsKey) as? Bool ?? true
        guard enabled, !trimmed.isEmpty, YouTubeLink(string: trimmed) == nil else {
            remoteSuggestions = []
            return
        }
        // The demo can only find what its catalogue holds, so it suggests from there.
        if DemoMode.isRunning {
            remoteSuggestions = DemoCatalog.shared.suggestions(for: trimmed)
            return
        }
        suggestionTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let fetched = (try? await YouTubeSuggestions.fetch(for: trimmed)) ?? []
            guard !Task.isCancelled else { return }
            remoteSuggestions = fetched
        }
    }

    private func run(_ text: String) {
        submittedQuery = text
        suggestionTask?.cancel()
        remoteSuggestions = []
        searchTask?.cancel()
        searchTask = Task { await performSearch(text) }
    }

    private func performSearch(_ text: String) async {
        isSearching = true
        isLoadingMore = false
        errorMessage = nil
        loadMoreError = nil
        do {
            let page = try await service.search(query: text, filters: filters, pageToken: nil)
            guard !Task.isCancelled else { return }
            results = page.items
            nextPageToken = page.nextPageToken
            lastQuery = text
            hasSearched = true
            recents.record(text)
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
            nextPageToken = nil
            lastQuery = text
            hasSearched = true
        }
        isSearching = false
    }
}

/// One line under the search field.
struct SearchSuggestion: Identifiable, Hashable {
    let text: String
    /// One of your own recent searches, rather than one of YouTube's.
    let isRecent: Bool

    var id: String { text }
}

/// YouTube's search suggestions — the completions its own search box offers.
///
/// They come from Google's suggestion service rather than the Data API, so they cost no quota
/// and need no key, but they are not an official, documented interface: if it changes, the field
/// simply offers your recent searches alone. The session keeps no cookies, so what you type is
/// not tied to anything else.
enum YouTubeSuggestions {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 5
        return URLSession(configuration: configuration)
    }()

    static func fetch(for query: String, locale: Locale = .current) async throws -> [String] {
        var components = URLComponents(string: "https://suggestqueries.google.com/complete/search")!
        components.queryItems = [
            URLQueryItem(name: "client", value: "firefox"),
            URLQueryItem(name: "ds", value: "yt"),
            URLQueryItem(name: "ie", value: "utf-8"),
            URLQueryItem(name: "oe", value: "utf-8"),
            URLQueryItem(name: "hl", value: locale.language.languageCode?.identifier ?? "en"),
            URLQueryItem(name: "gl", value: locale.region?.identifier ?? "US"),
            URLQueryItem(name: "q", value: query)
        ]
        let (data, _) = try await session.data(from: components.url!)
        return parse(data)
    }

    /// The response is a JSON array: the query, then the list of suggestions, then extras this
    /// app has no use for.
    static func parse(_ data: Data) -> [String] {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
              array.count > 1,
              let suggestions = array[1] as? [String]
        else { return [] }
        return suggestions
    }
}
