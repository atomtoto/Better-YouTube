import SwiftUI
import UserNotifications

/// The bell screen: every new upload the app has announced, newest first.
struct NotificationsView: View {
    @EnvironmentObject private var store: NotificationStore
    @EnvironmentObject private var notifications: NotificationService
    @EnvironmentObject private var auth: GoogleAuthService
    @EnvironmentObject private var watchLater: WatchLaterStore
    @State private var saveError: String?
    @EnvironmentObject private var player: PlayerManager
    @Environment(\.dismiss) private var dismiss

    @State private var isRefreshing = false
    @State private var channelAvatars: [String: URL] = [:]

    private var channelIDs: [String] {
        Array(Set(store.items.map(\.channelId).filter { !$0.isEmpty })).sorted()
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.items.isEmpty {
                    EmptyStateView(
                        title: "No Notifications",
                        systemImage: "bell",
                        message: emptyMessage
                    )
                } else {
                    List {
                        ForEach(store.items) { item in
                            Button {
                                store.markRead(item)
                                dismiss()
                                Task { await player.open(videoId: item.videoId) }
                            } label: {
                                NotificationRow(item: item, avatarURL: channelAvatars[item.channelId])
                            }
                            .buttonStyle(.plain)
                            .videoContextMenu(item.video)
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                if !item.isRead {
                                    Button {
                                        store.markRead(item)
                                        Task { await notifications.updateBadge() }
                                    } label: {
                                        Label("Mark as Read", systemImage: "envelope.open")
                                    }
                                    .tint(.blue)
                                }
                                
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button {
                                    Task {
                                        await watchLater.add(item.video)
                                        saveError = watchLater.errorMessage
                                    }
                                } label: {
                                    Label("Watch Later", systemImage: "clock.fill")
                                }
                                .tint(.indigo)
                                .disabled(watchLater.pendingVideoIDs.contains(item.videoId))
                            }
                        }
                        .onDelete { store.remove(at: $0) }
                    }
                    .listStyle(.plain)
                    .refreshable { await refresh() }
                }
            }
            .alert("Watch Later", isPresented: Binding(
                get: { saveError != nil }, set: { if !$0 { saveError = nil } }
            )) {
                Button("OK", role: .cancel) { saveError = nil }
            } message: { Text(saveError ?? "") }
            .navigationTitle("Notifications")
            .inlineNavigationBar()
            .toolbar {
                #if os(macOS)
                ToolbarItem(placement: .primaryAction) {
                    RefreshButton { await refresh() }
                }
                #endif

                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            store.markAllRead()
                            Task { await notifications.updateBadge() }
                        } label: {
                            Label("Mark All as Read", systemImage: "envelope.open")
                        }
                        Button(role: .destructive) {
                            store.clear()
                            Task { await notifications.updateBadge() }
                        } label: {
                            Label("Clear All", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .disabled(store.items.isEmpty)
                }
            }
            .task {
                await notifications.refreshAuthorizationStatus()
                await notifications.updateBadge()
            }
            .task(id: channelIDs) {
                var initial: [String: URL] = [:]
                for id in channelIDs {
                    if let url = ChannelAvatarCache.shared.avatarURL(for: id) {
                        initial[id] = url
                    }
                }
                if !initial.isEmpty {
                    channelAvatars.merge(initial, uniquingKeysWith: { _, new in new })
                }
                let missing = channelIDs.filter { channelAvatars[$0] == nil }
                guard !missing.isEmpty else { return }
                let fetched = await YouTubeAPIService.shared.channelAvatars(ids: missing)
                guard !Task.isCancelled else { return }
                channelAvatars.merge(fetched, uniquingKeysWith: { _, new in new })
                ChannelAvatarCache.shared.setAvatarURLs(fetched)
            }
        }
    }

    private var emptyMessage: String {
        if !auth.isSignedIn {
            return "Sign in with Google to get notified when the channels you follow upload."
        }
        if !store.isEnabled {
            return "Turn on new video notifications in Settings to see uploads here."
        }
        return "You'll see new uploads from the channels you follow here."
    }

    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        if YouTubeWebSession.shared.isSignedIn {
            _ = await store.importFromYouTube()
        }
        await BackgroundRefresh.checkForNewVideos()
        isRefreshing = false
    }
}

private struct NotificationRow: View {
    let item: NotificationItem
    let avatarURL: URL?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            AvatarView(url: avatarURL, size: 40)
                .overlay(alignment: .bottomTrailing) {
                    if !item.isRead {
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 10, height: 10)
                            .overlay(Circle().stroke(Color(UIColor.systemBackground), lineWidth: 2))
                    }
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.subheadline.weight(item.isRead ? .regular : .semibold))
                    .lineLimit(2)
                    .foregroundStyle(.primary)

                HStack(spacing: 4) {
                    Text(item.channelTitle)
                        .lineLimit(1)
                    Text("·")
                    Text(RelativeDateFormatter.string(from: item.date))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            ArtworkView(url: item.video.thumbnailURL, duration: item.video.duration)
                .frame(width: 80, height: 45)
        }
        .padding(.vertical, 4)
    }
}
