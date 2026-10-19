import Foundation

/// One entry in one of the player's settings menus: a quality, a caption track, a language to
/// translate captions into, an audio track.
struct PlaybackChoice: Identifiable, Hashable, Sendable, Decodable {
    let id: String
    let title: String
}

/// A chapter of the video. Chapters split the scrubber into segments, as on YouTube.
struct VideoChapter: Identifiable, Hashable, Sendable, Decodable {
    let title: String
    /// Where it starts, in seconds.
    let start: Double
    /// YouTube's picture of the chapter. Chapters read from a description have none.
    var thumbnail: URL?
    var id: Double { start }
}

/// What the player's settings menu offers for the video playing now — the same as YouTube's own:
/// quality, captions (with auto-translate), audio track and speed — plus the chapters the
/// scrubber is split into.
///
/// Published apart from `PlayerManager`, as the playback position is: the embed reports these
/// once a second, and only the player's controls need to redraw when they change.
@MainActor
final class PlaybackOptions: ObservableObject {
    static let standardRates: [Double] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]
    /// The quality YouTube's menu calls Auto, which lets the player follow the connection.
    static let automaticQuality = "auto"

    /// Fixed qualities on offer, best first. Empty when there is nothing to choose, as with a
    /// downloaded file.
    @Published private(set) var qualities: [PlaybackChoice] = []
    /// The quality asked for: `automaticQuality` or the id of one of `qualities`.
    @Published private(set) var quality = PlaybackOptions.automaticQuality
    /// What is actually playing — "720p" — which is what Auto is shown with.
    @Published private(set) var playingQualityLabel: String?
    @Published private(set) var captions: [PlaybackChoice] = []
    /// The caption track shown, or nil while captions are off.
    @Published private(set) var caption: String?
    /// The languages YouTube can translate the captions into.
    @Published private(set) var translations: [PlaybackChoice] = []
    /// The language captions are translated into, or nil for none.
    @Published private(set) var translation: String?
    @Published private(set) var audioTracks: [PlaybackChoice] = []
    @Published private(set) var audioTrack: String?
    @Published private(set) var rates = PlaybackOptions.standardRates
    @Published private(set) var rate: Double = 1
    @Published private(set) var chapters: [VideoChapter] = []
    /// While YouTube plays an ad or shows its end screen, its own layer is what the taps are for.
    @Published private(set) var showsYouTubeLayer = false
    /// True while the video plays at double speed because a finger is held on it.
    @Published private(set) var isSpeedingUp = false

    /// Everything a new video starts without. Its chapters are what its description lists until
    /// the player reports YouTube's own.
    func reset(chapters: [VideoChapter] = [], rate: Double = 1) {
        qualities = []
        quality = Self.automaticQuality
        playingQualityLabel = nil
        captions = []
        caption = nil
        translations = []
        translation = nil
        audioTracks = []
        audioTrack = nil
        rates = Self.standardRates
        self.rate = rate
        self.chapters = chapters
        showsYouTubeLayer = false
        isSpeedingUp = false
    }

    /// Takes the embed's report. Each value is assigned only when it changed: the report comes
    /// every time anything in it does, and an unchanged `@Published` value still redraws.
    func apply(_ report: EmbedOptionsReport) {
        update(\.qualities, report.qualities ?? [])
        update(\.quality, report.quality ?? Self.automaticQuality)
        update(\.playingQualityLabel, report.qualityLabel)
        update(\.captions, report.captions ?? [])
        update(\.caption, report.caption)
        update(\.translations, report.translations ?? [])
        update(\.translation, report.translation)
        update(\.audioTracks, report.audioTracks ?? [])
        update(\.audioTrack, report.audioTrack)
        if let rates = report.rates, !rates.isEmpty { update(\.rates, rates) }
        if let rate = report.rate, !isSpeedingUp { update(\.rate, rate) }
        // A video without chapters of YouTube's keeps the ones read from its description.
        if let chapters = report.chapters, !chapters.isEmpty { update(\.chapters, chapters) }
        update(\.showsYouTubeLayer, report.ad == true || report.ended == true)
    }

    /// What a downloaded file offers: its own audio and caption tracks, if it has any.
    func applyLocal(audioTracks: [PlaybackChoice], audioTrack: String?,
                    captions: [PlaybackChoice], caption: String?) {
        update(\.audioTracks, audioTracks)
        update(\.audioTrack, audioTrack)
        update(\.captions, captions)
        update(\.caption, caption)
    }

    /// Shows a choice straight away, before the player confirms it.
    func select(quality: String) { update(\.quality, quality) }
    func select(caption: String?, translation: String?) {
        update(\.caption, caption)
        update(\.translation, translation)
    }
    func select(audioTrack: String) { update(\.audioTrack, audioTrack) }
    func select(rate: Double) { update(\.rate, rate) }
    func setSpeedingUp(_ speedingUp: Bool) { update(\.isSpeedingUp, speedingUp) }

    private func update<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<PlaybackOptions, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    /// The chapter playing at `seconds`.
    func chapter(at seconds: Double) -> VideoChapter? {
        chapters.last { $0.start <= seconds }
    }
}

