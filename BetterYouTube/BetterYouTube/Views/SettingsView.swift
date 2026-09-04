import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var apiKeyStore: APIKeyStore
    @EnvironmentObject private var library: LibraryStore
    @State private var draftKey: String = ""
    @State private var didSave = false

    var body: some View {
        Form {
            Section("YouTube Data API v3 Key") {
                TextField("API key", text: $draftKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Save") {
                    apiKeyStore.apiKey = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    didSave = true
                }
                .disabled(draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if didSave {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.footnote)
                }
            } footer: {
                Text("Create a free key at console.cloud.google.com by enabling the YouTube Data API v3 and generating an API key credential. The key is stored only on this device.")
            }

            Section("Library") {
                LabeledContent("Favorites", value: "\(library.favorites.count)")
                LabeledContent("Watch later", value: "\(library.watchLater.count)")
                LabeledContent("History", value: "\(library.history.count)")
                Button("Clear watch history", role: .destructive) {
                    library.clearHistory()
                }
            }

            Section("About") {
                LabeledContent("App", value: "Better YouTube")
                LabeledContent("Version", value: "1.0")
                Text("An unofficial SwiftUI client built on the public YouTube Data API v3. Not affiliated with YouTube or Google.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .onAppear { draftKey = apiKeyStore.apiKey }
    }
}

#Preview {
    NavigationStack { SettingsView() }
        .environmentObject(APIKeyStore.shared)
        .environmentObject(LibraryStore.shared)
}
