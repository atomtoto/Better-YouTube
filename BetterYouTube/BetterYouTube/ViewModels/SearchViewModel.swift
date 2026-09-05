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

    /// Debounces typing so a 100-unit search request doesn't fire on every keystroke.
    func queryChanged() {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            hasSearched = false
            errorMessage = nil
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await performSearch(trimmed)
        }
    }

    func submit() {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { await performSearch(trimmed) }
    }

    func search(term: String) {
        query = term
        submit()
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
