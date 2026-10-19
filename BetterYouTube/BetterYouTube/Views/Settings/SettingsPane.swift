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
    case account, playback, library, notifications, youTubeHome, downloads, api, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .account: return String(localized: "Account")
        case .playback: return String(localized: "Playback")
        case .library: return String(localized: "Library")
        case .notifications: return String(localized: "Notifications")
        case .youTubeHome: return String(localized: "YouTube Home")
        case .downloads: return String(localized: "Downloads")
        case .api: return String(localized: "API & Quota")
        case .advanced: return String(localized: "Advanced")
        }
    }

    var icon: String {
        switch self {
        case .account: return "person.crop.circle"
        case .playback: return "play.rectangle"
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
        case .playback: return .red
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
    @State private var showsYouTubeSignIn = false
    @AppStorage(LaunchSectionPreference.storageKey) private var launchSection = LaunchSectionPreference.home
    #if os(iOS)
    @AppStorage(SettingsTabPreference.storageKey) private var showsSettingsTab = false
    @AppStorage(SearchTabPreference.storageKey) private var searchInTabBar = false
    #endif

    var body: some View {
        Form {
            switch pane {
            case .account:
                AccountSection()
            case .playback:
                PlaybackSection()
            case .library:
                ICloudSyncSection()
                WatchLaterSection()
                OnThisDeviceSection()
                SearchSection()
            case .notifications:
                NotificationsSection()
            case .youTubeHome:
                YouTubeHomeSection(showsSignIn: $showsYouTubeSignIn)
            case .downloads:
                DownloadsSection()
            case .api:
                APIKeySection()
                QuotaSection()
            case .advanced:
                Section {
                    Picker("Open on", selection: $launchSection) {
                        ForEach(LaunchSectionPreference.allCases) { section in
                            Text(section.title).tag(section)
                        }
                    }
                } header: {
                    Text("Navigation")
                } footer: {
                    Text("Applies the next time Better YouTube opens.")
                }
                #if os(iOS)
                Section {
                    Toggle("Show Settings in Tab Bar", isOn: $showsSettingsTab)
                    Toggle("Search in Tab Bar", isOn: $searchInTabBar)
                } footer: {
                    Text("Search in Tab Bar makes Search a tab like the others, with its field under the title. Turned off, Search is a separate button at the end of the tab bar that turns into a field along the bottom.")
                }
                #endif
                ResetSection()
                AboutSection()
            }
        }
        .settingsFormStyle()
        .sheet(isPresented: $showsYouTubeSignIn) {
            YouTubeSignInView()
        }
        .navigationTitle(pane.title)
        // Only the phone's: the docked player is in this window there. On a Mac it is in the
        // *other* window, and scrolling Settings has no business shrinking it.
        #if os(iOS)
        .minimizesPlayerBarOnScroll()
        #endif
    }
}

private struct SearchSection: View {
    @EnvironmentObject private var recents: RecentSearchStore
    @AppStorage(SearchViewModel.remoteSuggestionsKey) private var suggestsFromYouTube = true

    var body: some View {
        Section {
            Toggle("Suggestions from YouTube", isOn: $suggestsFromYouTube)
            Button("Clear Recent Searches", role: .destructive) {
                recents.clear()
            }
            .disabled(recents.terms.isEmpty)
        } header: {
            Text("Search")
        } footer: {
            Text("As you type, what is in the search field is sent to YouTube's suggestion service, which costs no quota. Turned off, the field suggests only your recent searches.")
        }
    }
}

private struct PlaybackSection: View {
    @AppStorage(MiniPlayerStyle.storageKey) private var miniPlayerStyle = MiniPlayerStyle.platformDefault
    @AppStorage(FloatingMiniPlayerSize.storageKey) private var floatingSize = FloatingMiniPlayerSize.defaultSize
    @AppStorage(PlayerManager.autoplayKey) private var autoplaysNext = true
    @AppStorage(HoldToSpeedUpPreference.storageKey) private var holdsToSpeedUp = true
    @AppStorage(SkipIntervalPreference.backKey) private var skipBack = SkipIntervalPreference.defaultSeconds
    @AppStorage(SkipIntervalPreference.forwardKey) private var skipForward = SkipIntervalPreference.defaultSeconds
    @AppStorage(PlayerControlsPreference.storageKey) private var playerControls = PlayerControlsPreference.app
    #if os(iOS)
    @AppStorage(FullScreenPlayerPreference.storageKey) private var fullScreenPlayer = FullScreenPlayerPreference.app
    @AppStorage(BackgroundPlaybackPreference.storageKey) private var playsInBackground = true
    @AppStorage(AutoPictureInPicturePreference.storageKey) private var startsPictureInPicture = false
    #endif

    /// Whether the app's own controls can still come up. On a Mac, macOS's player takes over
    /// downloaded videos too, so nothing is left for the settings that only those controls use.
    private var usesAppControls: Bool {
        #if os(macOS)
        playerControls != .system
        #else
        true
        #endif
    }

    var body: some View {
        // Which player is the first thing to decide, so it comes first — each choice said in
        // full under it, the way a choice that changes this much should be.
        Section {
            Picker("Player", selection: $playerControls) {
                ForEach(PlayerControlsPreference.available) { player in
                    Text(player.title).tag(player)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } header: {
            Text("Player")
        } footer: {
            Text(playerControls.summary)
        }

        #if os(iOS)
        Section {
            Picker("Full Screen", selection: $fullScreenPlayer) {
                ForEach(FullScreenPlayerPreference.allCases) { player in
                    Text(player.title).tag(player)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } header: {
            Text("Full Screen")
        } footer: {
            Text(fullScreenPlayer.summary)
        }
        #endif

        Section {
            Picker("Skip Back", selection: $skipBack) {
                ForEach(SkipIntervalPreference.choices, id: \.self) { seconds in
                    Text(Duration.seconds(seconds), format: .units(allowed: [.minutes, .seconds], width: .wide))
                        .tag(seconds)
                }
            }
            Picker("Skip Forward", selection: $skipForward) {
                ForEach(SkipIntervalPreference.choices, id: \.self) { seconds in
                    Text(Duration.seconds(seconds), format: .units(allowed: [.minutes, .seconds], width: .wide))
                        .tag(seconds)
                }
            }
        } footer: {
            #if os(macOS)
            Text("How far the player's skip buttons, the arrow keys and the Playback menu jump.")
            #else
            Text("How far the player's skip buttons, a double tap on either side of the video and the lock screen's buttons jump.")
            #endif
        }

        Section {
            Toggle("Hold to Play at 2×", isOn: $holdsToSpeedUp)
                .disabled(!usesAppControls)
        } footer: {
            #if os(macOS)
            Text("Hold the mouse button down on the video to play it at double speed until you let go, as on YouTube. Not available with macOS's player.")
            #else
            Text("Touch and hold the right half of the video to play it at double speed until you let go, as in the YouTube app.")
            #endif
        }

        Section {
            Toggle("Autoplay", isOn: $autoplaysNext)
        } footer: {
            Text("Plays the next video in the list when one ends. Turned off, YouTube's own suggestions stay on screen at the end instead. In a car, the queue always continues.")
        }

        #if os(iOS)
        Section {
            Toggle("Background Playback", isOn: $playsInBackground)
            Toggle("Picture in Picture", isOn: $startsPictureInPicture)
        } footer: {
            Text("Background Playback keeps the sound going when you lock the iPhone or leave the app; turned off, the video pauses. With Picture in Picture, a playing video moves to a small window over your other apps when you go to the Home Screen.")
        }
        #endif

        Section {
            Picker("Style", selection: $miniPlayerStyle) {
                ForEach(MiniPlayerStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }

            if miniPlayerStyle == .floatingVideo {
                Picker("Floating Size", selection: $floatingSize) {
                    ForEach(FloatingMiniPlayerSize.allCases) { size in
                        Text(size.title).tag(size)
                    }
                }
                .pickerStyle(.segmented)
            }
        } header: {
            Text("Mini Player")
        } footer: {
            Text("Floating keeps a resizable 16:9 player in a bottom corner. Playback Bar shows the title and channel across the bottom. Long-press the mini player and choose Switch to change style.")
        }
    }
}
