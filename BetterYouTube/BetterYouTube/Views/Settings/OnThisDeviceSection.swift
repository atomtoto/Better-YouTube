import SwiftUI

/// What the app is keeping locally, and the one piece of it YouTube has no copy of.
struct OnThisDeviceSection: View {
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        Section("On This Device") {
            LabeledContent("Favorites", value: "\(library.favorites.count)")
            LabeledContent("Watch Later", value: "\(library.watchLater.count)")
            LabeledContent("History", value: "\(library.history.count)")
            Button("Clear Watch History", role: .destructive) {
                library.clearHistory()
            }
            .disabled(library.history.isEmpty)
        }
    }
}
