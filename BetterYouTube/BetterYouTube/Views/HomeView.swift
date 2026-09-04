import SwiftUI

struct HomeView: View {
    @StateObject private var viewModel = HomeViewModel()

    var body: some View {
        Group {
            if viewModel.isLoading && viewModel.videos.isEmpty {
                ProgressView("Loading trending videos…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let message = viewModel.errorMessage, viewModel.videos.isEmpty {
                EmptyStateView(title: "Couldn't load videos", message: message)
            } else {
                List(viewModel.videos) { video in
                    NavigationLink(value: video) {
                        VideoRowView(video: video)
                    }
                }
                .listStyle(.plain)
                .refreshable { await viewModel.load() }
            }
        }
        .navigationTitle("Trending")
        .navigationDestination(for: Video.self) { video in
            VideoDetailView(video: video)
        }
        .task {
            if viewModel.videos.isEmpty {
                await viewModel.load()
            }
        }
    }
}

#Preview {
    NavigationStack { HomeView() }
        .environmentObject(APIKeyStore.shared)
        .environmentObject(LibraryStore.shared)
}
