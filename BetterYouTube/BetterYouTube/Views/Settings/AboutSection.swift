import SwiftUI

struct AboutSection: View {
    @State private var showsLicenses = false
    var body: some View {
        Section("About") {
            LabeledContent(
                "Version",
                value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1"
            )
            Text("An unofficial client built on the public YouTube Data API v3. Not affiliated with YouTube or Google.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Open Source Licenses") { showsLicenses = true }
        }
        .sheet(isPresented: $showsLicenses) {
            NavigationStack {
                ScrollView {
                    Text(Self.licenses)
                        .font(.footnote)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle("Open Source Licenses")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showsLicenses = false }
                    }
                }
            }
            .frame(minWidth: 300, minHeight: 400)
        }
    }

    private static let licenses: String = {
        guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "License notices are unavailable." }
        return text
    }()
}
