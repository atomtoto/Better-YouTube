#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
import SwiftUI

/// The seam between iOS and macOS.
///
/// Everything the two platforms spell differently is named once here and used by that name
/// everywhere else, so the rest of the app reads as one program rather than as two interleaved
/// ones. The rule this file follows: a `#if` belongs here, not at the call site. Where a genuine
/// *behavioural* difference exists — a phone can be turned on its side, a Mac cannot — the
/// difference stays visible in the code that cares, and is commented there.
///
/// Anything new that touches UIKit or AppKit directly belongs on this list.

// MARK: - Types that differ in name only

#if os(macOS)
typealias PlatformImage = NSImage
typealias PlatformWindow = NSWindow
#else
typealias PlatformImage = UIImage
typealias PlatformWindow = UIWindow
#endif

extension Image {
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

extension PlatformImage {
    /// A rasterized Core Graphics image, which is what both the QR generator and the artwork
    /// loader end up holding.
    static func fromCGImage(_ image: CGImage) -> PlatformImage {
        #if os(macOS)
        return NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
        #else
        return UIImage(cgImage: image)
        #endif
    }
}

// MARK: - The host application

enum Platform {
    /// The window the app is currently in front of, for the two things that need one: the
    /// sign-in sheet's presentation anchor, and the off-screen web view the feed reader hangs
    /// on a real window so that it lays out.
    @MainActor
    static var keyWindow: PlatformWindow? {
        #if os(macOS)
        return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first { $0.isVisible }
        #else
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        #endif
    }

    /// Opens a URL outside the app — a watch page in the browser, a settings pane.
    @MainActor
    static func open(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    /// Takes the user to wherever notification permission is granted, which is the only place
    /// it can be granted from once it has been refused.
    @MainActor
    static func openNotificationSettings() {
        #if os(macOS)
        // The pane's identifier, which is how System Settings is deep-linked on macOS 13 and
        // later. A version that doesn't recognise it opens System Settings at the top rather
        // than failing, which is still where the user needs to be.
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        #else
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        #endif
        open(url)
    }

    /// What to call the place above, in a sentence.
    static var settingsAppName: String {
        #if os(macOS)
        "System Settings"
        #else
        "iOS Settings"
        #endif
    }

    /// Where downloaded files show up for the user, named as they would name it.
    static var downloadsLocationDescription: String {
        #if os(macOS)
        "Files land in the app's own Downloads folder, reachable from Downloads → Show in Finder."
        #else
        "Files land in Downloads, which the Files app shows under “Better YouTube”."
        #endif
    }

    /// Reveals a file to the user in the system's file browser. macOS only: iOS has no
    /// equivalent, and the Files app already lists the folder.
    @MainActor
    static func revealInFileBrowser(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        #endif
    }

    /// True where the app can be pushed into the background and keep working — which decides
    /// whether periodic work is the system's job or the app's own. See `BackgroundRefresh`.
    static var schedulesWorkWhileSuspended: Bool {
        #if os(macOS)
        false
        #else
        true
        #endif
    }
}

// MARK: - Colours

/// The app's surfaces, named for their role rather than for either platform's palette.
///
/// iOS and macOS disagree about which is lighter: on iOS the page is white and cards sit a shade
/// darker; on macOS the window is grey and content areas sit a shade lighter. Both readings are
/// the native one, and naming by role is what lets the same view be right on both.
extension Color {
    /// The page behind everything.
    static var appBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }

    /// A card, a field, a raised surface over the page.
    static var appSecondaryBackground: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }

    /// A neutral fill: placeholders, skeletons, the unfilled part of a bar.
    static var appTertiaryFill: Color {
        #if os(macOS)
        Color(nsColor: .quaternaryLabelColor)
        #else
        Color(uiColor: .tertiarySystemFill)
        #endif
    }
}

// MARK: - View modifiers that only one platform has

extension View {
    /// A compact title bar. macOS has one shape of navigation title, so there is nothing to ask
    /// for there.
    @ViewBuilder
    func inlineNavigationBar() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// The grouped-list look, which the two platforms spell differently.
    @ViewBuilder
    func groupedListStyle() -> some View {
        #if os(iOS)
        listStyle(.insetGrouped)
        #else
        listStyle(.inset)
        #endif
    }

    /// A settings form. macOS needs to be told to use the modern grouped shape; on iOS a `Form`
    /// already is one.
    @ViewBuilder
    func settingsFormStyle() -> some View {
        #if os(macOS)
        formStyle(.grouped)
        #else
        self
        #endif
    }

    /// Text entry for a value that is an identifier rather than prose — a key, a URL, a token.
    /// Nothing should be capitalized or corrected on the way in.
    @ViewBuilder
    func identifierField(isURL: Bool = false) -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(isURL ? .URL : .default)
        #else
        autocorrectionDisabled()
        #endif
    }

    /// Pins a search field where the hand is: within thumb reach at the bottom of a phone, and
    /// at the top of a Mac window, which is where every Mac app keeps one.
    @ViewBuilder
    func searchFieldInset<Field: View>(@ViewBuilder _ field: () -> Field) -> some View {
        #if os(macOS)
        safeAreaInset(edge: .top, content: field)
        #else
        safeAreaInset(edge: .bottom, content: field)
        #endif
    }

    /// Hides the status bar and the home indicator while the video has the screen. Neither
    /// exists on a Mac.
    @ViewBuilder
    func systemChromeHidden(_ hidden: Bool) -> some View {
        #if os(iOS)
        statusBarHidden(hidden)
            .persistentSystemOverlays(hidden ? .hidden : .automatic)
        #else
        self
        #endif
    }

    /// Keeps a view clear of the keyboard's reserved space on iOS. There is no keyboard inset
    /// to ignore on macOS.
    @ViewBuilder
    func ignoresKeyboardInset() -> some View {
        #if os(iOS)
        ignoresSafeArea(.keyboard, edges: .bottom)
        #else
        self
        #endif
    }
}

#if os(macOS)

/// A Refresh button for the toolbar.
///
/// `refreshable` gives iOS pull-to-refresh, which macOS has no gesture for — so on a Mac the same
/// action needs somewhere to be clicked. It exists only on the platform that needs it, and the
/// screens that offer refreshing put it in their toolbar behind an `#if`.
struct RefreshButton: View {
    let action: () async -> Void
    @State private var isRefreshing = false

    var body: some View {
        Button {
            guard !isRefreshing else { return }
            isRefreshing = true
            Task {
                await action()
                isRefreshing = false
            }
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
        .disabled(isRefreshing)
        .keyboardShortcut("r", modifiers: .command)
    }
}

#endif
