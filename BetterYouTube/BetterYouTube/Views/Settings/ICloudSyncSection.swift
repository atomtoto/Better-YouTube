import SwiftUI

/// The private iCloud library shared by the user's Apple devices.
struct ICloudSyncSection: View {
    @ObservedObject private var sync = ICloudSyncService.shared

    var body: some View {
        Section {
            Toggle("iCloud Sync", isOn: Binding(
                get: { sync.isEnabled },
                set: { sync.setEnabled($0) }
            ))

            HStack(spacing: 8) {
                if sync.isSyncing {
                    ProgressView().controlSize(.small)
                }
                Text(sync.statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let lastSyncDate = sync.lastSyncDate {
                LabeledContent("Last Synced") {
                    Text(lastSyncDate, format: .dateTime.day().month().hour().minute())
                }
            }

            Button("Sync Now") {
                Task { await sync.syncNow() }
            }
            .disabled(!sync.isEnabled || sync.isSyncing)
        } header: {
            Text("iCloud")
        } footer: {
            Text("Favorites, the app's Watch Later, watch history, and mini player style and size sync between iPhone, iPad and Mac using the same Apple Account. Apple Watch receives the library through its paired iPhone. Downloaded media, sign-ins and credentials stay on each device. YouTube's Watch Later uses your separate youtube.com session. Turning off sync keeps your library on this device and in iCloud.")
        }
    }
}
