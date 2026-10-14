import SwiftUI

/// First-run setup, as a short run of native screens: a welcome, then one decision per screen.
///
/// Each screen is pushed onto a navigation stack of its own, so going back is the system's back
/// button and swipe rather than a step counter, and every screen is a grouped form — the same
/// shape as Settings, where all of this can be changed later. The buttons that move forward sit
/// in a bar along the bottom, within thumb reach, which the content scrolls under.
struct OnboardingView: View {
    let onFinish: () -> Void

    @EnvironmentObject private var apiKeyStore: APIKeyStore
    @EnvironmentObject private var auth: GoogleAuthService

    enum Step: Hashable {
        case cloud, google, apiKey, home
    }

    @State private var path: [Step] = []

    var body: some View {
        NavigationStack(path: $path) {
            WelcomeStep(path: $path, later: onFinish)
                .navigationDestination(for: Step.self) { step in
                    switch step {
                    case .cloud: CloudStep(path: $path, later: onFinish)
                    case .google: GoogleStep(path: $path, later: onFinish)
                    case .apiKey: APIKeyStep(path: $path, later: onFinish)
                    case .home: HomeStep(onFinish: onFinish)
                    }
                }
        }
        .onAppear {
            // Already connected — an update to an existing install, or a reset that kept nothing
            // but the sign-in: only the optional last step is left.
            if path.isEmpty, auth.isSignedIn || apiKeyStore.hasKey {
                path = [.home]
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 640, idealHeight: 700)
        #endif
    }
}

// MARK: - The screens

/// What the app is, and the two ways into it.
private struct WelcomeStep: View {
    @Binding var path: [OnboardingView.Step]
    let later: () -> Void

