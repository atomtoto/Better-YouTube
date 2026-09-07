import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var apiKeyStore: APIKeyStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var watchLater: WatchLaterStore
    @EnvironmentObject private var auth: GoogleAuthService
    @EnvironmentObject private var notificationStore: NotificationStore
    @EnvironmentObject private var notifications: NotificationService

    @State private var draftKey: String = ""
    @State private var draftClientId: String = ""
    @State private var isSigningIn = false
    @State private var authError: String?
    @State private var didSaveKey = false
    /// The signed-in account's own YouTube channel, for the avatar and name at the top.
    @State private var account: Channel?

    var body: some View {
        Form {
            accountSection
            watchLaterSection
            notificationsSection
            apiKeySection

            Section("On This Device") {
                LabeledContent("Favorites", value: "\(library.favorites.count)")
                LabeledContent("Watch Later", value: "\(library.watchLater.count)")
                LabeledContent("History", value: "\(library.history.count)")
                Button("Clear Watch History", role: .destructive) {
                    library.clearHistory()
                }
                .disabled(library.history.isEmpty)
            }

            Section {
                LabeledContent("Version", value: "1.0")
                Text("An unofficial client built on the public YouTube Data API v3. Not affiliated with YouTube or Google.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("About")
            } footer: {
                Text("Quota tip: each search costs 100 of the 10,000 daily API units, while browsing channels, playlists and video details costs 1 unit per request.")
            }
        }
        .minimizesPlayerBarOnScroll()
        .navigationTitle("Settings")
        .onAppear {
            draftKey = apiKeyStore.apiKey
            draftClientId = auth.clientId
        }
        .task(id: auth.isSignedIn) {
            guard auth.isSignedIn else {
                account = nil
                return
            }
            account = try? await YouTubeAPIService.shared.myChannel()
        }
    }

    /// The channel's own numbers once they arrive; until then — or for a Google account with no
    /// channel of its own — what signing in bought you.
    private var accountDetail: String {
        var parts: [String] = []
        if let subscribers = account?.subscriberCount {
            parts.append("\(CountFormatter.abbreviated(subscribers)) subscribers")
        }
        if let videos = account?.videoCount {
            parts.append("\(CountFormatter.abbreviated(videos)) videos")
        }
        return parts.isEmpty
            ? "Subscriptions, playlists and likes are available in Library."
            : parts.joined(separator: " · ")
    }

    // MARK: Sections

    /// Only meaningful signed in: without an account there is no playlist, just this device's list.
    @ViewBuilder
    private var watchLaterSection: some View {
        if auth.isSignedIn {
            Section {
                LabeledContent("Playlist", value: WatchLaterStore.playlistTitle)

                let strays = watchLater.videosOnlyOnThisDevice.count
                if strays > 0 {
                    Button {
                        Task { await watchLater.uploadVideosOnlyOnThisDevice() }
                    } label: {
                        HStack(spacing: 8) {
                            if watchLater.isLoading {
                                ProgressView().controlSize(.small)
                            }
                            Text(strays == 1
                                 ? "Add 1 video kept on this device"
                                 : "Add \(strays) videos kept on this device")
                        }
                    }
                    .disabled(watchLater.isLoading)
                }

                if let message = watchLater.errorMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Watch Later")
            } footer: {
                Text("""
                YouTube's own Watch Later has been closed to apps since 2016, so this app keeps a \
                private playlist of its own instead. It syncs across your devices and appears in \
                the YouTube app like any other playlist. Adding or removing a video costs 50 of \
                the 10,000 daily quota units, so roughly 200 changes a day.
                """)
            }
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        Section {
            if auth.isSignedIn {
                HStack(spacing: 14) {
                    AvatarView(url: account?.thumbnailURL, size: 52)
                        .artworkShadow()
                    VStack(alignment: .leading, spacing: 3) {
                        Text(account?.title ?? "Signed in with Google")
                            .font(.headline)
                            .lineLimit(1)
                        Text(accountDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(.vertical, 4)

                Button("Sign Out", role: .destructive) {
                    auth.signOut()
                    // The next account has a playlist of its own; drop this one's.
                    watchLater.reset()
                }
            } else {
                TextField("OAuth client ID (iOS)", text: $draftClientId)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: draftClientId) { newValue in
                        auth.clientId = newValue
                    }

                Button {
                    signIn()
                } label: {
                    HStack {
                        if isSigningIn {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "person.crop.circle.badge.plus")
                        }
                        Text("Sign in with Google")
                    }
                }
                .disabled(isSigningIn || auth.redirectScheme == nil)

                if let authError {
                    Text(authError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        } header: {
            Text("YouTube Account")
        } footer: {
            Text("""
            Optional. In the Google Cloud Console: create an OAuth 2.0 client ID of type iOS, then \
            open Google Auth Platform → Audience and add your own Google account under Test users — \
            while the consent screen is in Testing, every other account is refused with \
            "access_denied". Paste the client ID above to read your subscriptions, playlists and \
            liked videos, and to keep your Watch Later as a playlist on your account. Watch history is \
            not available through the API, so that list stays on this device.
            """)
        }
    }

    @ViewBuilder
    private var notificationsSection: some View {
        Section {
            Picker("New videos", selection: $notificationStore.mode) {
                ForEach(NotificationMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .onChange(of: notificationStore.mode) { mode in
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
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("Allow notifications in iOS Settings", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            Button {
                Task { await BackgroundRefresh.checkForNewVideos() }
            } label: {
                Label("Check for New Videos Now", systemImage: "arrow.clockwise")
            }
            .disabled(!notificationStore.isEnabled || !auth.isSignedIn)
        } header: {
            Text("Notifications")
        } footer: {
            Text("""
            Better YouTube checks your subscriptions for new uploads in the background and notifies \
            you locally — the Data API offers no push channel for personal accounts, so delivery \
            follows iOS's background-refresh schedule and the moment you open the app. Turn the \
            bell on from a channel page to pick individual channels.
            """)
        }
    }

    private var apiKeySection: some View {
        Section {
            TextField("API key", text: $draftKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Button("Save Key") {
                apiKeyStore.apiKey = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
                didSaveKey = true
            }
            .disabled(draftKey.trimmingCharacters(in: .whitespacesAndNewlines) == apiKeyStore.apiKey)

            if didSaveKey {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.green)
            }
        } header: {
            Text("YouTube Data API v3 Key")
        } footer: {
            Text("Enable the YouTube Data API v3 in the Google Cloud Console and create an API key credential. The key is stored only on this device.")
        }
    }

    private func signIn() {
        isSigningIn = true
        authError = nil
        Task {
            do {
                try await auth.signIn()
            } catch {
                authError = error.localizedDescription
            }
            isSigningIn = false
        }
    }
}

#Preview {
    NavigationStack { SettingsView() }
        .environmentObject(APIKeyStore.shared)
        .environmentObject(LibraryStore.shared)
        .environmentObject(WatchLaterStore.shared)
        .environmentObject(GoogleAuthService.shared)
        .environmentObject(NotificationStore.shared)
        .environmentObject(NotificationService.shared)
}
