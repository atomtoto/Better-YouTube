import SwiftUI

/// Settings, as the phone and iPad show it: a list of panes, each pushing to its own screen.
///
/// It used to be every section stacked into one form, which is a long scroll past six subjects to
/// reach the seventh. The panes are the same ones the Mac's Settings window lists down its side —
/// see `SettingsPane`, which is where the grouping lives — so the two platforms divide the
/// screen the same way and only the shell differs.
struct SettingsView: View {
    /// A pane keeps its own drafts and result banners, and an app reset makes all of them stale
    /// at once. Panes are built when they are opened, so in practice little survives one; keying
    /// the list on the counter is what makes that a guarantee rather than a happy consequence of
    /// which pane the Reset button happens to sit in. See `AppResetSignal`.
    @ObservedObject private var reset = AppResetSignal.shared

    var body: some View {
        List {
            ForEach(SettingsPane.allCases) { pane in
                NavigationLink {
                    SettingsPaneView(pane: pane)
                } label: {
                    SettingsPaneRow(pane: pane)
                }
            }
        }
        .id(reset.generation)
        .groupedListStyle()
        .minimizesPlayerBarOnScroll()
        .navigationTitle("Settings")
    }
}

/// A row leading to a pane, drawn like Library's: a tinted chip, then the name.
private struct SettingsPaneRow: View {
    let pane: SettingsPane

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: pane.icon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(pane.tint, in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            Text(pane.title)
                .font(.body)
        }
        .padding(.vertical, 2)
    }
}

/// "Open Settings", from wherever a screen has to send someone there.
///
/// On a phone that is a push onto the current navigation stack. On a Mac, Settings is a window of
/// its own, so `SettingsLink` opens that instead of pushing a settings screen into the Library.
struct OpenSettingsButton: View {
    var title = "Open Settings"

    var body: some View {
        #if os(macOS)
        SettingsLink {
            Text(title).font(.subheadline.weight(.semibold))
        }
        #else
        NavigationLink {
            SettingsView()
        } label: {
            Text(title).font(.subheadline.weight(.semibold))
        }
        #endif
    }
}

#Preview {
    NavigationStack { SettingsView() }
        .environmentObject(APIKeyStore.shared)
        .environmentObject(LibraryStore.shared)
        .environmentObject(WatchLaterStore.shared)
        .environmentObject(GoogleAuthService.shared)
        .environmentObject(NotificationStore.shared)
        .environmentObject(NotificationService.shared)
        .environmentObject(QuotaTracker.shared)
        .environmentObject(YouTubeWebSession.shared)
        .environmentObject(DownloadStore.shared)
        .environmentObject(DownloadManager.shared)
        .environmentObject(DownloadSettings.shared)
}
