import Foundation

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query: String = ""
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

    private let service: YouTubeAPIService
    private let recents: RecentSearchStore
    private var searchTask: Task<Void, Never>?
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

    func clear() {
        searchTask?.cancel()
        searchTask = nil
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

    private func run(_ text: String) {
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
