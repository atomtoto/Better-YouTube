import SwiftUI

struct RootTabView: View {
    @EnvironmentObject private var apiKeyStore: APIKeyStore

    var body: some View {
        TabView {
            NavigationStack {
                HomeView()
            }
            .tabItem { Label("Home", systemImage: "play.rectangle.fill") }

            NavigationStack {
                SearchView()
            }
            .tabItem { Label("Search", systemImage: "magnifyingglass") }

            NavigationStack {
                LibraryView()
            }
            .tabItem { Label("Library", systemImage: "books.vertical.fill") }

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .sheet(isPresented: .constant(!apiKeyStore.hasKey)) {
            OnboardingAPIKeyView()
                .interactiveDismissDisabled()
        }
    }
}

/// Shown the first time the app launches, before any videos can be fetched.
private struct OnboardingAPIKeyView: View {
    @EnvironmentObject private var apiKeyStore: APIKeyStore
    @State private var draft: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Better YouTube uses the official YouTube Data API v3. Create a free API key in the Google Cloud Console, then paste it below to start browsing.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Section("API Key") {
                    TextField("Paste your API key", text: $draft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    Button("Save & Continue") {
                        apiKeyStore.apiKey = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("Welcome")
        }
    }
}

#Preview {
    RootTabView()
        .environmentObject(APIKeyStore.shared)
        .environmentObject(LibraryStore.shared)
}
