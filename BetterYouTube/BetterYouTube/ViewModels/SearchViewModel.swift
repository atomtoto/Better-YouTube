import Foundation

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query: String = ""
    @Published private(set) var results: [SearchResult] = []
    @Published private(set) var isSearching = false
    @Published var errorMessage: String?

    private let service: YouTubeAPIService
    private var searchTask: Task<Void, Never>?

    init(service: YouTubeAPIService = .shared) {
        self.service = service
    }

    /// Debounces user input before firing a network request.
    func queryChanged() {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
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

    private func performSearch(_ text: String) async {
        isSearching = true
        errorMessage = nil
        do {
            let found = try await service.search(query: text)
            if !Task.isCancelled {
                results = found
            }
        } catch {
            if !Task.isCancelled {
                errorMessage = error.localizedDescription
            }
        }
        isSearching = false
    }
}
