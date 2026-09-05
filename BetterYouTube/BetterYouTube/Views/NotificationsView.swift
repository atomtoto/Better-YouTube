import SwiftUI
import UserNotifications

/// The bell screen: every new upload the app has announced, newest first.
struct NotificationsView: View {
    @EnvironmentObject private var store: NotificationStore
    @EnvironmentObject private var notifications: NotificationService
    @EnvironmentObject private var auth: GoogleAuthService
    @EnvironmentObject private var player: PlayerManager
    @Environment(\.dismiss) private var dismiss

    @State private var isRefreshing = false

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
                                NotificationRow(item: item)
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete { store.remove(at: $0) }
                    }
                    .listStyle(.plain)
                    .refreshable { await refresh() }
                }
            }
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
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
        await BackgroundRefresh.checkForNewVideos()
        isRefreshing = false
    }
}

private struct NotificationRow: View {
    let item: NotificationItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(item.isRead ? Color.clear : Color.red)
                .frame(width: 8, height: 8)
                .padding(.top, 6)

            ArtworkView(url: item.thumbnailURL)
                .frame(width: 104, height: 104 * 9 / 16)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.channelTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(item.title)
                    .font(.subheadline.weight(item.isRead ? .regular : .medium))
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                Text(RelativeDateFormatter.string(from: item.date))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)
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