/// What the embed's page reports about the player, as JSON — see `PlayerManager.shellHTML`.
struct EmbedOptionsReport: Decodable, Sendable {
    let qualities: [PlaybackChoice]?
    let quality: String?
    let qualityLabel: String?
    let captions: [PlaybackChoice]?
    let caption: String?
    let translations: [PlaybackChoice]?
    let translation: String?
    let audioTracks: [PlaybackChoice]?
    let audioTrack: String?
    let rates: [Double]?
    let rate: Double?
    let chapters: [VideoChapter]?
    let ad: Bool?
    let ended: Bool?
}

/// Chapters read from a description, the way YouTube reads them: a list of timestamps, one per
/// line, in order, starting at 0:00, and at least three of them.
/// This is how a downloaded video gets its chapters, and how a streamed one has them before the
/// player reports its own.
enum DescriptionChapters {
    static func parse(_ description: String) -> [VideoChapter] {
        var chapters: [VideoChapter] = []
        for line in description.split(whereSeparator: \.isNewline) {
            let text = String(line)
            let range = NSRange(text.startIndex..., in: text)
            guard let match = pattern.firstMatch(in: text, range: range),
                  let stampRange = Range(match.range(at: 1), in: text),
                  let seconds = RichText.seconds(in: text[stampRange]) else { continue }
            let title = text.replacingCharacters(in: Range(match.range, in: text)!, with: "")
                .trimmingCharacters(in: separators)
            let start = Double(seconds)
            if chapters.isEmpty {
                guard start == 0 else { continue }
            } else if let last = chapters.last {
                // A second list further down (a tracklist, "timestamps in the comments") ends
                // the first rather than mixing into it.
                guard start > last.start else { break }
            }
            chapters.append(VideoChapter(title: title, start: start))
        }
        return chapters.count >= 3 ? chapters : []
    }

    /// A timestamp at the start of a line, with whatever bullet or bracket goes before it.
    private static let pattern = try! NSRegularExpression(
        pattern: #"^\s*[\(\[]?((?:\d{1,2}:)?\d{1,3}:\d{2})[\)\]]?(?![\w:])"#
    )
    private static let separators = CharacterSet.whitespaces
        .union(CharacterSet(charactersIn: "-–—:|•·"))
}

/// Settings → Playback → Player: whose controls a video plays under.
///
/// On an iPhone or an iPad the choice is for the video under its details — full screen is the
/// Full-Screen Player's to decide. On a Mac it holds everywhere, full screen included.
enum PlayerControlsPreference: String, CaseIterable, Identifiable {
    /// The app's own controls, with chapters and YouTube's settings menu — the default.
    case app
    /// YouTube's own player: its controls, menus and end screen, as on its website. It can't
    /// play a downloaded file, which keeps the app's controls.
    case youTube
    /// macOS's own controls on the video, as in Safari, and AVKit's player for a downloaded
    /// file. A Mac's only.
    case system

    static let storageKey = "player_controls"

    /// The choices this platform has.
    static var available: [PlayerControlsPreference] {
        #if os(macOS)
        allCases
        #else
        [.app, .youTube]
        #endif
    }

