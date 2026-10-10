import SwiftUI

/// Search with the field pinned to the bottom, within thumb reach. Opening the tab does exactly
/// two things: raise the keyboard and show recent searches — nothing is fetched until you ask.
struct SearchView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var recents: RecentSearchStore
    @StateObject private var viewModel = SearchViewModel()
    @FocusState private var isFieldFocused: Bool
    /// A channel or playlist opened from a pasted link, pushed onto Search's own stack.
    @State private var linkedChannel: Channel?
    @State private var linkedPlaylist: Playlist?
    @State private var linkError: String?

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
                recentSearches
            } else {
                results
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground)
        // Tapping anywhere outside the field puts the keyboard away. Simultaneous so rows and
        // buttons still receive their own taps.
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { isFieldFocused = false })
        .navigationTitle("Search")
        .inlineNavigationBar()
        // Bottom on a phone, top on a Mac — see `searchFieldInset`.
        .searchFieldInset { searchField }
        .navigationDestination(for: Channel.self) { ChannelView(channelId: $0.id, initialChannel: $0) }
        .navigationDestination(item: $linkedChannel) { channel in
            ChannelView(channelId: channel.id, initialChannel: channel.title.isEmpty ? nil : channel)
        }
        .navigationDestination(item: $linkedPlaylist) { PlaylistDetailView(playlist: $0) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { filtersMenu }
        }
        .alert("Couldn't Open Link", isPresented: Binding(
            get: { linkError != nil },
            set: { if !$0 { linkError = nil } }
        )) {
            Button("OK", role: .cancel) { linkError = nil }
        } message: {
            Text(linkError ?? "")
        }
        .onAppear { isFieldFocused = true }
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

    // MARK: Bottom search field

    private var canSubmit: Bool {
        !viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isFieldFocused ? Color.accentColor : .secondary)
                    .animation(.easeInOut(duration: 0.15), value: isFieldFocused)

                TextField("Search or paste a YouTube link", text: $viewModel.query)
                    .focused($isFieldFocused)
                    .submitLabel(.search)
                    .identifierField()
                    .textFieldStyle(.plain)
                    .onSubmit(submit)

                if !viewModel.query.isEmpty {
                    Button {
                        viewModel.clear()
                        isFieldFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity.combined(with: .scale(scale: 0.7)))
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(Color.appSecondaryBackground, in: Capsule())
            .overlay(
                Capsule().strokeBorder(
                    isFieldFocused ? Color.accentColor.opacity(0.4) : Color.clear,
                    lineWidth: 1.5
                )
            )
            .animation(.easeInOut(duration: 0.15), value: isFieldFocused)
            .animation(.easeInOut(duration: 0.15), value: viewModel.query.isEmpty)

            Button(action: submit) {
                // A link is opened rather than searched for, and the button says which.
                Image(systemName: viewModel.link == nil ? "arrow.right" : "arrow.up.forward")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(canSubmit ? Color.accentColor : Color.appTertiaryFill, in: Circle())
                    .contentShape(Circle())
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .animation(.easeInOut(duration: 0.15), value: canSubmit)
            .accessibilityLabel(viewModel.link == nil ? "Search" : "Open Link")
        }
        .padding(.horizontal, Theme.Spacing.gutter)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func submit() {
        isFieldFocused = false
        if let link = viewModel.link {
            open(link)
        } else {
            viewModel.submit()
        }
    }

    /// A pasted link goes straight to what it names — one unit at most, against the 100 a
    /// search for it would cost, and exactly the thing that was shared.
    private func open(_ link: YouTubeLink) {
        switch link {
        case .video(let id, let start):
            Task { await player.open(videoId: id, startTime: start) }
        case .playlist(let id):
            linkedPlaylist = Playlist(id: id, title: "", description: "", thumbnailURL: nil)
        case .channel(let id):
            linkedChannel = Channel(id: id, title: "", description: "", thumbnailURL: nil)
        case .handle(let handle):
            Task {
                do {
                    if let channel = try await YouTubeAPIService.shared.channel(handle: handle) {
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

    // MARK: Recents

    private var recentSearches: some View {
        Group {
            if recents.terms.isEmpty {
                EmptyStateView(
                    title: "Search YouTube",
                    systemImage: "magnifyingglass",
                    message: "Look for videos and channels. Your recent searches will show up here."
                )
            } else {
                List {
                    Section {
                        ForEach(recents.terms, id: \.self) { term in
                            Button {
                                viewModel.search(term: term)
                                isFieldFocused = false
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

#Preview {
    NavigationStack { SearchView() }
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
