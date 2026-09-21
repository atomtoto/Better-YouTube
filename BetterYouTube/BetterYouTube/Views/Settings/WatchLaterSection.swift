import SwiftUI
import UniformTypeIdentifiers

/// The real Watch Later connection and a generic Takeout playlist importer.
struct WatchLaterSection: View {
    @EnvironmentObject private var watchLater: WatchLaterStore

    @State private var showsTakeoutImporter = false
    @State private var showsDestinationPicker = false
    @State private var importedVideos: [Video] = []
    @State private var importSummary: WatchLaterStore.TakeoutImport?

    var body: some View {
        Section {
            LabeledContent(
                "Playlist",
                value: watchLater.usesYouTubeWatchLater ? "YouTube · Watch Later" : "On This Device"
            )

            // Parsing is available signed out; destination choices are shown afterwards.
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
            Text("Connect to youtube.com to use YouTube's actual Watch Later playlist. Otherwise, Watch Later stays on this device. A Google Takeout playlist can be imported into Watch Later or any custom playlist you choose.")
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
                Task {
                    let result = await watchLater.importTakeout(from: url)
                    importSummary = result
                    importedVideos = result.videos
                    showsDestinationPicker = result.failure == nil && !result.videos.isEmpty
                }
            case .failure(let error):
                importSummary = .init(failure: error.localizedDescription)
            }
        }
        .sheet(isPresented: $showsDestinationPicker) {
            PlaylistPickerView(videos: importedVideos)
        }
    }

    /// The result of an import, in the terms someone reading it cares about.
    private static func describe(_ summary: WatchLaterStore.TakeoutImport) -> String {
        if let failure = summary.failure { return failure }
        var parts = [summary.videos.count == 1
                     ? "Found 1 video — choose its destination"
                     : "Found \(summary.videos.count) videos — choose their destination"]
        if summary.missing > 0 { parts.append("\(summary.missing) no longer on YouTube") }
        // Say what was left behind, or a truncated import looks like a botched one.
        if summary.skippedOlder > 0 { parts.append("\(summary.skippedOlder) older ones skipped") }
        return parts.joined(separator: " · ")
    }
}
