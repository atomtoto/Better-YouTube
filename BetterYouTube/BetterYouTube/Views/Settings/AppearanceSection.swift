import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The home screen icon style. The system stores the choice as the name of an alternate
/// icon in the build settings; nil is the primary icon.
#if os(iOS)
enum AppIconChoice: String, CaseIterable, Identifiable {
    /// The primary icon: a light page with the red play button.
    case light
    /// The alternate icon: the play button on a red page.
    case red

    var id: String { rawValue }

    /// The alternate icon's name in the build settings, nil for the primary icon.
    var alternateIconName: String? {
        switch self {
        case .light: nil
        case .red: "BetterYouTubeSecond"
        }
    }

    var title: String {
        switch self {
        case .light: return String(localized: "Light")
        case .red: return String(localized: "Red")
        }
    }

    var preview: ImageResource {
        switch self {
        case .light: .appIconPreview
        case .red: .appIconSecondPreview
        }
    }

    /// The style of the icon in use, from its name.
    @MainActor
    static var current: Self {
        UIApplication.shared.alternateIconName == "BetterYouTubeSecond" ? .red : .light
    }
}
#endif

/// Appearance: the warm background in light mode and — on iPhone and iPad, where the system
/// offers alternate icons — the home screen icon.
struct AppearanceSection: View {
    @AppStorage(WarmBackgroundSetting.storageKey) private var warmBackground = true
    #if os(iOS)
    @State private var icon = AppIconChoice.current
    @State private var iconError: String?
    #endif

    var body: some View {
        Section {
            Toggle("Warm Background", isOn: $warmBackground)
        } footer: {
            Text("In light mode, the app's pages take a warm cream background. Dark mode is unchanged.")
        }
        #if os(iOS)
        iconSection
        #endif
    }

    #if os(iOS)
    /// The system shows its own confirmation when the icon changes.
    private var iconSelection: Binding<AppIconChoice> {
        Binding {
            icon
        } set: { choice in
            let previous = icon
            icon = choice
            updateIcon(restoring: previous)
        }
    }

    /// Gives the app the icon of the chosen style, unless it already has it.
    /// A refused change puts the style back when `previous` is given.
    private func updateIcon(restoring previous: AppIconChoice? = nil) {
        let name = icon.alternateIconName
        guard UIApplication.shared.supportsAlternateIcons,
              UIApplication.shared.alternateIconName != name else { return }
        iconError = nil
        Task {
            do {
                try await UIApplication.shared.setAlternateIconName(name)
            } catch {
                if let previous { icon = previous }
                iconError = String(localized: "The icon could not be changed.")
            }
        }
    }

    private var iconSection: some View {
        Section {
            Picker("App Icon", selection: iconSelection) {
                ForEach(AppIconChoice.allCases) { choice in
                    Label {
                        Text(choice.title)
                    } icon: {
                        Image(choice.preview)
                            .resizable()
                            .frame(width: 40, height: 40)
                            .accessibilityHidden(true)
                    }
                    .tag(choice)
                    .appIconRowLeadingInset()
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } header: {
            Text("App Icon")
        } footer: {
            if let iconError {
                Text(iconError).foregroundStyle(.red)
            }
        }
        .disabled(!UIApplication.shared.supportsAlternateIcons)
    }
    #endif
}

#if os(iOS)
private extension View {
    /// From iOS 26, the grouped lists have 26 pt round corners; the app icon rows take that
    /// radius as their total leading padding, so the icons sit clear of the rounded corners.
    @ViewBuilder
    func appIconRowLeadingInset() -> some View {
        if #available(iOS 26, *) {
            listRowInsets(.leading, 26)
        } else {
            self
        }
    }
}
#endif
