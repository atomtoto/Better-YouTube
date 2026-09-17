import SwiftUI

/// The groups Settings is divided into.
///
/// One definition, two shells: the Mac lists these down the side of its Settings window and the
/// phone lists them as rows that push, so the grouping — what belongs with what — is decided
/// here and nowhere else. Adding a pane means adding a case and its sections, and both platforms
/// pick it up.
///
/// Grouped by what someone is trying to do rather than by which store the setting happens to
/// live in: the API key and what it has spent are one subject, a playlist and the videos kept on
/// the device are another.
enum SettingsPane: String, CaseIterable, Identifiable {
    case account, library, notifications, youTubeHome, downloads, api, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .account: return "Account"
        case .library: return "Library"
        case .notifications: return "Notifications"
        case .youTubeHome: return "YouTube Home"
        case .downloads: return "Downloads"
        case .api: return "API & Quota"
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

    /// The chip colour on the phone's rows, matching the way Library draws its own.
    var tint: Color {
        switch self {
        case .account: return .blue
        case .library: return .orange
        case .notifications: return .red
        case .youTubeHome: return .pink
        case .downloads: return .green
        case .api: return .indigo
        case .advanced: return .gray
        }
    }
}

/// One pane's sections, as a form.
///
/// The same view on both platforms: pushed onto the navigation stack on a phone, and shown in the
/// detail column of the Settings window on a Mac. Which sections a pane holds is the only thing
/// it decides.
struct SettingsPaneView: View {
    let pane: SettingsPane

    var body: some View {
        Form {
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
        .settingsFormStyle()
        .navigationTitle(pane.title)
        // Only the phone's: the docked player is in this window there. On a Mac it is in the
        // *other* window, and scrolling Settings has no business shrinking it.
        #if os(iOS)
        .minimizesPlayerBarOnScroll()
        #endif
    }
}