    static var stored: PlayerControlsPreference {
        let stored = UserDefaults.standard.string(forKey: storageKey).flatMap(Self.init(rawValue:)) ?? .app
        return available.contains(stored) ? stored : .app
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .app: return String(localized: "This App's Player")
        case .youTube: return String(localized: "YouTube's Player")
        case .system: return String(localized: "macOS Player")
        }
    }

    /// What the choice gives, said under it in Settings.
    var summary: String {
        #if os(macOS)
        switch self {
        case .app:
            return String(localized: "This app's controls, with chapters on the progress bar and a menu for quality, captions, audio track and speed. Click the video to play or pause it, double-click it for full screen, and use YouTube's keyboard shortcuts.")
        case .youTube:
            return String(localized: "YouTube's own controls, menus, keyboard shortcuts and end screen, as on its website. Downloaded videos keep this app's player.")
        case .system:
            return String(localized: "macOS's own controls, as in Safari, with AirPlay, Picture in Picture and full screen. YouTube chooses the quality, and there's no menu for captions or audio tracks. Downloaded videos play in macOS's player too.")
        }
        #else
        switch self {
        case .app, .system:
            return String(localized: "This app's controls, with chapters on the progress bar and a menu for quality, captions, audio track and speed.")
        case .youTube:
            return String(localized: "YouTube's own controls, menus and end screen, as on its website. Full screen still uses the player chosen below, and downloaded videos keep this app's player.")
        }
        #endif
    }
}

/// Settings → Playback → Full Screen: which player takes over when the phone is turned.
enum FullScreenPlayerPreference: String, CaseIterable, Identifiable {
    /// The app's own player, with its controls and menus — the default.
    case app
    /// iOS's player, with the system's controls.
    case system

    static let storageKey = "full_screen_player"

    static var stored: FullScreenPlayerPreference {
        UserDefaults.standard.string(forKey: storageKey).flatMap(Self.init(rawValue:)) ?? .app
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .app: return String(localized: "This App's Player")
        case .system: return String(localized: "iOS Player")
        }
    }

    /// What the choice gives, said under it in Settings.
    var summary: String {
        switch self {
        case .app:
            return String(localized: "In full screen, the video keeps this app's controls, with chapters, captions and the settings menu. Pinch out to fill the screen.")
        case .system:
            return String(localized: "In full screen, iOS's player takes over, with the system's controls but without YouTube's captions.")
        }
    }
}

/// Settings → Playback → Hold to Speed Up: touching and holding the right half of the video — or,
/// on a Mac, holding the mouse down on it — plays it at double speed until let go, as YouTube
/// does. On unless turned off.
enum HoldToSpeedUpPreference {
    static let storageKey = "hold_to_speed_up"
    static let rate: Double = 2

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: storageKey) as? Bool ?? true
    }
}

/// Settings → Playback → Background Playback: the sound goes on when the app is left or the
/// iPhone locked. On unless turned off.
enum BackgroundPlaybackPreference {
    static let storageKey = "background_playback"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: storageKey) as? Bool ?? true
    }
}

/// Settings → Playback → Picture in Picture: a playing video moves to its Picture in Picture
/// window when the app is left for the Home Screen. Off unless turned on.
enum AutoPictureInPicturePreference {
    static let storageKey = "auto_picture_in_picture"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: storageKey)
    }
}

/// Settings → Playback → Skip Back and Skip Forward: how far the player's skip buttons, a double
/// tap on the video and the lock screen's skip buttons jump. Ten seconds unless changed.
enum SkipIntervalPreference {
    static let backKey = "skip_back_seconds"
    static let forwardKey = "skip_forward_seconds"
    /// The lengths SF Symbols draw a skip button for.
    static let choices = [5, 10, 15, 30, 45, 60]
    static let defaultSeconds = 10

    static var back: Int { stored(backKey) }
    static var forward: Int { stored(forwardKey) }

    /// A stored value no button can be drawn for falls back to the default.
    static func valid(_ seconds: Int) -> Int {
        choices.contains(seconds) ? seconds : defaultSeconds
    }

    private static func stored(_ key: String) -> Int {
        valid(UserDefaults.standard.integer(forKey: key))
    }
}