    var body: some View {
        OnboardingPage(
            symbol: "play.rectangle.fill",
            title: "Welcome to Better YouTube",
            subtitle: "A calmer way to browse. Set up access in a few short steps.",
            later: later
        ) {
            Section {
                FeatureRow(
                    symbol: "person.crop.circle.badge.checkmark",
                    title: "Connect Google",
                    detail: "OAuth lets you browse and access your subscriptions, playlists and likes. No separate API key is needed."
                )
                FeatureRow(
                    symbol: "sparkles.tv",
                    title: "Add YouTube Home",
                    detail: "A separate, optional youtube.com connection brings in your personal feed and Watch Later."
                )
                FeatureRow(
                    symbol: "icloud",
                    title: "Your library everywhere",
                    detail: "Favorites, Watch Later, history and where you stopped follow you across your Apple devices."
                )
                FeatureRow(
                    symbol: "arrow.down.circle",
                    title: "Watch offline",
                    detail: "Downloaded videos play anywhere in the app, even with no network."
                )
            } footer: {
                Text("You can also choose an API key for public videos, or try the app first with a demo catalogue — no account needed.")
            }
        } actions: {
            Button {
                path.append(.cloud)
            } label: {
                Text("Set Up Google")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Button {
                path.append(.apiKey)
            } label: {
                Text("Use an API key instead")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            // No account and no key: real videos from a catalogue built into the app.
            Button("Try Without Signing In") {
                DemoMode.shared.enter()
                later()
            }
            .buttonStyle(.borderless)
            .font(.subheadline.weight(.semibold))
        }
    }
}

/// The Google Cloud side, which has to exist before anything can sign in.
private struct CloudStep: View {
    @Binding var path: [OnboardingView.Step]
    let later: () -> Void

    private var bundleID: String {
        Bundle.main.bundleIdentifier ?? "com.atomtoto.BetterYouTube"
    }

    var body: some View {
        OnboardingPage(
            symbol: "checklist",
            title: "Prepare Google Cloud",
            subtitle: "Enable the API and create an OAuth client in your Google Cloud project.",
            later: later
        ) {
            Section {
                SetupLink(
                    number: 1,
                    title: "Enable YouTube Data API v3",
                    detail: "Required for browsing and account features.",
                    url: GoogleCloudSetupURL.youtubeDataAPI
                )
                SetupLink(
                    number: 2,
                    title: "Create an OAuth client ID",
                    detail: "Choose the iOS application type, including on a Mac.",
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
            } footer: {
                Text("Choose the same Google Cloud project on each linked page.")
            }

            Section {
                CopyableValueRow(value: bundleID)
            } header: {
                Text("Use this bundle ID")
            } footer: {
                Text("Paste it into the OAuth client's Bundle ID field.")
            }

            Section {
                ForEach(BrandingValue.allCases) { item in
                    CopyableValueRow(label: item.field, value: item.value)
                }
            } header: {
                Text("Branding")
            } footer: {
                Text("""
                Google won't publish the app without these. At sign-in it then shows "Google \
                hasn't verified this app": choose Advanced, then Go to the app.
                """)
            }
        } actions: {
            Button {
                path.append(.google)
            } label: {
                Text("I Have My OAuth Client ID")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

/// A value to paste into Google Cloud, with a button that copies it. Settings → Account uses it too.
struct CopyableValueRow: View {
    var label: LocalizedStringResource?
    let value: String
    @State private var copied = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                if let label {
                    Text(label)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text(value)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 12)
            Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                Platform.copyToPasteboard(value)
                copied = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .contentTransition(.symbolEffect(.replace))
        }
        .sensoryFeedback(.success, trigger: copied) { _, copied in copied }
    }
}

/// The client ID, then Google's own sign-in sheet.
private struct GoogleStep: View {
    @Binding var path: [OnboardingView.Step]
    let later: () -> Void
    @EnvironmentObject private var auth: GoogleAuthService
    @State private var isSigningIn = false
    @State private var authError: String?

    var body: some View {
        OnboardingPage(
            symbol: "person.crop.circle.fill",
            title: "Connect your Google account",
            subtitle: "Paste your OAuth client ID, then sign in securely with Google.",
            later: later
        ) {
            Section {
                TextField("Paste your client ID", text: $auth.clientId)
                    .identifierField()
                    .onChange(of: auth.clientId) { _, _ in authError = nil }
            } header: {
                Text("OAuth client ID")
            } footer: {
                if let inputError = auth.clientIdInputError, case .clientIdIsURL = inputError {
                    Text(inputError.localizedDescription)
                        .foregroundStyle(.red)
                } else {
                    Text("It ends in .apps.googleusercontent.com. You can find it under Google Cloud → Clients.")
                }
            }

            Section {
                if auth.isSignedIn {
                    Label("Connected with Google", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("On Google's consent screen, select the YouTube permission before continuing.", systemImage: "checkmark.shield")
                }
                if let authError {
                    Label(authError, systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                }
                Link(destination: GoogleCloudSetupURL.oauthClients) {
                    ExternalLinkLabel("Find your OAuth client ID")
                }
            }
        } actions: {
            if auth.isSignedIn {
                Button {
                    path.append(.home)
                } label: {
                    Text("Continue to YouTube Home")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button(action: signIn) {
                    HStack(spacing: 10) {
                        if isSigningIn { ProgressView() }
                        Text("Sign in with Google")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSigningIn || auth.redirectScheme == nil)
            }
        }
        .navigationBarBackButtonHidden(isSigningIn)
        .sensoryFeedback(.success, trigger: auth.isSignedIn) { _, signedIn in signedIn }
        .sensoryFeedback(.error, trigger: authError) { _, error in error != nil }
    }

    private func signIn() {
        isSigningIn = true
        authError = nil
        Task {
            do {
                try await auth.signIn()
                path.append(.home)
            } catch {
                authError = error.localizedDescription
            }
            isSigningIn = false
        }
    }
}

/// The alternative to signing in: public videos on a key.
private struct APIKeyStep: View {
    @Binding var path: [OnboardingView.Step]
    let later: () -> Void
    @EnvironmentObject private var apiKeyStore: APIKeyStore
    @State private var draft = ""

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        OnboardingPage(
            symbol: "key.fill",
            title: "Use an API key",
            subtitle: "An optional way to browse public videos without signing in.",
            later: later
        ) {
            Section {
                SetupLink(
                    number: 1,
                    title: "Enable YouTube Data API v3",
                    detail: "Choose your Google Cloud project first.",
                    url: GoogleCloudSetupURL.youtubeDataAPI
                )
                SetupLink(
                    number: 2,
                    title: "Create an API key",
                    detail: "Find it under APIs & Services → Credentials.",
                    url: GoogleCloudSetupURL.apiCredentials
                )
            }

            Section {
                TextField("Paste your API key", text: $draft)
                    .identifierField()
            } header: {
                Text("API key")
            } footer: {
                Text("You can add OAuth later in Settings for subscriptions, playlists and likes.")
            }
        } actions: {
            Button {
                apiKeyStore.apiKey = trimmedDraft
                path.append(.home)
            } label: {
                Text("Continue with API Key")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(trimmedDraft.isEmpty)
        }
    }
}

/// The optional youtube.com session, and the way out of setup.
private struct HomeStep: View {
    let onFinish: () -> Void
    @EnvironmentObject private var webSession: YouTubeWebSession
    @State private var showsYouTubeSignIn = false

    var body: some View {
        OnboardingPage(
            symbol: "sparkles.tv",
            title: "Bring in your YouTube Home",
            subtitle: "Connect youtube.com for your personalized Home feed and Watch Later."
        ) {
            Section {
                FeatureRow(
                    symbol: "house",
                    title: "Your own YouTube feed",
                    detail: "Sign in to youtube.com to see your personalized Home and YouTube Watch Later playlist here."
                )
                if webSession.isSignedIn {
                    Label("Connected to youtube.com", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    if !webSession.isSignedIn {
                        Text("This website connection is separate from Google OAuth. Use the same Google account when YouTube asks you to sign in.")
                    }
                    Text("YouTube Home reads the website outside the official API and may need attention if YouTube changes its pages.")
                }
            }
        } actions: {
            if webSession.isSignedIn {
                Button(action: onFinish) {
                    Text("Start Using Better YouTube")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    showsYouTubeSignIn = true
                } label: {
                    Text("Connect YouTube Home")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button(action: onFinish) {
                    Text("Continue Without YouTube Home")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .sheet(isPresented: $showsYouTubeSignIn) {
            YouTubeSignInView()
        }
        .sensoryFeedback(.success, trigger: webSession.isSignedIn) { _, signedIn in signedIn }
    }
}

// MARK: - Building blocks

/// One screen of setup: a symbol and a title over a grouped form, with the buttons that move on
/// in a bar the form scrolls under.
private struct OnboardingPage<Content: View, Actions: View>: View {
    let symbol: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    /// Finishes setup for another time, from the toolbar. The last screen has nothing left to
    /// postpone and passes none.
    var later: (() -> Void)? = nil
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions

    @ScaledMetric(relativeTo: .largeTitle) private var symbolSize = 60
    @State private var hasAppeared = false

    var body: some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    Image(systemName: symbol)
                        .font(.system(size: symbolSize))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.tint)
                        .symbolEffect(.bounce, value: hasAppeared)
                        .accessibilityHidden(true)
                    Text(title)
                        .font(.largeTitle.bold())
                    Text(subtitle)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            content
        }
        .settingsFormStyle()
        .safeAreaBar(edge: .bottom) {
            VStack(spacing: 10) {
                actions
            }
            .font(.headline)
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: 560)
        }
        .inlineNavigationBar()
        .toolbar {
            if let later {
                ToolbarItem {
                    Button("Set Up Later", action: later)
                }
            }
        }
        .onAppear { hasAppeared = true }
    }
}

/// A row of the welcome's feature list: a symbol in the accent colour, a name and a sentence.
private struct FeatureRow: View {
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
        }
        .padding(.vertical, 4)
    }
}

/// A numbered step that opens a Google Cloud page in the browser. Settings → Account uses it too.
struct SetupLink: View {
    let number: Int
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let url: URL

    var body: some View {
        Link(destination: url) {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .foregroundStyle(.primary)
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    // Palette, not monochrome: a monochrome numeral is knocked out of the circle and
                    // shows the background, which turns dark in dark mode.
                    Image(systemName: "\(number).circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentColor)
                }
                Spacer(minLength: 8)
                // Says the page opens outside the app, the way Settings marks its web links.
                Image(systemName: "arrow.up.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        // A link row tints everything in it; this one reads as a row, with only its number in
        // the accent colour.
        .tint(.primary)
        .padding(.vertical, 2)
    }
}
