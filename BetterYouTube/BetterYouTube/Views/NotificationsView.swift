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
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                Button {
                                    Task {
                                        await watchLater.add(item.video)
                                        saveError = watchLater.errorMessage
                                    }
                                } label: {
                                    Label("Watch Later", systemImage: "clock.badge.plus")
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
                let missing = channelIDs.filter { channelAvatars[$0] == nil }
                guard !missing.isEmpty else { return }
                let fetched = await YouTubeAPIService.shared.channelAvatars(ids: missing)
                guard !Task.isCancelled else { return }
                channelAvatars.merge(fetched, uniquingKeysWith: { _, new in new })
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
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                            .overlay(Circle().stroke(Color.appBackground, lineWidth: 2))
                    }
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.channelTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(item.title)
                    .font(.footnote.weight(item.isRead ? .regular : .medium))
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                Text(RelativeDateFormatter.string(from: item.date))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)

            ArtworkView(url: item.thumbnailURL)
                .frame(width: 112, height: 63)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NotificationsView()
        .environmentObject(NotificationStore.shared)
        .environmentObject(NotificationService.shared)
        .environmentObject(GoogleAuthService.shared)
        .environmentObject(PlayerManager.shared)
}
