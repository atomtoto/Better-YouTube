import SwiftUI

/// Search, in the system's own search field: along the bottom on a phone, where the search tab
/// turns into it, and in the window's toolbar on a Mac. Opening the tab raises the keyboard and
/// shows recent searches — nothing is fetched until you ask.
struct SearchView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var recents: RecentSearchStore
    /// Owned by the root view, which runs searches from links and Siri and puts the field away
    /// when a link leaves the search tab.
    @ObservedObject var viewModel: SearchViewModel
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        Group {
            if viewModel.isSearching && viewModel.results.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let message = viewModel.errorMessage, viewModel.results.isEmpty {
                ContentUnavailableView("Search Failed", systemImage: "exclamationmark.triangle", description: Text(message))
            } else if viewModel.results.isEmpty && viewModel.hasSearched {
                ContentUnavailableView(
                    "No Results",
                    systemImage: "magnifyingglass",
                    description: Text("Try a different search term.")
                )
            } else if viewModel.results.isEmpty {
                recentSearches
            } else {
                results
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground)
        .searchFocused($isFieldFocused)
        .navigationTitle("Search")
        .searchField(viewModel)
        // A search on its way — submitted, a suggestion or a recent search tapped, a filter
        // changed — puts the keyboard away, so the results it brings are not hidden behind it.
        .onChange(of: viewModel.isSearching) { _, searching in
            if searching { isFieldFocused = false }
        }
        .navigationDestination(for: Channel.self) { ChannelView(channelId: $0.id, initialChannel: $0) }
        .navigationDestination(item: $viewModel.linkedChannel) { channel in
            ChannelView(channelId: channel.id, initialChannel: channel.title.isEmpty ? nil : channel)
        }
        .navigationDestination(item: $viewModel.linkedPlaylist) { PlaylistDetailView(playlist: $0) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { filtersMenu }
        }
        .alert("Couldn't Open Link", isPresented: Binding(
            get: { viewModel.linkError != nil },
            set: { if !$0 { viewModel.linkError = nil } }
        )) {
            Button("OK", role: .cancel) { viewModel.linkError = nil }
        } message: {
            Text(viewModel.linkError ?? "")
        }
        .onAppear {
            // Ready to type on arrival — unless there is a search to show: results to come back
            // to, or one already on its way from Siri, Shortcuts or a link, which the keyboard
            // and its suggestions would only cover.
            if viewModel.results.isEmpty, !viewModel.isSearching, !viewModel.hasSearched {
                isFieldFocused = true
            }
        }
    }

    // MARK: Filters

    /// YouTube's filter sheet, as the menu a toolbar holds: each picker is a submenu showing its
    /// current choice. They narrow the same 100-unit search, so they cost nothing extra.
    private var filtersMenu: some View {
        Menu {
            Picker(selection: $viewModel.filters.order) {
                ForEach(SearchFilters.Order.allCases) { Text($0.title).tag($0) }
            } label: {
                Label("Sort By", systemImage: "arrow.up.arrow.down")
            }
            .pickerStyle(.menu)

            Picker(selection: $viewModel.filters.duration) {
                ForEach(SearchFilters.Duration.allCases) { Text($0.title).tag($0) }
            } label: {
                Label("Duration", systemImage: "timer")
            }
            .pickerStyle(.menu)

            Picker(selection: $viewModel.filters.uploadDate) {
                ForEach(SearchFilters.UploadDate.allCases) { Text($0.title).tag($0) }
            } label: {
                Label("Upload Date", systemImage: "calendar")
            }
            .pickerStyle(.menu)

            if !viewModel.filters.isDefault {
                Divider()
                Button("Reset Filters", systemImage: "arrow.counterclockwise") {
                    viewModel.filters = SearchFilters()
                }
            }
        } label: {
            Label(
                "Filters",
                systemImage: viewModel.filters.isDefault
                    ? "line.3.horizontal.decrease.circle"
                    : "line.3.horizontal.decrease.circle.fill"
            )
        }
    }

    // MARK: Recents

    private var recentSearches: some View {
        Group {
            if recents.terms.isEmpty {
                ContentUnavailableView(
                    "Search YouTube",
                    systemImage: "magnifyingglass",
                    description: Text("Look for videos and channels, or paste a YouTube link to open it. Your recent searches will show up here.")
                )
            } else {
                List {
                    Section {
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
                                    Button {
                                        viewModel.query = term
                                        isFieldFocused = true
                                    } label: {
                                        Image(systemName: "arrow.up.left")
                                            .font(.footnote)
                                            .foregroundStyle(.tertiary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button(role: .destructive) {
                                    recents.remove(term)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text("Recent Searches")
                            Spacer()
                            Button("Clear") { recents.clear() }
                                .font(.caption.weight(.semibold))
                                .textCase(nil)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollDismissesKeyboard(.interactively)
                .minimizesPlayerBarOnScroll()
            }
        }
    }

    // MARK: Results

    /// A further page is another full search's worth of quota, so it is asked for, not scrolled
    /// into.
    private var moreResults: some View {
        VStack(spacing: 8) {
            Button {
                Task { await viewModel.loadMore() }
            } label: {
                if viewModel.isLoadingMore {
                    ProgressView()
                } else {
                    Text("More Results")
                }
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isLoadingMore)

            if let error = viewModel.loadMoreError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var results: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if !viewModel.videos.isEmpty {
                    Text("Videos")
                        .font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280, maximum: 440), spacing: 18)], spacing: 24) {
                        ForEach(viewModel.videos) { video in
                            FeedVideoCard(video: video, onPlay: {
                                player.play(video, upNext: viewModel.videos.after(video))
                            })
                            .videoContextMenu(video)
                        }
                    }
                }

                if !viewModel.channels.isEmpty {
                    Text("Channels")
                        .font(.headline)
                    ForEach(viewModel.channels) { channel in
                        NavigationLink(value: channel) {
                            ChannelRowView(channel: channel)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if viewModel.canLoadMore {
                    moreResults
                }
            }
            .padding(Theme.Spacing.gutter)
        }
        .scrollDismissesKeyboard(.immediately)
        .minimizesPlayerBarOnScroll()
    }
}

// MARK: - The field

extension View {
    /// Search's field, what it suggests and what its Search key does. On the Search screen itself:
    /// a phone's search tab turns into it along the bottom, and a Mac keeps it in the toolbar. On
    /// the tab view instead, the field spread to every tab, and stayed open over Home when a link
    /// moved there mid-search.
    func searchField(_ viewModel: SearchViewModel) -> some View {
        modifier(SearchField(viewModel: viewModel))
    }
}

private struct SearchField: ViewModifier {
    @ObservedObject var viewModel: SearchViewModel
    @EnvironmentObject private var recents: RecentSearchStore

    func body(content: Content) -> some View {
        content
            .searchable(text: $viewModel.query, isPresented: $viewModel.isPresented, placement: .searchTab,
                        prompt: "Search or paste a YouTube link")
            .searchSuggestions { suggestions }
            .onSubmit(of: .search) { viewModel.submitOrOpen() }
            .onChange(of: viewModel.query) { _, query in viewModel.queryChanged(query) }
    }

    /// What the field offers while you type: the link you pasted, ready to open, or the recent
    /// searches that match followed by YouTube's own suggestions.
    @ViewBuilder
    private var suggestions: some View {
        if viewModel.link != nil {
            Button {
                viewModel.submitOrOpen()
            } label: {
                Label("Open Link", systemImage: "arrow.up.forward.app")
            }
        } else {
            ForEach(viewModel.suggestions(recents: recents.terms)) { suggestion in
                Button {
                    viewModel.search(term: suggestion.text)
                } label: {
                    // Text in the primary colour and a grey symbol, as the system's own search
                    // suggestions are drawn — a tinted list reads as a list of links.
                    Label {
                        Text(suggestion.text)
                    } icon: {
                        Image(systemName: suggestion.isRecent ? "clock.arrow.circlepath" : "magnifyingglass")
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(.primary)
            }
        }
    }
}

#Preview {
    NavigationStack { SearchView(viewModel: SearchViewModel()) }
        .environmentObject(LibraryStore.shared)
        .environmentObject(WatchLaterStore.shared)
        .environmentObject(RecentSearchStore.shared)
        .environmentObject(DownloadStore.shared)
        .environmentObject(DownloadManager.shared)
        .environmentObject(DownloadSettings.shared)
        .environmentObject(PlayerManager.shared)
}

// MARK: - Filter names

extension SearchFilters.Order {
    var title: String {
        switch self {
        case .relevance: String(localized: "Relevance")
        case .date: String(localized: "Upload Date", comment: "Search sort order: newest first")
        case .viewCount: String(localized: "View Count")
        case .rating: String(localized: "Rating")
        }
    }
}

extension SearchFilters.Duration {
    var title: String {
        switch self {
        case .any: String(localized: "Any Length")
        case .short: String(localized: "Under 4 Minutes")
        case .medium: String(localized: "4–20 Minutes")
        case .long: String(localized: "Over 20 Minutes")
        }
    }
}

extension SearchFilters.UploadDate {
    var title: String {
        switch self {
        case .any: String(localized: "Any Time")
        case .today: String(localized: "Today")
        case .week: String(localized: "This Week")
        case .month: String(localized: "This Month")
        case .year: String(localized: "This Year")
        }
    }
}
