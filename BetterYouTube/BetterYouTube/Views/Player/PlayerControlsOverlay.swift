import AVKit
import SwiftUI

/// The player's controls, drawn over the video: the same ones whichever player is behind it —
/// YouTube's embed or a downloaded file — and whether the video sits under the header or fills
/// the screen.
///
/// What YouTube's player offers is all here: play and pause, ten-second skips (also a double tap
/// on either half, as in the YouTube app), a scrubber split into the video's chapters, captions,
/// Picture in Picture, full screen, and a settings menu with quality, captions and their
/// translation, audio track and speed. Holding the right half plays at double speed while held.
///
/// While YouTube plays an ad or shows its end screen, its own layer is the one with something to
/// tap — skip, or one of its suggestions — so the controls step aside and let the taps through.
struct PlayerControlsOverlay: View {
    @ObservedObject var player: PlayerManager
    @ObservedObject var options: PlaybackOptions
    let isFullScreen: Bool
    /// True while a touch on the scrubber or a hold to speed up is in progress, so the player's
    /// pull-down leaves that touch alone.
    @Binding var locksCollapse: Bool

    @AppStorage(HoldToSpeedUpPreference.storageKey) private var holdsToSpeedUp = true
    @AppStorage(SkipIntervalPreference.backKey) private var storedSkipBack = SkipIntervalPreference.defaultSeconds
    @AppStorage(SkipIntervalPreference.forwardKey) private var storedSkipForward = SkipIntervalPreference.defaultSeconds
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @State private var isShown = true
    @State private var hideTask: Task<Void, Never>?
    /// Where the scrubber is being dragged to, while it is.
    @State private var scrubTime: Double?
    /// Set while the settings menu is open, which keeps the controls from hiding under it.
    @State private var isMenuOpen = false
    @State private var skipFeedback: SkipFeedback?
    @GestureState private var isHolding = false

    private var skipBack: Int { SkipIntervalPreference.valid(storedSkipBack) }
    private var skipForward: Int { SkipIntervalPreference.valid(storedSkipForward) }
    /// Not every device has Picture in Picture — the Simulator, for one — and a button that can
    /// only fail is better left out.
    private static let supportsPictureInPicture = AVPictureInPictureController.isPictureInPictureSupported()
    private static let hideDelay: Duration = .seconds(3)

