import SwiftUI

/// Back to a fresh install. The confirmation names what goes rather than asking "are you
/// sure" about an unnamed thing — the API key and both sign-ins are the parts people don't
/// expect to lose, and they are the tedious ones to set up again.
///
/// It clears nothing of its own: `AppReset` empties the stores and then says it happened, and the
/// screen around this rebuilds every other section from stores that are by then empty. See
/// `AppResetSignal`.
struct ResetSection: View {
    @State private var showsConfirmation = false
    @State private var isResetting = false

    var body: some View {
        Section {
            Button("Reset App", role: .destructive) {
                showsConfirmation = true
            }
            .disabled(isResetting)
        } header: {
            Text("Reset")
        } footer: {
            Text("""
            Erases everything on this device: the API key and OAuth client ID, both sign-ins, \
            your favorites, Watch Later, watch history and recent searches, the notification \
            inbox and its channels, the quota tally, and every downloaded video along with the \
            download service's address. Your YouTube account itself is untouched — playlists, \
            subscriptions and likes all stay where they are.
            """)
        }
        .confirmationDialog(
            "Reset Better YouTube?",
            isPresented: $showsConfirmation,
            titleVisibility: .visible
        ) {
            Button("Erase Everything", role: .destructive) {
                isResetting = true
                Task {
                    await AppReset.eraseEverything()
                    isResetting = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This device goes back to a fresh install. Nothing changes on your YouTube account.")
        }
    }
}
