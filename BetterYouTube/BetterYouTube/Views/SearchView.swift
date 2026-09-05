import SwiftUI

/// Search with the field pinned to the bottom, within thumb reach. Opening the tab does exactly
/// two things: raise the keyboard and show recent searches — nothing is fetched until you ask.
struct SearchView: View {
    @EnvironmentObject private var recents: RecentSearchStore
    @StateObject private var viewModel = SearchViewModel()
    @FocusState private var isFieldFocused: Bool

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
        .background(Color(uiColor: .systemBackground))
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { searchField }
        .navigationDestination(for: Video.self) { VideoDetailView(video: $0) }
        .navigationDestination(for: Channel.self) { ChannelView(channelId: $0.id, initialChannel: $0) }
        .onAppear { isFieldFocused = true }
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

                TextField("Search videos and channels", text: $viewModel.query)
                    .focused($isFieldFocused)
                    .submitLabel(.search)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
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
            .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
            .overlay(
                Capsule().strokeBorder(
                    isFieldFocused ? Color.accentColor.opacity(0.4) : Color.clear,
                    lineWidth: 1.5
                )
            )
            .animation(.easeInOut(duration: 0.15), value: isFieldFocused)
            .animation(.easeInOut(duration: 0.15), value: viewModel.query.isEmpty)

            Button(action: submit) {
                Image(systemName: "arrow.right")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(canSubmit ? Color.accentColor : Color(uiColor: .tertiarySystemFill), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .animation(.easeInOut(duration: 0.15), value: canSubmit)
            .accessibilityLabel("Search")
        }
        .padding(.horizontal, Theme.Spacing.gutter)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func submit() {
        viewModel.submit()
        isFieldFocused = false
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
            }
        }
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
        .scrollDismissesKeyboard(.immediately)
    }
}

#Preview {
    NavigationStack { SearchView() }
        .environmentObject(LibraryStore.shared)
        .environmentObject(RecentSearchStore.shared)
}
