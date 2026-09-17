import SwiftUI
import UniformTypeIdentifiers

/// Watch Later, which YouTube closed to apps in 2016 — so the app keeps one of its own, and
/// this is where what YouTube's list already holds gets brought across.
struct WatchLaterSection: View {
    @EnvironmentObject private var auth: GoogleAuthService
    @EnvironmentObject private var watchLater: WatchLaterStore

    @State private var showsTakeoutImporter = false
    @State private var importSummary: WatchLaterStore.ImportSummary?

    var body: some View {
        Section {
            if auth.isSignedIn {
                LabeledContent("Playlist", value: WatchLaterStore.playlistTitle)

                let strays = watchLater.videosOnlyOnThisDevice.count
                if strays > 0 {
                    Button {
                        Task { await watchLater.uploadVideosOnlyOnThisDevice() }
                    } label: {
                        Text(strays == 1
                             ? "Add 1 video kept on this device"
                             : "Add \(strays) videos kept on this device")
                    }
                    .disabled(watchLater.isLoading)
                }
            }

            // Available signed out as well: the import lands on the device either way.
            Button {
                importSummary = nil
                showsTakeoutImporter = true
            } label: {
                HStack(spacing: 8) {
                    if watchLater.isLoading {
                        ProgressView().controlSize(.small)
                    }
                    Text("Import from Google Takeout…")
                }
            }
            .disabled(watchLater.isLoading)

            if let importSummary {
                Text(Self.describe(importSummary))
                    .font(.footnote)
                    // Both branches must be the same ShapeStyle, so spell out `Color`.
                    .foregroundStyle(importSummary.failure == nil ? Color.secondary : Color.red)
            }

            if let message = watchLater.errorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Watch Later")
        } footer: {
            Text("""
            YouTube's own Watch Later has been closed to apps since 2016. Signed in, this app keeps \
            a private playlist of its own instead — it syncs across your devices and appears in the \
            YouTube app like any other, at 50 of the 10,000 daily quota units per change, so \
            roughly 200 a day. To bring across what YouTube's list already holds, export it from \
            Google Takeout, unzip the archive, and import the CSV under “YouTube and YouTube \
            Music” → “playlists” — Watch Later exports as “Vidéos de Watch later.csv”, named in \
            your account's language. An import takes the \(WatchLaterStore.importLimit) most \
            recently added and leaves the rest. Imported videos land on this device; the button \
            above sends them up to the playlist.
            """)
        }
        // Takeout's CSVs arrive as plain text as often as with a CSV type, so accept both.
        .fileImporter(
            isPresented: $showsTakeoutImporter,
            allowedContentTypes: [.commaSeparatedText, .plainText, .text],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { importSummary = await watchLater.importTakeout(from: url) }
            case .failure(let error):
                importSummary = .init(failure: error.localizedDescription)
            }
        }
    }

    /// The result of an import, in the terms someone reading it cares about.
    private static func describe(_ summary: WatchLaterStore.ImportSummary) -> String {
        if let failure = summary.failure { return failure }
        var parts = [summary.added == 1 ? "Added 1 video" : "Added \(summary.added) videos"]
        if summary.alreadyThere > 0 { parts.append("\(summary.alreadyThere) already saved") }
        if summary.missing > 0 { parts.append("\(summary.missing) no longer on YouTube") }
        // Say what was left behind, or a truncated import looks like a botched one.
        if summary.skippedOlder > 0 { parts.append("\(summary.skippedOlder) older ones skipped") }
        return parts.joined(separator: " · ")
    }
}
