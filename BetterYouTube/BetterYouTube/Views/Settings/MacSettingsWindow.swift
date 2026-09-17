#if os(macOS)
import SwiftUI

/// Settings, as a Mac window.
///
/// ⌘, on a Mac opens a window, not a screen inside the main one — so the app has a `Settings`
/// scene and this is what fills it. The sections are the same views the phone stacks into one
/// `Form`; all this adds is a list of panes and a decision about which sections belong together.
///
/// A source list rather than a row of icons across the top: it is what System Settings does, it
/// scales past the handful of panes an icon row holds, and it matches the sidebar the main window
/// already uses.
struct MacSettingsWindow: View {
    @ObservedObject private var reset = AppResetSignal.shared
    @State private var pane: Pane = .account

    /// The panes, and what each one is made of. Grouped by what someone is trying to do rather
    /// than by which store the setting happens to live in.
    enum Pane: String, CaseIterable, Identifiable {
        case account, library, notifications, youTubeHome, downloads, api, advanced

        var id: String { rawValue }

        var title: String {
            switch self {
            case .account: return "Account"
            case .library: return "Library"
            case .notifications: return "Notifications"
            case .youTubeHome: return "YouTube Home"
            case .downloads: return "Downloads"
            case .api: return "API"
            case .advanced: return "Advanced"
            }
        }

        var icon: String {
            switch self {
            case .account: return "person.crop.circle"
            case .library: return "rectangle.stack"
            case .notifications: return "bell"
            case .youTubeHome: return "globe"
            case .downloads: return "arrow.down.circle"
            case .api: return "key"
            case .advanced: return "gearshape.2"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(
                get: { Optional(pane) },
                set: { if let new = $0 { pane = new } }
            )) {
                ForEach(Pane.allCases) { pane in
                    Label(pane.title, systemImage: pane.icon)
                        .tag(pane)
                }
            }
            .navigationSplitViewColumnWidth(min: 172, ideal: 190, max: 240)
        } detail: {
            Form {
                sections(for: pane)
            }
            .formStyle(.grouped)
            .navigationTitle(pane.title)
        }
        // Same reasoning as `SettingsView`: an app reset makes every draft and banner in here
        // stale, and rebuilding is cheaper to be right about than clearing each one.
        .id(reset.generation)
        // A Settings window doesn't take its size from the content the way a document window
        // does, and the footers in here are long enough to need the room.
        .frame(minWidth: 760, idealWidth: 820, minHeight: 520, idealHeight: 640)
    }

    @ViewBuilder
    private func sections(for pane: Pane) -> some View {
        switch pane {
        case .account:
            AccountSection()
        case .library:
            WatchLaterSection()
            OnThisDeviceSection()
        case .notifications:
            NotificationsSection()
        case .youTubeHome:
            YouTubeHomeSection()
        case .downloads:
            DownloadsSection()
        case .api:
            APIKeySection()
            QuotaSection()
        case .advanced:
            ResetSection()
            AboutSection()
        }
    }
}
#endif
