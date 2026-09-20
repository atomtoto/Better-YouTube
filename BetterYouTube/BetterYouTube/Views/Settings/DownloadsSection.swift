import SwiftUI

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
            Picker("Download Using", selection: $settings.backend) {
                ForEach(DownloadBackend.allCases) { backend in
                    Text(backend.title).tag(backend)
                }
            }

            if settings.backend == .server {
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

            if settings.backend == .server && settings.endpointURL != nil {
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

    private static var footer: String {
        """
        On This Device downloads directly from YouTube and combines audio and video here, without a download server. Keep the app open while finding the video and finishing it. Media transfers can continue in the background. Some live or restricted videos may be unavailable.

        My Server uses your saved resolver address and optional token. Addresses containing {id}, {videoId} or {url} are fetched directly; other addresses receive a JSON request. Share Setup shares only the server configuration.

        Quality is a maximum; the best compatible format below it is selected. \(Platform.downloadsLocationDescription) Downloaded videos play offline throughout the app.
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