    var body: some View {
        ZStack {
            touchSurface

            if isShown, !options.showsYouTubeLayer {
                chrome
                    .transition(.opacity)
            }

            if options.isSpeedingUp {
                speedBadge
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 12)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    .allowsHitTesting(false)
            }

            if let skipFeedback {
                skipFeedbackView(skipFeedback)
                    .id(skipFeedback.id)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        // White on the picture, whatever the app's appearance: glass and secondary text read as
        // they would in dark mode.
        .environment(\.colorScheme, .dark)
        .allowsHitTesting(!options.showsYouTubeLayer)
        .animation(.easeInOut(duration: 0.2), value: isShown)
        .animation(.easeInOut(duration: 0.2), value: options.showsYouTubeLayer)
        .animation(.snappy, value: options.isSpeedingUp)
        #if os(macOS)
        .onContinuousHover { phase in
            if case .active = phase { show() } else { scheduleHide(after: .milliseconds(600)) }
        }
        #endif
        .onChange(of: player.isPlaying, initial: true) { _, playing in
            // Paused from somewhere else — the lock screen, headphones, leaving the app — the
            // controls come back to say so, as YouTube's do.
            if !playing { isShown = true }
            scheduleHide()
        }
        .onChange(of: isShown, initial: true) { _, shown in player.setControlsShown(shown) }
        .onChange(of: isHolding || scrubTime != nil, initial: true) { _, locked in
            locksCollapse = locked
        }
        .onChange(of: isHolding) { _, holding in
            if holding {
                // The picture is what a held finger wants to see, as in the YouTube app.
                hide()
                player.beginSpeedingUp()
            } else {
                player.endSpeedingUp()
            }
        }
        .onChange(of: isMenuOpen) { _, open in
            if open { hideTask?.cancel() } else { scheduleHide() }
        }
        .onDisappear {
            locksCollapse = false
            hideTask?.cancel()
            player.endSpeedingUp()
            player.setControlsShown(false)
        }
    }

    // MARK: - Touches on the picture

    /// The picture itself, in two halves: a tap shows or hides the controls, a double tap skips
    /// back on the left and forward on the right, and holding the right speeds up. A Mac's
    /// click plays and pauses instead, and its double click fills the window.
    private var touchSurface: some View {
        HStack(spacing: 0) {
            Color.clear
                .contentShape(Rectangle())
                .gesture(taps(skipping: -Double(skipBack)))
            Color.clear
                .contentShape(Rectangle())
                .gesture(hold.exclusively(before: taps(skipping: Double(skipForward))))
        }
        .accessibilityHidden(true)
    }

    private func taps(skipping seconds: Double) -> some Gesture {
        TapGesture(count: 2)
            .onEnded {
                #if os(macOS)
                player.toggleFillsWindow()
                #else
                skip(by: seconds, feedback: true)
                #endif
            }
            .exclusively(before: TapGesture().onEnded {
                #if os(macOS)
                player.togglePlayPause()
                show()
                #else
                if isShown { hide() } else { show() }
                #endif
            })
    }

    private var hold: some Gesture {
        LongPressGesture(minimumDuration: 0.4)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .updating($isHolding) { value, state, _ in
                guard holdsToSpeedUp, case .second(true, _) = value else { return }
                state = true
            }
    }

    // MARK: - The controls

    private var chrome: some View {
        ZStack {
            // A dim over the picture, so white controls read on a white frame.
            Color.black.opacity(0.4)
                .allowsHitTesting(false)

            transport

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                bottomBar
            }
            .padding(.horizontal, isFullScreen ? 20 : 12)
            .padding(.top, isFullScreen ? 16 : 8)
            .padding(.bottom, isFullScreen ? 18 : 2)
        }
    }

