import SwiftUI

/// An optional key for public Data API requests when the user prefers not to sign in.
struct APIKeySection: View {
    @EnvironmentObject private var apiKeyStore: APIKeyStore

    /// Edited rather than bound: there is a Save button, and a key that took effect halfway
    /// through being pasted would spend quota on requests that can only fail.
    @State private var draft = ""
    @State private var didSave = false

    var body: some View {
        Section {
            Link(destination: GoogleCloudSetupURL.youtubeDataAPI) {
                ExternalLinkLabel("Enable YouTube Data API v3")
            }
            Link(destination: GoogleCloudSetupURL.apiCredentials) {
                ExternalLinkLabel("Create or find an API key")
            }
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
            Text("YouTube Data API v3 Key (Optional)")
        } footer: {
            Text("Select your Google Cloud project on each linked page, enable the API, then choose Create credentials → API key. Google OAuth can load public content without a separate key; account features still need OAuth. The key is stored only on this device.")
        }
        .onAppear { draft = apiKeyStore.apiKey }
    }
}
