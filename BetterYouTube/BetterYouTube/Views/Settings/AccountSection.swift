import SwiftUI

/// The Google sign-in, and the account it bought you.
struct AccountSection: View {
    @EnvironmentObject private var auth: GoogleAuthService
    @EnvironmentObject private var watchLater: WatchLaterStore

    @State private var isSigningIn = false
    @State private var authError: String?
    /// The signed-in account's own YouTube channel, for the avatar and name at the top.
    @State private var account: Channel?

    var body: some View {
        Section {
            if auth.isSignedIn {
                signedIn
                cloudSetupLinks
            } else {
                cloudSetupLinks
                signedOut
            }
        } header: {
            Text("YouTube Account")
        } footer: {
            Text("""
            OAuth is recommended for browsing and account features; an API key is optional. \
            While the consent screen is in Testing, only accounts added under Test users can sign \
            in. Watch Later uses the separate youtube.com session. Watch history stays on this device.

            On the consent screen, tick the YouTube permission before Continue: left unticked, \
            Google issues a sign-in that can't do anything and the app has to throw it away.

            Passkeys don't work in the sign-in sheet — the system only offers them in Safari \
            itself. Sign in to Google in Safari first, with your passkey, and this sheet borrows \
            that session and won't ask for anything at all.
            """)
        }
        .task(id: auth.isSignedIn) {
            guard auth.isSignedIn else {
                account = nil
                return
            }
            account = try? await YouTubeAPIService.shared.myChannel()
        }
    }

    @ViewBuilder
    private var signedIn: some View {
        HStack(spacing: 14) {
            AvatarView(url: account?.thumbnailURL, size: 52)
                .artworkShadow()
            VStack(alignment: .leading, spacing: 3) {
                Text(account?.title ?? "Signed in with Google")
                    .font(.headline)
                    .lineLimit(1)
                Text(detail)
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
    }

    @ViewBuilder
    private var signedOut: some View {
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

        // Bound straight to the store rather than through a draft. There is no Save button here —
        // the field always wrote through on every keystroke — so the draft was only ever a second
        // copy to keep in step, and one the app reset had to reach in and clear.
#if os(macOS)
        TextField("OAuth ID", text: $auth.clientId)
            .identifierField()
            .onChange(of: auth.clientId) { _, _ in authError = nil }
#else
        TextField("Click here to add YouTube OAuth client ID", text: $auth.clientId)
            .identifierField()
            .onChange(of: auth.clientId) { _, _ in authError = nil }
#endif

        if let inputError = auth.clientIdInputError,
           case .clientIdIsURL = inputError {
            Text(inputError.localizedDescription)
                .font(.footnote)
                .foregroundStyle(.red)
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

    @ViewBuilder
    private var cloudSetupLinks: some View {
        Text("Google Cloud setup · select your project on each page")
            .font(.footnote)
            .foregroundStyle(.secondary)
        Link(destination: GoogleCloudSetupURL.youtubeDataAPI) {
            ExternalLinkLabel("Enable YouTube Data API v3")
        }
        Link(destination: GoogleCloudSetupURL.oauthClients) {
            ExternalLinkLabel("Create or find an OAuth client ID")
        }
        Link(destination: GoogleCloudSetupURL.oauthAudience) {
            ExternalLinkLabel("Add a test user (if Testing)")
        }
        Text("Choose an iOS client (also used on macOS) with this app's bundle ID: \(Bundle.main.bundleIdentifier ?? "com.atomtoto.BetterYouTube")")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
    }

    /// The channel's own numbers once they arrive; until then — or for a Google account with no
    /// channel of its own — what signing in bought you.
    private var detail: String {
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
