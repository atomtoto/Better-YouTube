import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var recents: RecentSearchStore
    @StateObject private var viewModel = SearchViewModel()

    private let categories: [(title: String, symbol: String, colors: [Color])] = [
        ("Music", "music.note", [.pink, .purple]),
        ("Gaming", "gamecontroller.fill", [.indigo, .blue]),
        ("News", "newspaper.fill", [.orange, .red]),
        ("Sport", "sportscourt.fill", [.green, .teal]),
        ("Tech", "cpu.fill", [.blue, .cyan]),
        ("Podcasts", "mic.fill", [.purple, .indigo])
    ]

    var body: some View {
        Group {
            if viewModel.isSearching && viewModel.results.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let message = viewModel.errorMessage, viewModel.results.isEmpty {
                EmptyStateView(title: "Search failed", systemImage: "exclamationmark.triangle", message: message)
            } else if viewModel.results.isEmpty && viewModel.hasSearched {
                EmptyStateView(
                    title: "No Results",
                    systemImage: "magnifyingglass",
                    message: "Try a different search term."
                )
            } else if viewModel.results.isEmpty {
                browse
            } else {
                results
            }
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle("Search")
        .searchable(text: $viewModel.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Videos and channels")
        .onChange(of: viewModel.query) { _ in viewModel.queryChanged() }
        .onSubmit(of: .search) { viewModel.submit() }
        .navigationDestination(for: Video.self) { VideoDetailView(video: $0) }
        .navigationDestination(for: Channel.self) { ChannelView(channelId: $0.id, initialChannel: $0) }
    }

    // MARK: Browse (empty state)

    private var browse: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                if !recents.terms.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Recently Searched")
                                .font(.title2.bold())
                            Spacer()
                            Button("Clear") { recents.clear() }
                                .font(.subheadline.weight(.semibold))
                        }

                        ForEach(recents.terms, id: \.self) { term in
                            Button {
                                viewModel.search(term: term)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .foregroundStyle(.secondary)
                                    Text(term)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: "arrow.up.left")
                                        .font(.footnote)
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 10)
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Browse Categories")
                        .font(.title2.bold())

                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                        spacing: 12
                    ) {
                        ForEach(categories, id: \.title) { category in
                            Button {
                                viewModel.search(term: category.title)
                            } label: {
                                CategoryTile(title: category.title, symbol: category.symbol, colors: category.colors)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(Theme.Spacing.gutter)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: Results

    private var results: some View {
        List {
            if !viewModel.videos.isEmpty {
                Section("Videos") {
                    ForEach(viewModel.videos) { video in
                        NavigationLink(value: video) {
                            VideoRowView(video: video)
                        }
                        .videoContextMenu(video)
                    }
                }
            }

            if !viewModel.channels.isEmpty {
                Section("Channels") {
                    ForEach(viewModel.channels) { channel in
                        NavigationLink(value: channel) {
                            ChannelRowView(channel: channel)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
    }
}

private struct CategoryTile: View {
    let title: String
    let symbol: String
    let colors: [Color]

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)

            Image(systemName: symbol)
                .font(.system(size: 46))
                .foregroundStyle(.white.opacity(0.25))
                .offset(x: 96, y: -14)

            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
                .padding(12)
        }
        .frame(height: 88)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

#Preview {
    NavigationStack { SearchView() }
        .environmentObject(LibraryStore.shared)
        .environmentObject(RecentSearchStore.shared)
}
