import SwiftUI

/// Downloading, and the one thing about it worth being plain about: the app cannot do it
/// alone, and this is where you say what should do it for it.
///
/// No service ships with the app and none is suggested. Playback goes through YouTube's own
/// embed, which never exposes a media file, so a download needs something that can resolve one
/// — and which resolver to trust is the owner's call, not the app's. Running your own is also
/// the only version that keeps working: a public instance goes dark, throttles you, or starts
/// keeping a record of what you watch, while one on your own machine you can fix the day it
/// breaks.
struct DownloadsSection: View {
    @EnvironmentObject private var settings: DownloadSettings
    @EnvironmentObject private var store: DownloadStore
    @EnvironmentObject private var manager: DownloadManager

    @State private var draftEndpoint = ""
    @State private var draftToken = ""
    @State private var didSave = false
    @State private var showsRemoveConfirmation = false
    @State private var showsShare = false

    var body: some View {
        Section {
            TextField("https://…", text: $draftEndpoint)
                .identifierField(isURL: true)

            SecureField("Bearer token (optional)", text: $draftToken)
                .identifierField()

            Button("Save Download Service") {
                settings.endpoint = draftEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
                settings.token = draftToken.trimmingCharacters(in: .whitespacesAndNewlines)
                didSave = true
            }
            .disabled(!hasChanges)

            if didSave {
                // Which of the two shapes the address was read as is the one thing here that is
                // easy to get wrong and impossible to see, so saving says so outright.
                Label(
                    status,
                    systemImage: settings.isConfigured
                        ? "checkmark.circle.fill"
                        : "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(settings.isConfigured ? Color.green : Color.orange)
            }

            Picker("Quality", selection: $settings.quality) {
                ForEach(DownloadQuality.allCases) { quality in
                    Text(quality.title).tag(quality)
                }
            }

            Toggle("Download over Wi-Fi Only", isOn: $settings.wifiOnly)

            Picker("Storage Limit", selection: $settings.storageLimitGB) {
                Text("No limit").tag(0)
                ForEach([2, 4, 8, 16, 32, 64], id: \.self) { size in
                    Text("\(size) GB").tag(size)
                }
            }

            LabeledContent(
                "Storage Used",
                value: ByteCountFormatter.string(
                    fromByteCount: store.bytesOnDisk(),
                    countStyle: .file
                )
            )

            if settings.isConfigured {
                Button {
                    showsShare = true
                } label: {
                    Label("Share Setup", systemImage: "qrcode")
                }
            }

            if !store.records.isEmpty {
                Button("Remove All Downloads", role: .destructive) {
                    showsRemoveConfirmation = true
                }
            }
        } header: {
            Text("Downloads")
        } footer: {
            Text(Self.footer)
        }
        .onAppear { adoptSavedService() }
        // A `betteryoutube://` link can configure the service from outside this screen, and a
        // draft that kept the old address would quietly overwrite it on the next Save.
        .onChange(of: settings.endpoint) { _, _ in adoptSavedService() }
        .onChange(of: settings.token) { _, _ in adoptSavedService() }
        .confirmationDialog(
            "Remove all downloads?",
            isPresented: $showsRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove All", role: .destructive) { manager.removeAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The files go from this device. Nothing changes on your YouTube account.")
        }
        .sheet(isPresented: $showsShare) {
            DownloadConfigShareView()
        }
    }

    /// Brings the fields in line with what is actually saved.
    ///
    /// The guard is what keeps this from undoing the Save button: saving publishes the endpoint,
    /// which lands right back here, and by then the drafts already match — so a change this
    /// screen made looks like nothing to do, and only a change from elsewhere clears the fields
    /// and the "Saved" note with them.
    private func adoptSavedService() {
        guard hasChanges else { return }
        draftEndpoint = settings.endpoint
        draftToken = settings.token
        didSave = false
    }

    /// Kept out of the view builder: it is four paragraphs, and inlining it buries the section.
    ///
    /// One line of it is the platform's — where the files end up is the Files app on a phone and
    /// a folder in the Finder on a Mac — so `Platform` supplies that sentence.
    private static var footer: String {
        """
        Playback goes through YouTube's own embed, which never hands over a media file, so the app \
        has no way to fetch one by itself. Point this at a resolver you run and Download appears on \
        every video; leave it empty and downloading stays off.

        Two shapes work. An address carrying {id}, {videoId} or {url} is filled in and fetched \
        directly, so https://box.local/yt/{id}.mp4 is a complete setup. Anything else is sent a POST \
        of url, videoId, quality and maxHeight, and its reply is read for a media link — url, \
        downloadUrl, link, or the first entry of urls, formats or streams.

        \(Platform.downloadsLocationDescription) They stay out of iCloud backups, and a downloaded \
        video plays from the file everywhere in the app, with no network at all.

        Once it works, Share Setup hands the same service to another device as a link or a QR \
        code, so nobody else has to type any of this.
        """
    }

    private var status: String {
        guard settings.isConfigured else {
            return settings.trimmedEndpoint.isEmpty
                ? "Downloading is off"
                : "Downloading is off — that isn't an http or https address"
        }
        return settings.usesTemplate
            ? "Saved — the address is filled in and fetched directly"
            : "Saved — the address is sent a POST and read for a media link"
    }

    private var hasChanges: Bool {
        draftEndpoint.trimmingCharacters(in: .whitespacesAndNewlines) != settings.endpoint
            || draftToken.trimmingCharacters(in: .whitespacesAndNewlines) != settings.token
    }
}
