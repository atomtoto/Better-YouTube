import SwiftUI

struct AboutSection: View {
    var body: some View {
        Section("About") {
            LabeledContent("Version", value: "1.0")
            Text("An unofficial client built on the public YouTube Data API v3. Not affiliated with YouTube or Google.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
