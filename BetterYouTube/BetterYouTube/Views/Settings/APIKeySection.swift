import SwiftUI

/// The API key, which is what everything the app shows is fetched with.
struct APIKeySection: View {
    @EnvironmentObject private var apiKeyStore: APIKeyStore

    /// Edited rather than bound: there is a Save button, and a key that took effect halfway
    /// through being pasted would spend quota on requests that can only fail.
    @State private var draft = ""
    @State private var didSave = false

    var body: some View {
        Section {
            TextField("API key", text: $draft)
                .identifierField()

            Button("Save Key") {
                apiKeyStore.apiKey = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                didSave = true
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines) == apiKeyStore.apiKey)

            if didSave {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.green)
            }
        } header: {
            Text("YouTube Data API v3 Key")
        } footer: {
            Text("Enable the YouTube Data API v3 in the Google Cloud Console and create an API key credential. The key is stored only on this device.")
        }
        .onAppear { draft = apiKeyStore.apiKey }
    }
}
