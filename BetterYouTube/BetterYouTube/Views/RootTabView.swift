import SwiftUI

struct RootTabView: View {
    @EnvironmentObject private var apiKeyStore: APIKeyStore
    @EnvironmentObject private var auth: GoogleAuthService
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var notificationStore: NotificationStore
    @State private var showsOnboarding = false

    var body: some View {
        TabView(selection: $router.selectedTab) {
            NavigationStack(path: $router.homePath) {
                HomeView()
            }
            .tabItem { Label("Home", systemImage: "play.circle.fill") }
            .badge(notificationStore.unreadCount)
            .tag(AppRouter.Tab.home)

            NavigationStack {
                SearchView()
            }
            .tabItem { Label("Search", systemImage: "magnifyingglass") }
            .tag(AppRouter.Tab.search)

            NavigationStack {
                LibraryView()
            }
            .tabItem { Label("Library", systemImage: "square.stack.fill") }
            .tag(AppRouter.Tab.library)

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("Settings", systemImage: "gearshape.fill") }
            .tag(AppRouter.Tab.settings)
        }
        .sheet(isPresented: $showsOnboarding) {
            OnboardingView()
        }
        .onAppear {
            showsOnboarding = !apiKeyStore.hasKey && !auth.isSignedIn
        }
    }
}

/// First-run screen explaining the two ways to authenticate against the YouTube API.
private struct OnboardingView: View {
    @EnvironmentObject private var apiKeyStore: APIKeyStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 12) {
                        Image(systemName: "play.rectangle.on.rectangle.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(.red)
                        Text("Welcome to Better YouTube")
                            .font(.largeTitle.bold())
                            .multilineTextAlignment(.center)
                        Text("A calmer way to browse YouTube, built on the official Data API.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 32)

                    VStack(spacing: 16) {
                        FeatureRow(
                            icon: "key.fill",
                            title: "Add an API key",
                            detail: "Enable the YouTube Data API v3 in the Google Cloud Console and create an API key."
                        )
                        FeatureRow(
                            icon: "person.crop.circle.fill",
                            title: "Sign in (optional)",
                            detail: "Connect your Google account in Settings to see your subscriptions, playlists and likes."
                        )
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("API key")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TextField("Paste your key", text: $draft)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color(uiColor: .secondarySystemBackground))
                            )

                        Button {
                            apiKeyStore.apiKey = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                            dismiss()
                        } label: {
                            Text("Continue")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Later") { dismiss() }
                }
            }
        }
    }
}

private struct FeatureRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.red)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

#Preview {
    RootTabView()
        .environmentObject(APIKeyStore.shared)
        .environmentObject(LibraryStore.shared)
        .environmentObject(GoogleAuthService.shared)
        .environmentObject(RecentSearchStore.shared)
        .environmentObject(NotificationStore.shared)
        .environmentObject(NotificationService.shared)
        .environmentObject(AppRouter.shared)
}
