import SwiftUI

/// The Google sign-in, and the account it bought you.
///
/// Signed out, the pane reads top to bottom as the way in: what signing in is for, then the three
/// things it takes — a Google Cloud project, its client ID, and the sign-in itself. Signed in, it
/// is the account, the way out, and the Cloud project kept to hand for later.
struct AccountSection: View {
    @EnvironmentObject private var auth: GoogleAuthService
    @EnvironmentObject private var watchLater: WatchLaterStore
    @ObservedObject private var demo = DemoMode.shared

    @State private var isSigningIn = false
    @State private var authError: String?
    @State private var confirmsSignOut = false
    /// Open on a first visit, closed once a client ID is in place: by then the Cloud project
    /// exists, and the steps would only push the sign-in button down the screen.
    @State private var showsCloudSteps = GoogleAuthService.shared.redirectScheme == nil
    /// The signed-in account's own YouTube channel, for the avatar and name at the top.
    @State private var account: Channel?

    @ScaledMetric(relativeTo: .largeTitle) private var avatarSize = 84

    var body: some View {
        if demo.isActive {
            DemoSection()
        } else if auth.isSignedIn {
            signedIn
        } else {
            signedOut
        }
    }

    // MARK: Signed in

    @ViewBuilder
    private var signedIn: some View {
        Section {
            header(title: account?.title ?? String(localized: "Signed in with Google"), detail: detail) {
                AvatarView(url: account?.thumbnailURL, size: avatarSize)
                    .artworkShadow()
            }
        }
        .task {
            account = try? await YouTubeAPIService.shared.myChannel()
        }
        // The next account to sign in is not this one; don't show its picture meanwhile.
        .onDisappear { account = nil }

        Section {
            Label("Connected with Google", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)

            Button("Sign Out", role: .destructive) {
                confirmsSignOut = true
            }
            .confirmationDialog("Sign out of Google?", isPresented: $confirmsSignOut, titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) {
                    auth.signOut()
                    // The next account has a playlist of its own; drop this one's.
                    watchLater.reset()
                }
            } message: {
                Text("Your subscriptions, playlists and likes leave Library until you sign in again. Favorites, history and downloads aren't affected.")
            }
        } footer: {
            Text("Subscriptions, playlists and likes are in Library. Your YouTube Home feed and YouTube's Watch Later use a separate youtube.com sign-in, under YouTube Home.")
        }

        Section {
            DisclosureGroup("Google Cloud Project") {
                cloudSteps
            }
        } footer: {
            Text("If Google signs you out every seven days, the app is still in Testing in your Cloud project: publish it (step 4).")
        }
    }

    /// The channel's own numbers once they arrive; until then — or for a Google account with no
    /// channel of its own — what signing in bought you.
    private var detail: String {
        var parts: [String] = []
        if let subscribers = account?.subscriberCount {
            parts.append(CountFormatter.subscribers(subscribers))
        }
        if let videos = account?.videoCount {
            parts.append(CountFormatter.videos(videos))
        }
        return parts.isEmpty
            ? String(localized: "Google account")
            : parts.joined(separator: " · ")
    }

    // MARK: Signed out

    @ViewBuilder
    private var signedOut: some View {
        Section {
            header(
                title: String(localized: "Not Signed In"),
                detail: String(localized: "Sign in with Google for your subscriptions, playlists and likes.")
            ) {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .frame(width: avatarSize, height: avatarSize)
            }
        }

        // Google ending the session looks from here like the app dropping it for no
        // reason, and the usual cause has a fix worth naming.
        if let reason = auth.lastSignOutReason {
            Section {
                Label {
                    Text(reason)
                        .font(.footnote)
                } icon: {
                    Image(systemName: "clock.badge.exclamationmark")
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Why You Were Signed Out")
            }
        }

        Section {
            DisclosureGroup(isExpanded: $showsCloudSteps) {
                cloudSteps
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Prepare Google Cloud")
                        Text("Once, in a few minutes.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "checklist")
                        .foregroundStyle(.tint)
                }
            }
        } header: {
            Text("Step 1 · Google Cloud")
        } footer: {
            Text("Better YouTube reaches YouTube through your own Google Cloud project: it's free, and set up once. Choose the same project on each linked page.")
        }

        // Bound straight to the store rather than through a draft. There is no Save button here —
        // the field always wrote through on every keystroke — so the draft was only ever a second
        // copy to keep in step, and one the app reset had to reach in and clear.
        Section {
            TextField("OAuth client ID", text: $auth.clientId, prompt: Text("Paste your client ID"))
                .identifierField()
                .onChange(of: auth.clientId) { _, _ in authError = nil }
        } header: {
            Text("Step 2 · OAuth Client ID")
        } footer: {
            if let inputError = auth.clientIdInputError {
                Label(inputError.localizedDescription, systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
            } else if auth.redirectScheme != nil {
                Label("Client ID looks right.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Text("It ends in .apps.googleusercontent.com. You can find it under Google Cloud → Clients.")
            }
        }

        Section {
            Button(action: signIn) {
                Label {
                    Text("Sign in with Google")
                } icon: {
                    if isSigningIn {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "person.crop.circle.badge.plus")
                    }
                }
            }
            .disabled(isSigningIn || auth.redirectScheme == nil)

            if let authError {
                Label(authError, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Step 3 · Sign In")
        } footer: {
            if auth.redirectScheme == nil {
                Text("Paste your client ID above first.")
            } else {
                Text("""
                On Google's consent screen, tick the YouTube permission before Continue. \
                To use a passkey, sign in to Google in Safari first: this sheet reuses that session.
                """)
            }
        }
        .sensoryFeedback(.error, trigger: authError) { _, error in error != nil }
    }

    // MARK: Header

    /// The account at the top of the pane, centred the way the system's Settings shows its own:
    /// a picture, a name, one line under it.
    private func header(title: String, detail: String, @ViewBuilder picture: () -> some View) -> some View {
        VStack(spacing: 10) {
            picture()
                .accessibilityHidden(true)
            Text(title)
                .font(.title2.bold())
                .lineLimit(2)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .listRowBackground(Color.clear)
    }

    // MARK: Google Cloud

    /// The one-time setup in Google Cloud, the same steps first-run setup walks through, with the
    /// values to paste kept folded away until they're wanted.
    @ViewBuilder
    private var cloudSteps: some View {
        SetupLink(
            number: 1,
            title: "Enable YouTube Data API v3",
            detail: "Required for browsing and account features.",
            url: GoogleCloudSetupURL.youtubeDataAPI
        )
        SetupLink(
            number: 2,
            title: "Create an OAuth client ID",
            detail: "Choose the iOS application type, including on a Mac, with the bundle ID below.",
            url: GoogleCloudSetupURL.oauthClients
        )
        SetupLink(
            number: 3,
            title: "Fill in Branding",
            detail: "Paste the values below. Leave the logo empty.",
            url: GoogleCloudSetupURL.oauthBranding
        )
        SetupLink(
            number: 4,
            title: "Publish the app",
            detail: "Otherwise Google signs you out every seven days.",
            url: GoogleCloudSetupURL.oauthAudience
        )
        DisclosureGroup("Values to Paste") {
            CopyableValueRow(label: "Bundle ID", value: Bundle.main.bundleIdentifier ?? "com.atomtoto.BetterYouTube")
            ForEach(BrandingValue.allCases) { item in
                CopyableValueRow(label: item.field, value: item.value)
            }
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
