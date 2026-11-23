import SwiftUI

/// Whether the app's pages take a warm background in light mode. A preference shared by
/// every screen and window; the raw value is stored and must not change.
enum WarmBackgroundSetting {
    static let storageKey = "warm_background"
}

/// The warm page of the app: cream behind lighter rows (`Color.warmBackground` behind
/// `Color.warmRow`, from the asset catalog), with the native lists, sections and separators.
/// Only in light mode, and only with the « Fond chaud » setting; the dark appearance stays
/// the system's, and so does everything else.
private struct WarmPage: ViewModifier {
    @AppStorage(WarmBackgroundSetting.storageKey) private var isEnabled = true
    @Environment(\.colorScheme) private var colorScheme

    private var isWarm: Bool { isEnabled && colorScheme == .light }

    func body(content: Content) -> some View {
        // The same modifiers either way, so that the setting does not rebuild the list.
        content
            .scrollContentBackground(isWarm ? .hidden : .automatic)
            .listRowBackground(isWarm ? Color.warmRow : nil)
            // The page runs under every safe area, so that no white shows around the keyboard.
            .background { (isWarm ? Color.warmBackground : Color.clear).ignoresSafeArea(.all) }
    }
}

extension View {
    /// Gives a list, form or scrollable page the warm background, when the setting asks for it.
    func warmPage() -> some View {
        modifier(WarmPage())
    }
}
