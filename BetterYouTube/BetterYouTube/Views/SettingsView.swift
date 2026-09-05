import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var apiKeyStore: APIKeyStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var auth: GoogleAuthService

    @State private var draftKey: String = ""
    @State private var draftClientId: String = ""
    @State private var isSigningIn = false
    @State private var authError: String?
    @State private var didSaveKey = false

    var body: some View {
        Form {
            accountSection
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
        .navigationTitle("Settings")
        .onAppear {
            draftKey = apiKeyStore.apiKey
            draftClientId = auth.clientId
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var accountSection: some View {
        Section {
            if auth.isSignedIn {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Signed in with Google")
                            .font(.subheadline.weight(.semibold))
                        Text("Subscriptions, playlists and likes are available in Library.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Button("Sign Out", role: .destructive) {
                    auth.signOut()
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
            liked videos. Watch Later and watch history are not available through the API, so those \
            lists stay on this device.
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
        .environmentObject(GoogleAuthService.shared)
}
