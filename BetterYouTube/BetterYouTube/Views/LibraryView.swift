import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var section: Section = .favorites

    enum Section: String, CaseIterable, Identifiable {
        case favorites = "Favorites"
        case watchLater = "Watch Later"
        case history = "History"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $section) {
                ForEach(Section.allCases) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            list
        }
        .navigationTitle("Library")
        .navigationDestination(for: Video.self) { video in
            VideoDetailView(video: video)
        }
        .toolbar {
            if section == .history && !library.history.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Clear") { library.clearHistory() }
                }
            }
        }
    }

    @ViewBuilder
    private var list: some View {
        switch section {
        case .favorites:
            videoList(library.favorites, empty: "No favorites yet", onDelete: library.removeFavorites)
        case .watchLater:
            videoList(library.watchLater, empty: "Nothing saved for later", onDelete: library.removeWatchLater)
        case .history:
            videoList(library.history, empty: "No watch history yet", onDelete: library.removeFromHistory)
        }
    }

    private func videoList(_ videos: [Video], empty: String, onDelete: @escaping (IndexSet) -> Void) -> some View {
        Group {
            if videos.isEmpty {
                EmptyStateView(title: empty, systemImage: "tray")
            } else {
                List {
                    ForEach(videos) { video in
                        NavigationLink(value: video) {
                            VideoRowView(video: video)
                        }
                    }
                    .onDelete(perform: onDelete)
                }
                .listStyle(.plain)
            }
        }
    }
}

#Preview {
    NavigationStack { LibraryView() }
        .environmentObject(APIKeyStore.shared)
        .environmentObject(LibraryStore.shared)
}
