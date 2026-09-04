import SwiftUI

struct SearchView: View {
    @StateObject private var viewModel = SearchViewModel()

    var body: some View {
        Group {
            if viewModel.isSearching && viewModel.results.isEmpty {
                ProgressView("Searching…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let message = viewModel.errorMessage, viewModel.results.isEmpty {
                EmptyStateView(title: "Search failed", message: message)
            } else if viewModel.results.isEmpty {
                EmptyStateView(
                    title: viewModel.query.isEmpty ? "Search YouTube" : "No results",
                    systemImage: "magnifyingglass",
                    message: viewModel.query.isEmpty ? "Find videos and channels." : "Try a different search."
                )
            } else {
                List(viewModel.results) { result in
                    switch result {
                    case .video(let video):
                        NavigationLink(value: video) {
                            VideoRowView(video: video)
                        }
                    case .channel(let channel):
                        NavigationLink(value: channel) {
                            ChannelRowView(channel: channel)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Search")
        .searchable(text: $viewModel.query, prompt: "Search videos and channels")
        .onChange(of: viewModel.query) { _ in viewModel.queryChanged() }
        .onSubmit(of: .search) { viewModel.submit() }
        .navigationDestination(for: Video.self) { video in
            VideoDetailView(video: video)
        }
        .navigationDestination(for: Channel.self) { channel in
            ChannelView(channelId: channel.id, initialChannel: channel)
        }
    }
}

struct ChannelRowView: View {
    let channel: Channel

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: channel.thumbnailURL) { phase in
                if case .success(let image) = phase {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Circle().fill(Color.gray.opacity(0.25))
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(channel.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let subs = channel.subscriberCount {
                    Text("\(CountFormatter.abbreviated(subs)) subscribers")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Channel")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationStack { SearchView() }
        .environmentObject(APIKeyStore.shared)
        .environmentObject(LibraryStore.shared)
}
