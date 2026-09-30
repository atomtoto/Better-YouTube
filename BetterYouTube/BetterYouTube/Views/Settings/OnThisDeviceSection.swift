import SwiftUI

/// The app's library, with a confirmation for history deletion across synced devices.
struct OnThisDeviceSection: View {
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject private var sync = ICloudSyncService.shared
    @State private var showsHistoryConfirmation = false

    var body: some View {
        Section("Your Library") {
            LabeledContent("Favorites", value: "\(library.favorites.count)")
            LabeledContent("Watch Later", value: "\(library.watchLater.count)")
            LabeledContent("History", value: "\(library.history.count)")
            Button("Clear Watch History", role: .destructive) {
                showsHistoryConfirmation = true
            }
            .disabled(library.history.isEmpty)
        }
        .confirmationDialog(
            "Clear Watch History?",
            isPresented: $showsHistoryConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear Watch History", role: .destructive) {
                library.clearHistory()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(sync.isEnabled
                 ? "This also clears the app's watch history on your other devices using iCloud Sync. Your YouTube account's history is unchanged."
                 : "This clears the app's watch history on this device. Your YouTube account's history is unchanged.")
        }
    }
}
