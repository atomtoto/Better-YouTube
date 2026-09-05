import Foundation

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query: String = ""
    @Published private(set) var results: [SearchResult] = []
    @Published private(set) var isSearching = false
    @Published private(set) var hasSearched = false
    @Published var errorMessage: String?

    private let service: YouTubeAPIService
    private let recents: RecentSearchStore
    private var searchTask: Task<Void, Never>?

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

    /// Searching is explicit — `search.list` costs 100 of the 10,000 daily quota units, so it
    /// runs when you submit, never while you type.
    func submit() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        searchTask?.cancel()
        searchTask = Task { await performSearch(trimmed) }
    }

    func search(term: String) {
        query = term
        submit()
    }

    func clear() {
        searchTask?.cancel()
        query = ""
        results = []
        hasSearched = false
        errorMessage = nil
    }

    private func performSearch(_ text: String) async {
        isSearching = true
        errorMessage = nil
        do {
            let found = try await service.search(query: text)
            guard !Task.isCancelled else { return }
            results = found
            hasSearched = true
            recents.record(text)
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
            hasSearched = true
        }
        isSearching = false
    }
}
