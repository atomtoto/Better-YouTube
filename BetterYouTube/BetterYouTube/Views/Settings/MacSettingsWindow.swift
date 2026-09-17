#if os(macOS)
import SwiftUI

/// Settings, as a Mac window.
///
/// ⌘, on a Mac opens a window, not a screen inside the main one — so the app has a `Settings`
/// scene and this is what fills it. The panes and their contents are `SettingsPane`'s, shared
/// with the phone; all this adds is the source list and the window's shape.
///
/// A source list rather than a row of icons across the top: it is what System Settings does, it
/// scales past the handful of panes an icon row holds, and it matches the sidebar the main window
/// already uses.
struct MacSettingsWindow: View {
    /// Same reasoning as `SettingsView`: an app reset makes every draft and banner in here stale,
    /// and rebuilding is cheaper to be right about than clearing each one.
    @ObservedObject private var reset = AppResetSignal.shared
    @State private var pane: SettingsPane = .account

    var body: some View {
        NavigationSplitView {
            // The selection is optional — clicking the empty space below the rows clears it —
            // while Settings always has a pane open. Dropping the nil rather than acting on it
            // keeps those two facts from disagreeing.
            List(selection: Binding(
                get: { Optional(pane) },
                set: { if let new = $0 { pane = new } }
            )) {
                ForEach(SettingsPane.allCases) { pane in
                    Label(pane.title, systemImage: pane.icon)
                        .tag(pane)
                }
            }
            .navigationSplitViewColumnWidth(min: 172, ideal: 190, max: 240)
            // No sidebar toggle. `NavigationSplitView` offers one by default, and in a Settings
            // window it is the wrong affordance: the pane list *is* the navigation, and a window
            // whose only way back to it has been collapsed away is a dead end.
            .toolbar(removing: .sidebarToggle)
        } detail: {
            SettingsPaneView(pane: pane)
        }
        .id(reset.generation)
        // A Settings window doesn't take its size from the content the way a document window
        // does, and the footers in here are long enough to need the room.
        .frame(minWidth: 760, idealWidth: 820, minHeight: 520, idealHeight: 640)
    }
}
#endif
