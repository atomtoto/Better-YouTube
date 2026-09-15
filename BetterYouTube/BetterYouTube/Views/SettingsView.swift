import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var apiKeyStore: APIKeyStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var watchLater: WatchLaterStore
    @EnvironmentObject private var auth: GoogleAuthService
    @EnvironmentObject private var notificationStore: NotificationStore
    @EnvironmentObject private var notifications: NotificationService
    @EnvironmentObject private var quota: QuotaTracker
    @EnvironmentObject private var webSession: YouTubeWebSession
    @EnvironmentObject private var downloadSettings: DownloadSettings
    @EnvironmentObject private var downloadStore: DownloadStore
    @EnvironmentObject private var downloadManager: DownloadManager

    @State private var draftKey: String = ""
    @State private var draftClientId: String = ""
    @State private var isSigningIn = false
    @State private var authError: String?
    @State private var didSaveKey = false
    /// The signed-in account's own YouTube channel, for the avatar and name at the top.
    @State private var account: Channel?
    @State private var showsTakeoutImporter = false
    @State private var importSummary: WatchLaterStore.ImportSummary?
    @State private var showsYouTubeSignIn = false
    @State private var isImportingBells = false
    @State private var bellImport: NotificationStore.YouTubeImport?
    @State private var showsResetConfirmation = false
    @State private var isResetting = false

    @State private var draftEndpoint: String = ""
    @State private var draftToken: String = ""
    @State private var didSaveDownloadSource = false
    @State private var showsRemoveDownloadsConfirmation = false

    var body: some View {
        Form {
            accountSection
            watchLaterSection
            notificationsSection
            apiKeySection
            quotaSection
            youTubeHomeSection
            downloadsSection

            Section("On This Device") {
                LabeledContent("Favorites", value: "\(library.favorites.count)")
                LabeledContent("Watch Later", value: "\(library.watchLater.count)")
                LabeledContent("History", value: "\(library.history.count)")
                Button("Clear Watch History", role: .destructive) {
                    library.clearHistory()
                }
                .disabled(library.history.isEmpty)
            }

            resetSection

            Section {
                LabeledContent("Version", value: "1.0")
                Text("An unofficial client built on the public YouTube Data API v3. Not affiliated with YouTube or Google.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("About")
            }
        }
        .minimizesPlayerBarOnScroll()
        .navigationTitle("Settings")
        // Takeout's CSVs arrive as plain text as often as with a CSV type, so accept both.
        .fileImporter(
            isPresented: $showsTakeoutImporter,
            allowedContentTypes: [.commaSeparatedText, .plainText, .text],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { importSummary = await watchLater.importTakeout(from: url) }
            case .failure(let error):
                importSummary = .init(failure: error.localizedDescription)
            }
        }
        .sheet(isPresented: $showsYouTubeSignIn) {
            YouTubeSignInView()
        }
        .onAppear {
            draftKey = apiKeyStore.apiKey
            draftClientId = auth.clientId
            draftEndpoint = downloadSettings.endpoint
            draftToken = downloadSettings.token
            // Catches the day turning over while the app sat in the background.
            quota.refresh()
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

    @ViewBuilder
    private var watchLaterSection: some View {
        Section {
            if auth.isSignedIn {
                LabeledContent("Playlist", value: WatchLaterStore.playlistTitle)

                let strays = watchLater.videosOnlyOnThisDevice.count
                if strays > 0 {
                    Button {
                        Task { await watchLater.uploadVideosOnlyOnThisDevice() }
                    } label: {
                        Text(strays == 1
                             ? "Add 1 video kept on this device"
                             : "Add \(strays) videos kept on this device")
                    }
                    .disabled(watchLater.isLoading)
                }
            }

            // Available signed out as well: the import lands on the device either way.
            Button {
                importSummary = nil
                showsTakeoutImporter = true
            } label: {
                HStack(spacing: 8) {
                    if watchLater.isLoading {
                        ProgressView().controlSize(.small)
                    }
                    Text("Import from Google Takeout…")
                }
            }
            .disabled(watchLater.isLoading)

            if let importSummary {
                Text(Self.describe(importSummary))
                    .font(.footnote)
                    // Both branches must be the same ShapeStyle, so spell out `Color`.
                    .foregroundStyle(importSummary.failure == nil ? Color.secondary : Color.red)
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
            YouTube's own Watch Later has been closed to apps since 2016. Signed in, this app keeps \
            a private playlist of its own instead — it syncs across your devices and appears in the \
            YouTube app like any other, at 50 of the 10,000 daily quota units per change, so \
            roughly 200 a day. To bring across what YouTube's list already holds, export it from \
            Google Takeout, unzip the archive, and import the CSV under “YouTube and YouTube \
            Music” → “playlists” — Watch Later exports as “Vidéos de Watch later.csv”, named in \
            your account's language. An import takes the \(WatchLaterStore.importLimit) most \
            recently added and leaves the rest. Imported videos land on this device; the button \
            above sends them up to the playlist.
            """)
        }
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

    /// The result of an import, in the terms someone reading it cares about.
    private static func describe(_ summary: WatchLaterStore.ImportSummary) -> String {
        if let failure = summary.failure { return failure }
        var parts = [summary.added == 1 ? "Added 1 video" : "Added \(summary.added) videos"]
        if summary.alreadyThere > 0 { parts.append("\(summary.alreadyThere) already saved") }
        if summary.missing > 0 { parts.append("\(summary.missing) no longer on YouTube") }
        // Say what was left behind, or a truncated import looks like a botched one.
        if summary.skippedOlder > 0 { parts.append("\(summary.skippedOlder) older ones skipped") }
        return parts.joined(separator: " · ")
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
                // Google ending the session looks from here like the app dropping it for no
                // reason, and the usual cause has a fix worth naming.
                if let reason = auth.lastSignOutReason {
                    Label {
                        Text(reason)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "clock.badge.exclamationmark")
                            .foregroundStyle(.orange)
                    }
                }

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

            On the consent screen, tick the YouTube permission before Continue: left unticked, \
            Google issues a sign-in that can't do anything and the app has to throw it away.

            Passkeys don't work in the sign-in sheet — iOS only offers them in Safari itself. \
            Sign in to Google in Safari first, with your passkey, and this sheet borrows that \
            session and won't ask for anything at all.
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

            // Only on offer with a web session: the bell lives on YouTube's pages and nowhere
            // in the API.
            if webSession.isSignedIn {
                Button {
                    isImportingBells = true
                    Task {
                        bellImport = await notificationStore.importFromYouTube()
                        isImportingBells = false
                    }
                } label: {
                    HStack(spacing: 8) {
                        if isImportingBells {
                            ProgressView().controlSize(.small)
                        }
                        Label("Import YouTube's Notifications", systemImage: "bell.badge")
                    }
                }
                .disabled(isImportingBells)

                if let bellImport {
                    Text(Self.describe(bellImport))
                        .font(.footnote)
                        .foregroundStyle(bellImport.failure == nil ? Color.secondary : Color.red)
                }
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("""
            Better YouTube checks your subscriptions for new uploads in the background and notifies \
            you locally — the Data API offers no push channel for personal accounts, so delivery \
            follows iOS's background-refresh schedule and the moment you open the app. Turn the \
            bell on from a channel page to pick individual channels.

            Which channels you gave the bell to on YouTube isn't in the API either — a \
            subscription says whether it covers uploads or everything, and nothing about the \
            bell's three settings. With a YouTube Home session signed in, the button above reads \
            your real notification inbox instead and takes the channels from it: a channel only \
            appears there because its bell is on. One gap comes with that — a channel that hasn't \
            uploaded recently has nothing in the inbox to be found by.
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

    @ViewBuilder
    private var quotaSection: some View {
        Section {
            QuotaGauge(quota: quota)

            // Where it went, biggest first — a single search is worth a hundred of anything else,
            // and that is only obvious once it is written down.
            ForEach(quota.breakdown.prefix(4)) { spend in
                LabeledContent(spend.title, value: spend.units.formatted())
            }

            if quota.used > 0 {
                Button("Reset Counter", role: .destructive) {
                    quota.reset()
                }
            }
        } header: {
            Text("API Quota")
        } footer: {
            Text("""
            The Data API gives a Cloud project \(QuotaTracker.dailyLimit.formatted()) units a day \
            and no way to ask what is left, so this is the app's own tally of what it has spent: \
            a search costs 100 units, every other read 1, and each change to the Watch Later \
            playlist 50. Anything else using the same API key spends from the same allowance \
            without appearing here. Google refills it at midnight Pacific time.
            """)
        }
    }

    /// Back to a fresh install. The confirmation names what goes rather than asking "are you
    /// sure" about an unnamed thing — the API key and both sign-ins are the parts people don't
    /// expect to lose, and they are the tedious ones to set up again.
    private var resetSection: some View {
        Section {
            Button("Reset App", role: .destructive) {
                showsResetConfirmation = true
            }
            .disabled(isResetting)
        } header: {
            Text("Reset")
        } footer: {
            Text("""
            Erases everything on this device: the API key and OAuth client ID, both sign-ins, \
            your favorites, Watch Later, watch history and recent searches, the notification \
            inbox and its channels, the quota tally, and every downloaded video along with the \
            download service's address. Your YouTube account itself is untouched — playlists, \
            subscriptions and likes all stay where they are.
            """)
        }
        .confirmationDialog(
            "Reset Better YouTube?",
            isPresented: $showsResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Erase Everything", role: .destructive) {
                isResetting = true
                Task {
                    await AppReset.eraseEverything()
                    draftKey = ""
                    draftClientId = ""
                    draftEndpoint = ""
                    draftToken = ""
                    didSaveDownloadSource = false
                    account = nil
                    bellImport = nil
                    importSummary = nil
                    didSaveKey = false
                    isResetting = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This device goes back to a fresh install. Nothing changes on your YouTube account.")
        }
    }

    /// Downloading, and the one thing about it worth being plain about: the app cannot do it
    /// alone, and this is where you say what should do it for it.
    ///
    /// No service ships with the app and none is suggested. Playback goes through YouTube's own
    /// embed, which never exposes a media file, so a download needs something that can resolve one
    /// — and which resolver to trust is the owner's call, not the app's. Running your own is also
    /// the only version that keeps working: a public instance goes dark, throttles you, or starts
    /// keeping a record of what you watch, while one on your own machine you can fix the day it
    /// breaks.
    @ViewBuilder
    private var downloadsSection: some View {
        Section {
            TextField("https://…", text: $draftEndpoint)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)

            SecureField("Bearer token (optional)", text: $draftToken)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Button("Save Download Service") {
                downloadSettings.endpoint = draftEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
                downloadSettings.token = draftToken.trimmingCharacters(in: .whitespacesAndNewlines)
                didSaveDownloadSource = true
            }
            .disabled(!hasDownloadSourceChanges)

            if didSaveDownloadSource {
                Label(
                    downloadSettings.isConfigured
                        ? "Saved"
                        : "Downloading is off — that isn't an http or https address",
                    systemImage: downloadSettings.isConfigured
                        ? "checkmark.circle.fill"
                        : "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(downloadSettings.isConfigured ? Color.green : Color.orange)
            }

            Picker("Quality", selection: $downloadSettings.quality) {
                ForEach(DownloadQuality.allCases) { quality in
                    Text(quality.title).tag(quality)
                }
            }

            Toggle("Download over Wi-Fi Only", isOn: $downloadSettings.wifiOnly)

            Picker("Storage Limit", selection: $downloadSettings.storageLimitGB) {
                Text("No limit").tag(0)
                ForEach([2, 4, 8, 16, 32, 64], id: \.self) { size in
                    Text("\(size) GB").tag(size)
                }
            }

            LabeledContent(
                "Storage Used",
                value: ByteCountFormatter.string(
                    fromByteCount: downloadStore.bytesOnDisk(),
                    countStyle: .file
                )
            )

            if !downloadStore.records.isEmpty {
                Button("Remove All Downloads", role: .destructive) {
                    showsRemoveDownloadsConfirmation = true
                }
            }
        } header: {
            Text("Downloads")
        } footer: {
            Text(Self.downloadsFooter)
        }
        .confirmationDialog(
            "Remove all downloads?",
            isPresented: $showsRemoveDownloadsConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove All", role: .destructive) { downloadManager.removeAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The files go from this device. Nothing changes on your YouTube account.")
        }
    }

    /// Kept out of the view builder: it is three paragraphs, and inlining it buries the section.
    private static let downloadsFooter = """
    Playback goes through YouTube's own embed, which never hands over a media file, so the app has \
    no way to fetch one by itself. Point this at a resolver you run and Download appears on every \
    video; leave it empty and downloading stays off.

    Two shapes work. An address carrying {id}, {videoId} or {url} is filled in and fetched \
    directly, so https://box.local/yt/{id}.mp4 is a complete setup. Anything else is sent a POST \
    of url, videoId, quality and maxHeight, and its reply is read for a media link — url, \
    downloadUrl, link, or the first entry of urls, formats or streams.

    Files land in Downloads, which the Files app shows under “Better YouTube”. They stay out of \
    iCloud backups, and a downloaded video plays from the file everywhere in the app, with no \
    network at all.
    """

    private var hasDownloadSourceChanges: Bool {
        draftEndpoint.trimmingCharacters(in: .whitespacesAndNewlines) != downloadSettings.endpoint
            || draftToken.trimmingCharacters(in: .whitespacesAndNewlines) != downloadSettings.token
    }

    /// The one part of the app that steps outside the Data API, and the section says so plainly.
    /// Nothing here is on until you sign in: without a session the Home screen doesn't even offer
    /// the segment.
    @ViewBuilder
    private var youTubeHomeSection: some View {
        Section {
            if webSession.isSignedIn {
                Label("Signed in to youtube.com", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)

                Picker("Show as", selection: $webSession.rendering) {
                    ForEach(YouTubeWebSession.FeedRendering.allCases) { rendering in
                        Text(rendering.title).tag(rendering)
                    }
                }

                Button("Sign Out of youtube.com", role: .destructive) {
                    Task { await webSession.signOut() }
                }
            } else {
                Button {
                    showsYouTubeSignIn = true
                } label: {
                    Label("Sign in to youtube.com", systemImage: "globe")
                }
            }
        } header: {
            Text("YouTube Home")
        } footer: {
            Text("""
            Your real home feed exists only on YouTube's own page: the Data API dropped the \
            personalized feed in 2016 and related videos in 2023. Signing in here opens \
            youtube.com in a web view and keeps its cookies on this device, apart from the Google \
            sign-in above — that one is a token scoped to the API, this one is a browser session. \
            The app reads the order of the videos on your home page and fetches everything it \
            shows about them through the API. That is outside what YouTube's terms allow apps to \
            do, it can break whenever the page changes, and it is your account that carries the \
            risk. Sign out here and the app forgets the session and the Home segment with it.
            """)
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

/// The day's allowance at a glance: what is left in figures, and how much has gone as a bar.
/// The bar warms from green through amber to red as the day's spending climbs, so the state
/// reads before the numbers do.
private struct QuotaGauge: View {
    @ObservedObject var quota: QuotaTracker

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(quota.remaining, format: .number)
                    .font(.system(.title, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("of \(QuotaTracker.dailyLimit.formatted()) units left")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }

            QuotaBar(fraction: quota.fraction, tint: tint)

            HStack(spacing: 8) {
                Text("\(quota.used.formatted()) spent today")
                Spacer(minLength: 0)
                Text("Resets at \(quota.resetDate.formatted(date: .omitted, time: .shortened))")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .animation(.snappy, value: quota.used)
    }

    /// Green while there is room, amber once three quarters have gone, red at the end.
    private var tint: Color {
        switch quota.fraction {
        case ..<0.75: return .green
        case ..<0.9: return .orange
        default: return .red
        }
    }
}

/// The bar itself: a capsule track with the spent share filled over it.
private struct QuotaBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color(uiColor: .tertiarySystemFill))
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.55), tint],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    // A few units in, the fill would be a sliver too thin to read as a shape;
                    // give it at least its own height so it starts as a dot rather than a line.
                    .frame(width: fraction > 0 ? max(10, proxy.size.width * fraction) : 0)
            }
        }
        .frame(height: 10)
        .accessibilityElement()
        .accessibilityLabel("Quota spent")
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
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
        .environmentObject(QuotaTracker.shared)
        .environmentObject(YouTubeWebSession.shared)
        .environmentObject(DownloadStore.shared)
        .environmentObject(DownloadManager.shared)
        .environmentObject(DownloadSettings.shared)
}