    private var topBar: some View {
        HStack(alignment: .top, spacing: 8) {
            if isFullScreen, let video = player.currentVideo {
                VStack(alignment: .leading, spacing: 2) {
                    Text(video.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(video.channelTitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .foregroundStyle(.white)
            }

            Spacer(minLength: 0)

            GlassEffectContainer {
                HStack(spacing: 8) {
                    if !options.captions.isEmpty {
                        Button {
                            player.toggleCaptions()
                            scheduleHide()
                        } label: {
                            Image(systemName: options.caption == nil ? "captions.bubble" : "captions.bubble.fill")
                        }
                        .accessibilityLabel(options.caption == nil ? "Turn On Captions" : "Turn Off Captions")
                    }

                    if Self.supportsPictureInPicture {
                        Button {
                            player.startPictureInPicture()
                        } label: {
                            Image(systemName: "pip.enter")
                        }
                        .accessibilityLabel("Picture in Picture")
                    }

                    settingsMenu
                }
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .foregroundStyle(.white)
        }
    }

    /// Back, play or pause, forward — in the middle of the picture, as in every video player.
    private var transport: some View {
        GlassEffectContainer {
            HStack(spacing: 28) {
                Button {
                    skip(by: -Double(skipBack))
                } label: {
                    Image(systemName: "gobackward.\(skipBack)")
                        .font(.title3)
                        .padding(4)
                }
                .accessibilityLabel("Back \(skipBack) Seconds")

                Button {
                    player.togglePlayPause()
                    scheduleHide()
                } label: {
                    Group {
                        if player.isBuffering && !player.isPlaying {
                            ProgressView()
                        } else {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .contentTransition(.symbolEffect(.replace))
                        }
                    }
                    .font(.title)
                    .frame(width: 36, height: 36)
                    .padding(8)
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

                Button {
                    skip(by: Double(skipForward))
                } label: {
                    Image(systemName: "goforward.\(skipForward)")
                        .font(.title3)
                        .padding(4)
                }
                .accessibilityLabel("Forward \(skipForward) Seconds")
            }
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .foregroundStyle(.white)
        .tint(.white)
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                PlayerTimeLabel(progress: player.progress, options: options, scrubTime: scrubTime)
                Spacer(minLength: 0)
                Button {
                    player.toggleFullScreen()
                } label: {
                    Image(systemName: isFullScreen
                          ? "arrow.down.right.and.arrow.up.left"
                          : "arrow.up.left.and.arrow.down.right")
                        .font(.body.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .accessibilityLabel(isFullScreen ? "Exit Full Screen" : "Full Screen")
            }

            ChapterScrubber(
                progress: player.progress,
                chapters: options.chapters,
                scrubTime: $scrubTime,
                onSeek: { player.seek(to: $0) }
            )
        }
        .onChange(of: scrubTime == nil) { _, ended in
            if ended { scheduleHide() } else { hideTask?.cancel() }
        }
    }

    // MARK: - Settings

    /// YouTube's gear menu, in the system's own menu: each setting a submenu that shows what is
    /// chosen and ticks it.
    private var settingsMenu: some View {
        Menu {
            Group {
                if !options.qualities.isEmpty {
                    Picker(selection: Binding(get: { options.quality }, set: { player.setQuality($0) })) {
                        Text(automaticQualityTitle).tag(PlaybackOptions.automaticQuality)
                        ForEach(options.qualities) { quality in
                            Text(quality.title).tag(quality.id)
                        }
                    } label: {
                        Label("Quality", systemImage: "slider.horizontal.3")
                        Text(qualityTitle)
                    }
                    .pickerStyle(.menu)
                }

                if !options.captions.isEmpty {
                    Menu {
                        Picker("Captions", selection: Binding(
                            get: { options.caption },
                            set: { player.setCaptions($0) }
                        )) {
                            Text("Off").tag(String?.none)
                            ForEach(options.captions) { track in
                                Text(track.title).tag(Optional(track.id))
                            }
                        }
                        .pickerStyle(.inline)

                        if !options.translations.isEmpty {
                            Picker(selection: Binding(
                                get: { options.translation },
                                set: { player.setCaptions(options.caption, translation: $0) }
                            )) {
                                Text("Off").tag(String?.none)
                                ForEach(options.translations) { language in
                                    Text(language.title).tag(Optional(language.id))
                                }
                            } label: {
                                Label("Auto-Translate", systemImage: "translate")
                                if let translation = translationTitle { Text(translation) }
                            }
                            .pickerStyle(.menu)
                        }
                    } label: {
                        Label("Captions", systemImage: "captions.bubble")
                        Text(captionTitle)
                    }
                }

                if !options.audioTracks.isEmpty {
                    Picker(selection: Binding(
                        get: { options.audioTrack ?? "" },
                        set: { player.setAudioTrack($0) }
                    )) {
                        ForEach(options.audioTracks) { track in
                            Text(track.title).tag(track.id)
                        }
                    } label: {
                        Label("Audio Track", systemImage: "waveform")
                        if let title = audioTrackTitle { Text(title) }
                    }
                    .pickerStyle(.menu)
                }

                Picker(selection: Binding(get: { options.rate }, set: { player.setRate($0) })) {
                    ForEach(options.rates, id: \.self) { rate in
                        Text(Self.rateTitle(rate)).tag(rate)
                    }
                } label: {
                    Label("Playback Speed", systemImage: "gauge.with.dots.needle.67percent")
                    Text(Self.rateTitle(options.rate))
                }
                .pickerStyle(.menu)
            }
            .onAppear { isMenuOpen = true }
            .onDisappear { isMenuOpen = false }
        } label: {
            Image(systemName: "gearshape.fill")
        }
        .menuIndicator(.hidden)
        .accessibilityLabel("Settings")
    }

    private var automaticQualityTitle: String {
        guard options.quality == PlaybackOptions.automaticQuality,
              let playing = options.playingQualityLabel else { return String(localized: "Auto") }
        return String(localized: "Auto (\(playing))")
    }

    private var qualityTitle: String {
        if options.quality == PlaybackOptions.automaticQuality { return automaticQualityTitle }
        return options.qualities.first { $0.id == options.quality }?.title ?? automaticQualityTitle
    }

    private var captionTitle: String {
        guard let caption = options.caption,
              let track = options.captions.first(where: { $0.id == caption }) else {
            return String(localized: "Off")
        }
        if let translation = translationTitle { return "\(track.title) → \(translation)" }
        return track.title
    }

    private var translationTitle: String? {
        guard let translation = options.translation else { return nil }
        return options.translations.first { $0.id == translation }?.title ?? translation
    }

    private var audioTrackTitle: String? {
        options.audioTracks.first { $0.id == options.audioTrack }?.title
    }

    /// "Normal" at 1×, as YouTube says it; the factor otherwise — "1.5×".
    static func rateTitle(_ rate: Double) -> String {
        rate == 1 ? String(localized: "Normal", comment: "Playback speed of 1×") : "\(rate.formatted(.number))×"
    }

    // MARK: - Feedback

    private var speedBadge: some View {
        Label {
            Text(verbatim: "\(HoldToSpeedUpPreference.rate.formatted(.number))×")
        } icon: {
            Image(systemName: "forward.fill")
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: Capsule())
        .accessibilityLabel("Playing at Double Speed")
    }

    private func skipFeedbackView(_ feedback: SkipFeedback) -> some View {
        HStack {
            if feedback.seconds > 0 { Spacer() }
            Label {
                Text(verbatim: "\(Int(abs(feedback.seconds))) s")
            } icon: {
                Image(systemName: feedback.seconds > 0 ? "forward.fill" : "backward.fill")
            }
            .labelStyle(.titleAndIcon)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: Capsule())
            .padding(.horizontal, 32)
            if feedback.seconds < 0 { Spacer() }
        }
    }

    // MARK: - Showing and hiding

    private func skip(by seconds: Double, feedback: Bool = false) {
        player.seek(to: player.progress.currentTime + seconds)
        scheduleHide()
        guard feedback else { return }
        let shown = SkipFeedback(seconds: seconds)
        withAnimation(.easeOut(duration: 0.15)) { skipFeedback = shown }
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard skipFeedback?.id == shown.id else { return }
            withAnimation(.easeIn(duration: 0.25)) { skipFeedback = nil }
        }
    }

    private func show() {
        isShown = true
        scheduleHide()
    }

    private func hide() {
        hideTask?.cancel()
        isShown = false
    }

    /// Playing, the controls get out of the way after a few seconds untouched. Paused, they stay —
    /// and they always stay for VoiceOver, which has to be able to find them.
    private func scheduleHide(after delay: Duration = Self.hideDelay) {
        hideTask?.cancel()
        guard player.isPlaying, !voiceOverEnabled, !isMenuOpen, scrubTime == nil else { return }
        hideTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            isShown = false
        }
    }
}

/// A double tap's "10 s", shown on the side it skipped towards.
private struct SkipFeedback: Equatable {
    let id = UUID()
    let seconds: Double
}

// MARK: - Time and scrubber

/// "1:23 / 10:00", and the chapter playing, as YouTube shows them. Observes the position on its
/// own, so the rest of the controls don't redraw four times a second.
private struct PlayerTimeLabel: View {
    @ObservedObject var progress: PlaybackProgress
    @ObservedObject var options: PlaybackOptions
    let scrubTime: Double?

    var body: some View {
        let time = scrubTime ?? progress.currentTime
        HStack(spacing: 6) {
            Text(verbatim: "\(PlaybackTimeFormatter.string(time)) / \(PlaybackTimeFormatter.string(progress.duration))")
                .monospacedDigit()
            if let chapter = options.chapter(at: time), !chapter.title.isEmpty {
                Text(verbatim: "·")
                    .foregroundStyle(.secondary)
                Text(chapter.title)
                    .lineLimit(1)
            }
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(.white)
        .accessibilityElement(children: .combine)
    }
}

/// The progress bar, split into the video's chapters the way YouTube's is.
///
/// A custom control because a `Slider` can't draw segments; to VoiceOver it *is* a slider, through
/// its accessibility representation, and adjusting it seeks as dragging does.
private struct ChapterScrubber: View {
    @ObservedObject var progress: PlaybackProgress
    let chapters: [VideoChapter]
    @Binding var scrubTime: Double?
    let onSeek: (Double) -> Void

    private static let gap: CGFloat = 2

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let duration = progress.duration
            let time = scrubTime ?? progress.currentTime
            let fraction = duration > 0 ? min(1, max(0, time / duration)) : 0
            let isScrubbing = scrubTime != nil

            ZStack(alignment: .leading) {
                HStack(spacing: Self.gap) {
                    ForEach(segments(duration: duration), id: \.start) { segment in
                        segmentBar(segment, fraction: fraction, duration: duration,
                                   highlighted: isScrubbing && segment.contains(time))
                            .frame(width: max(0, segment.width(in: width, duration: duration, gap: Self.gap)))
                    }
                }
                .frame(height: isScrubbing ? 6 : 4)

                // A plain dot at rest; held, it grows into a glass lens over the bar.
                Circle()
                    .fill(.tint.opacity(isScrubbing ? 0 : 1))
                    .glassEffect(isScrubbing ? .regular.tint(.red) : .identity, in: Circle())
                    .frame(width: isScrubbing ? 28 : 12, height: isScrubbing ? 28 : 12)
                    .offset(x: fraction * width - (isScrubbing ? 14 : 6))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0 else { return }
                        scrubTime = min(1, max(0, value.location.x / width)) * duration
                    }
                    .onEnded { value in
                        guard duration > 0 else { return }
                        onSeek(min(1, max(0, value.location.x / width)) * duration)
                        scrubTime = nil
                    }
            )
            .animation(.snappy(duration: 0.2), value: isScrubbing)
        }
        .frame(height: 28)
        .accessibilityRepresentation {
            Slider(
                value: Binding(get: { progress.currentTime }, set: { onSeek($0) }),
                in: 0...max(progress.duration, 1)
            ) {
                Text("Playback Position")
            }
            .accessibilityValue(Text(verbatim: PlaybackTimeFormatter.string(progress.currentTime)))
        }
    }

    private struct Segment {
        let start: Double
        let end: Double

        func contains(_ time: Double) -> Bool { time >= start && time < end }

        func width(in total: CGFloat, duration: Double, gap: CGFloat) -> CGFloat {
            guard duration > 0 else { return total }
            return total * CGFloat((end - start) / duration) - gap
        }
    }

    /// One segment per chapter, or a single one for the whole video.
    private func segments(duration: Double) -> [Segment] {
        let starts = chapters.map(\.start).filter { $0 < duration }
        guard duration > 0, starts.count > 1 else { return [Segment(start: 0, end: max(duration, 1))] }
        return starts.enumerated().map { index, start in
            Segment(start: start, end: index + 1 < starts.count ? starts[index + 1] : duration)
        }
    }

    private func segmentBar(_ segment: Segment, fraction: Double, duration: Double, highlighted: Bool) -> some View {
        let played = duration > 0
            ? min(1, max(0, (fraction * duration - segment.start) / (segment.end - segment.start)))
            : 0
        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(highlighted ? 0.55 : 0.35))
                Capsule().fill(.tint)
                    .frame(width: proxy.size.width * played)
            }
        }
        .scaleEffect(y: highlighted ? 1.4 : 1)
    }
}
