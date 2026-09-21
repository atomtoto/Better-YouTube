import SwiftUI

/// New uploads, and the two things the API won't tell the app: when they happen, and which
/// channels you gave the bell to.
struct NotificationsSection: View {
    @EnvironmentObject private var auth: GoogleAuthService
    @EnvironmentObject private var notificationStore: NotificationStore
    @EnvironmentObject private var notifications: NotificationService
    @EnvironmentObject private var webSession: YouTubeWebSession

    var body: some View {
        Section {
            Picker("New videos", selection: $notificationStore.mode) {
                ForEach(NotificationMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .onChange(of: notificationStore.mode) { _, mode in
                guard mode != .off else { return }
                Task {
                    if notifications.authorizationStatus == .notDetermined {
                        await notifications.requestAuthorization()
                    }
                }
            }

            if notificationStore.mode == .selected {
                LabeledContent("Channels with the bell on", value: "\(notificationStore.channelOptIns.count)")
            }

            if notificationStore.isEnabled && notifications.authorizationStatus == .denied {
                Button {
                    Platform.openNotificationSettings()
                } label: {
                    Label(
                        "Allow notifications in \(Platform.settingsAppName)",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                }
            }

            Button {
                Task { await BackgroundRefresh.checkForNewVideos() }
            } label: {
                Label("Check for New Videos Now", systemImage: "arrow.clockwise")
            }
            .disabled(!notificationStore.isEnabled || !auth.isSignedIn)

            // Only on offer with a web session: the bell lives on YouTube's pages and nowhere
            // in the API.
            if webSession.isSignedIn {
                Toggle("Automatically Import YouTube Notifications", isOn: $notificationStore.automaticallyImportYouTube)
                Text("Refreshes every 15 minutes while the app is active. An unsuccessful import is retried after a minute.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let date = notificationStore.lastYouTubeImportDate {
                    LabeledContent("Last import", value: date.formatted(date: .abbreviated, time: .shortened))
                }
                Button {
                    Task {
                        _ = await notificationStore.importFromYouTube()
                    }
                } label: {
                    HStack(spacing: 8) {
                        if notificationStore.isImportingYouTube {
                            ProgressView().controlSize(.small)
                        }
                        Label("Import YouTube's Notifications", systemImage: "bell.badge")
                    }
                }
                .disabled(notificationStore.isImportingYouTube)

                if let bellImport = notificationStore.lastYouTubeImport {
                    Text(Self.describe(bellImport))
                        .font(.footnote)
                        .foregroundStyle(bellImport.failure == nil ? Color.secondary : Color.red)
                }
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text(Self.footer)
        }
    }

    /// The schedule is the platform's, so the sentence describing it is too.
    private static var footer: String {
        #if os(macOS)
        let delivery = "delivery follows a check the app runs every couple of hours while it is open, "
            + "plus the moment you bring it to the front"
        #else
        let delivery = "delivery follows iOS's background-refresh schedule and the moment you open the app"
        #endif
        return """
        Better YouTube checks your subscriptions for new uploads and notifies you locally — the \
        Data API offers no push channel for personal accounts, so \(delivery). Turn the bell on \
        from a channel page to pick individual channels.

        Which channels you gave the bell to on YouTube isn't in the API either — a subscription \
        says whether it covers uploads or everything, and nothing about the bell's three \
        settings. With a YouTube Home session signed in, the button above reads your real \
        notification inbox instead and takes the channels from it: a channel only appears there \
        because its bell is on. One gap comes with that — a channel that hasn't uploaded recently \
        has nothing in the inbox to be found by.
        """
    }

    /// What came back from YouTube's notification inbox.
    private static func describe(_ summary: NotificationStore.YouTubeImport) -> String {
        if let failure = summary.failure { return failure }
        guard summary.channels > 0 else { return "Nothing in YouTube's notifications yet." }
        let channels = summary.channels == 1
            ? "1 channel with the bell on"
            : "\(summary.channels) channels with the bell on"
        return summary.notifications == 0
            ? "\(channels) · nothing new to add"
            : "\(channels) · \(summary.notifications) added to the inbox"
    }
}
