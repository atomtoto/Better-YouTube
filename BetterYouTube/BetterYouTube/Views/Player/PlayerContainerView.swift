import SwiftUI

/// The two shapes available while playback is tucked out of the way.
enum MiniPlayerStyle: String, CaseIterable, Identifiable {
    case floatingVideo
    case playbackBar

    static let storageKey = "mini_player_style"

    static var platformDefault: MiniPlayerStyle {
        #if os(macOS)
        .floatingVideo
        #else
        .playbackBar
        #endif
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .floatingVideo: return "Floating"
        case .playbackBar: return "Playback Bar"
        }
    }
}

enum FloatingMiniPlayerSize: String, CaseIterable, Identifiable {
    case compact, standard, large

    static let storageKey = "floating_mini_player_size"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact: return "Compact"
        case .standard: return "Standard"
        case .large: return "Large"
        }
    }
}

/// The player that lives above every screen. It morphs between a bar docked over the tab bar and
/// a full-screen player, moving one shared video surface between the two positions rather than
/// rebuilding it — so the video never restarts.
///
/// Every position, size and opacity below is a function of two numbers: `expansion` (0 docked,
/// 1 full screen) and `compactness` (0 the full-width bar, 1 the pill it shrinks to when you
/// scroll down). Both are plain interpolations, so a half-finished drag has a well-defined
/// layout instead of a jump, and the finger can drive it directly.
struct PlayerContainerView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var downloads: DownloadStore
    @EnvironmentObject private var downloadManager: DownloadManager
    /// The pull-down that shrinks the expanded player back into the bar.
    @State private var drag = PlayerDragState()
    /// The separate flick that expands or dismisses the docked bar.
    @State private var barDragOffset: CGFloat = 0
    @State private var floatingOnLeft = false
    @State private var horizontalDrag: CGFloat = 0
    @State private var expandedScrollOffset: CGFloat = 0
    @AppStorage(MiniPlayerStyle.storageKey) private var miniPlayerStyle = MiniPlayerStyle.platformDefault
    @AppStorage(FloatingMiniPlayerSize.storageKey) private var floatingSize = FloatingMiniPlayerSize.standard
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif

    private let metrics = PlayerMetrics()

    #if os(iOS)
    /// The phone on its side, which is what puts the video full screen. A compact height is
    /// exactly that: portrait and every iPad layout are regular.
    ///
    /// A Mac has no counterpart: a window has no orientation, so full screen there is asked for
    /// rather than inferred — see `PlayerManager.toggleFillsWindow`.
    private var isLandscape: Bool { verticalSizeClass == .compact }
    #endif

    var body: some View {
        GeometryReader { proxy in
            let layout = PlayerLayout(
                size: proxy.size,
                metrics: metrics,
                compactness: player.isBarCompact ? 1 : 0,
                style: miniPlayerStyle,
                floatingSize: floatingSize,
                floatingOnLeft: floatingOnLeft,
                horizontalDrag: horizontalDrag,
                isFullScreen: player.isFullScreen
            )
            playerBody(in: layout)
                .offset(y: barDragOffset)
        }
        // Full screen means the whole screen: the geometry above has to measure past the notch
        // and the home indicator too, so the video reaches both edges.
        .ignoresSafeArea(.container, edges: player.isFullScreen ? .all : [])
        .opacity(player.currentVideo == nil ? 0 : 1)
        .scaleEffect(player.currentVideo == nil ? 0.96 : 1, anchor: .bottom)
        .animation(.spring(response: 0.42, dampingFraction: 0.88), value: player.currentVideo?.id)
        .allowsHitTesting(player.currentVideo != nil)
        .systemChromeHidden(player.isFullScreen)
        .alert("Picture in Picture", isPresented: Binding(
            get: { player.pictureInPictureError != nil },
            set: { if !$0 { player.pictureInPictureError = nil } }
        )) {
            Button("OK", role: .cancel) { player.pictureInPictureError = nil }
        } message: {
            Text(player.pictureInPictureError ?? "")
        }
        #if os(iOS)
        .onChange(of: isLandscape, initial: true) { _, landscape in
            player.setLandscape(landscape)
        }
        #endif
        .onChange(of: player.isExpanded) { _, expanded in
            if !expanded { expandedScrollOffset = 0 }
        }
        .onChange(of: player.currentVideo?.id) { _, _ in
            expandedScrollOffset = 0
        }
    }

    @ViewBuilder
    private func playerBody(in layout: PlayerLayout) -> some View {
        let expansion = currentExpansion(travel: layout.collapseTravel)
        let bar = layout.barFrame
        let video = layout.expandedVideoFrame
        let scale = layout.videoScale(expansion: expansion)
        let center = layout.videoCenter(expansion: expansion)

        ZStack(alignment: .topLeading) {
            // 1. Backdrops — drawn under the video surface. Black full screen, so the bars
            //    beside a video that isn't the screen's shape read as part of the picture.
            (player.isFullScreen ? Color.black : Color.appBackground)
                .opacity(Double(expansion))
                .ignoresSafeArea()
                .allowsHitTesting(player.isExpanded)

            MiniPlayerBackground(cornerRadius: layout.barCornerRadius)
                .frame(width: bar.width, height: bar.height)
                .position(x: bar.midX, y: bar.midY)
                .opacity(Double(1 - expansion))
                .allowsHitTesting(false)

            // 2. The one and only video surface. It keeps its full-screen layout size in every
            //    state and is *scaled* into the bar rather than resized: re-laying out a web view
            //    on every frame of a drag is what made collapsing the player stutter. Expanded,
            //    it takes the taps so YouTube's own controls work; docked, they fall through to
            //    the bar and expand the player.
            videoSurface
                .frame(width: video.width, height: video.height)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: layout.videoCornerRadius(expansion: expansion) / max(scale, 0.01),
                        style: .continuous
                    )
                )
                // Local transport handles its own gestures; the header still allows collapse.
                .simultaneousGesture(
                    collapseDrag(travel: layout.collapseTravel).gesture,
                    including: player.isFullScreen || player.isLocal ? .subviews : .all
                )
                .scaleEffect(scale)
                .position(x: center.x, y: center.y - videoScrollOffset * expansion)
                .allowsHitTesting(player.isExpanded)
                #if os(macOS)
                // The macOS ScrollView occupies the whole window. Keep the shared video above
                // its transparent gap so YouTube's playback controls still receive clicks.
                .zIndex(player.isExpanded ? 1 : 0)
                #endif

            // 3. Chrome — drawn over the video. The details are mounted only while the player is
            //    expanded, and follow the finger point for point as it pulls them away. Full
            //    screen there is no chrome at all: the video has the screen to itself.
            if player.isExpanded, !player.isFullScreen {
                ExpandedPlayerView(
                    videoHeight: video.height,
                    headerHeight: metrics.headerHeight,
                    travel: layout.collapseTravel,
                    drag: $drag,
                    scrollOffset: $expandedScrollOffset
                )
                .frame(width: layout.size.width, height: layout.size.height)
                .offset(y: drag.translation)
                .opacity(chromeOpacity(expansion: expansion))
                .transition(.opacity)
            }

            MiniPlayerControls(
                metrics: metrics,
                artworkExtent: layout.artworkExtent,
                labelWidth: layout.labelWidth,
                compactness: layout.compactness,
                style: layout.style,
                floatingControlDiameter: layout.floatingControlDiameter,
                barCornerRadius: layout.barCornerRadius
            )
            .frame(width: bar.width, height: bar.height)
            .clipShape(RoundedRectangle(cornerRadius: layout.barCornerRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: layout.barCornerRadius, style: .continuous))
            #if !os(macOS)
            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: layout.barCornerRadius, style: .continuous))
#endif
            .simultaneousGesture(floatingDrag, including: miniPlayerStyle == .floatingVideo ? .all : .none)
            .gesture(barDragGesture)
            .onTapGesture { player.expand() }
            .contextMenu {
                PlayerActions(
                    player: player,
                    downloads: downloads,
                    downloadManager: downloadManager,
                    miniPlayerStyle: miniPlayerStyle,
                    onSwitchMiniPlayerStyle: switchMiniPlayerStyle
                )
            } preview: {
                MiniPlayerBoxPreview(
                    video: player.currentVideo,
                    isPlaying: player.isPlaying,
                    progress: player.progress,
                    layout: layout,
                    metrics: metrics
                )
            }
            .position(x: bar.midX, y: bar.midY)
            .opacity(Double(1 - expansion))
            // Must stay last: contextMenu installs its own interaction wrapper. Disabling the
            // inner view before that wrapper leaves an invisible menu layer over the expanded
            // player and swallows its controls.
            .allowsHitTesting(!player.isExpanded)
            #if os(macOS)
            .zIndex(2)
            #endif
        }
    }

    /// Commit the anchor and clear the translation in the same animation transaction.
    /// GestureState's automatic reset used to jump back before the snap animation began.
    private var floatingDrag: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { horizontalDrag = value.translation.width }
            }
            .onEnded { value in
                withAnimation(.snappy) {
                    if abs(value.translation.width) > abs(value.translation.height) {
                        floatingOnLeft = value.predictedEndTranslation.width < 0
                    }
                    horizontalDrag = 0
                }
            }
    }

    private func switchMiniPlayerStyle() {
        guard !player.isExpanded else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            miniPlayerStyle = miniPlayerStyle == .floatingVideo ? .playbackBar : .floatingVideo
        }
    }

    /// Whichever player is live. They swap in the same slot and are laid out identically, so
    /// the morph between the bar and full screen is unaware that there are two of them — and a
    /// downloaded video docks, expands and goes full screen exactly like a streamed one.
    @ViewBuilder
    private var videoSurface: some View {
        if player.isLocal {
            #if os(iOS)
            LocalPlayerSurface(playback: player.local, showsControls: player.isExpanded)
            #else
            LocalPlayerSurface(playback: player.local)
            #endif
        } else {
            PlayerSurface(webView: player.webView)
        }
    }

    /// 1 full screen, 0 docked. Pulling the expanded player down walks it between the two, over
    /// exactly the distance the video has to travel.
    private func currentExpansion(travel: CGFloat) -> CGFloat {
        guard player.isExpanded else { return 0 }
        return max(0, 1 - drag.translation / travel)
    }

    private var videoScrollOffset: CGFloat {
        #if os(macOS)
        player.isExpanded && !player.isFullScreen ? expandedScrollOffset : 0
        #else
        0
        #endif
    }

    /// The details fade early in the pull, leaving the video as the only thing still travelling.
    private func chromeOpacity(expansion: CGFloat) -> Double {
        max(0, min(1, (Double(expansion) - 0.55) / 0.45))
    }

    private func collapseDrag(travel: CGFloat) -> PlayerCollapseDrag {
        PlayerCollapseDrag(state: $drag, travel: travel) { player.collapse() }
    }

    /// Flick the docked bar up to go full screen, down to dismiss it.
    private var barDragGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                barDragOffset = value.translation.height / (value.translation.height < 0 ? 4 : 2)
            }
            .onEnded { value in
                withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
                    barDragOffset = 0
                }
                if value.translation.height < -40 {
                    player.expand()
                } else if value.translation.height > 60 {
                    player.close()
                }
            }
    }
}

// MARK: - The pull-down that collapses the player

/// Live state of the pull-down. It lives in `PlayerContainerView` so that the header, which is
/// drawn by `ExpandedPlayerView`, and the video surface can both drive the same drag.
struct PlayerDragState {
    /// How far the finger has pulled, in points, downwards only.
    var translation: CGFloat = 0
    /// Set once the drag reads as vertical, so sideways scrubs stay with YouTube's controls.
    var isVertical = false
}

/// The pull-down itself, built the same way wherever it is attached, so the drag starts wherever
/// your thumb already is — the header or the video.
struct PlayerCollapseDrag {
    @Binding var state: PlayerDragState
    /// How far the video travels to reach the bar; the drag maps onto it point for point.
    let travel: CGFloat
    let onCollapse: () -> Void

    /// Let go past this share of the travel and the player collapses instead of springing back.
    /// Static so the memberwise initializer stays visible to the header, which builds one too.
    private static let commitFraction: CGFloat = 0.22

    var gesture: some Gesture {
        // Global coordinates: the surface this is attached to is scaled, and a local translation
        // would be divided by that scale — the video would bolt away from the finger.
        DragGesture(minimumDistance: 10, coordinateSpace: .global)
            .onChanged { value in
                if !state.isVertical {
                    guard value.translation.height > abs(value.translation.width) else { return }
                    state.isVertical = true
                }
                state.translation = min(max(0, value.translation.height), travel)
            }
            .onEnded { value in
                let wasDragging = state.isVertical
                state.isVertical = false
                guard wasDragging else { return }

                // Where the flick was heading, so a short fast pull collapses too.
                let projected = max(value.translation.height, value.predictedEndTranslation.height)
                withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
                    state.translation = 0
                    if projected > travel * Self.commitFraction { onCollapse() }
                }
            }
    }
}

// MARK: - The player's menu

/// What you can do to the playing video, wherever the player offers a menu: the expanded
/// player's ellipsis and the docked player's long-press menu.
struct PlayerActions: View {
    /// Handed in rather than read from the environment: this is built inside a menu, whose
    /// content is a presentation of its own, and an `@EnvironmentObject` resolved in there has
    /// no owner to find.
    @ObservedObject var player: PlayerManager
    @ObservedObject var downloads: DownloadStore
    @ObservedObject var downloadManager: DownloadManager
    var miniPlayerStyle: MiniPlayerStyle? = nil
    var onSwitchMiniPlayerStyle: (() -> Void)? = nil
    var onAddToPlaylist: (() -> Void)? = nil

    var body: some View {
        if let miniPlayerStyle, let onSwitchMiniPlayerStyle {
            Button(action: onSwitchMiniPlayerStyle) {
                Label(
                    miniPlayerStyle == .floatingVideo
                        ? "Switch to Playback Bar"
                        : "Switch to Floating",
                    systemImage: miniPlayerStyle == .floatingVideo
                        ? "rectangle.bottomthird.inset.filled"
                        : "pip"
                )
            }
        }
        // AVKit exposes its own PiP button for local iOS playback.
        #if os(iOS)
        if !player.isLocal {
            Button { player.startPictureInPicture() } label: {
                Label("Picture in Picture", systemImage: "pip.enter")
            }
        }
        #else
        Button { player.startPictureInPicture() } label: {
            Label("Picture in Picture", systemImage: "pip.enter")
        }
        #endif
        if let video = player.currentVideo {
            DownloadMenuButton(video: video, store: downloads, manager: downloadManager)
            if let onAddToPlaylist {
                Button(action: onAddToPlaylist) {
                    Label("Add to Playlist…", systemImage: "text.badge.plus")
                }
            }
        }
        if let url = player.currentVideo?.watchURL {
            ShareLink(item: url) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            Link(destination: url) {
                Label("Open in YouTube", systemImage: "arrow.up.forward.app")
            }
        }
        Button(role: .destructive) {
            player.close()
        } label: {
            Label("Stop Playback", systemImage: "xmark")
        }
    }
}

// MARK: - Shrinking the bar on scroll

extension View {
    /// Shrinks the docked bar to its pill as you scroll down and brings it back once you reach
    /// the top again, so it behaves like the tab bar it sits on — `tabBarMinimizeBehavior` is
    /// the tab bar's half of the same idea. Attach it to a screen's scroll view.
    func minimizesPlayerBarOnScroll() -> some View {
        onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { previous, current in
            PlayerManager.shared.scrollDidMove(from: previous, to: current)
        }
    }
}

// MARK: - Geometry

/// Fixed measurements of the docked player. The bar is shaped to sit with the floating tab bar:
/// same horizontal inset, same corner radius, just taller. Adjust these together if the tab bar's
/// own metrics change.
private struct PlayerMetrics {
    let barHeight: CGFloat = 62
    let barCornerRadius: CGFloat = 26

    #if os(macOS)
    let barInset: CGFloat = 16
    /// There is no tab bar under the Mac's bar — the sections live in a sidebar — so the only
    /// clearance it needs is the margin it floats on. The window's content is given the same
    /// room back as a bottom safe-area inset, in `RootTabView`.
    let tabBarClearance: CGFloat = 16
    let compactTabBarClearance: CGFloat = 16
    #else
    let barInset: CGFloat = 20
    /// Room left below the full-width bar for the floating tab bar.
    let tabBarClearance: CGFloat = 54
    /// The pill drops into the tab bar's own row rather than hovering above it, and a little
    /// below its bottom edge to line up with the pill the tab bar minimizes to. By then the tab
    /// bar is minimized too — the same scroll shrinks both — so the space beside it is free.
    let compactTabBarClearance: CGFloat = -7
    #endif

    var compactLeadingClearance: CGFloat {
        #if os(iOS)
        // Collapsed system tab button plus a gap, on the same bottom row as the player.
        return 68
        #else
        return 0
        #endif
    }

    let artworkPadding: CGFloat = 8
    let headerHeight: CGFloat = 44
    /// The pill the bar shrinks to on scroll keeps the artwork and play/pause, nothing else.
    let compactBarHeight: CGFloat = 52
    let playButtonWidth: CGFloat = 38
    let closeButtonWidth: CGFloat = 38
    let controlsTrailingPadding: CGFloat = 10
    /// Gap between the artwork and the title.
    let labelGap: CGFloat = 10
    #if os(macOS)
    let floatingVideoWidth: CGFloat = 320
    #endif
}

/// Interpolates the player between the three shapes it can take. The bar keeps its trailing edge
/// as it shrinks and drops as it narrows, so the pill lands in the bottom-right corner — in the
/// tab bar's own row, beside the pill the tab bar has minimized to by then.
private struct PlayerLayout {
    let size: CGSize
    let metrics: PlayerMetrics
    /// 0 the full-width bar, 1 the compact pill.
    let compactness: CGFloat
    let style: MiniPlayerStyle
    let floatingSize: FloatingMiniPlayerSize
    let floatingOnLeft: Bool
    let horizontalDrag: CGFloat
    /// Set in landscape, where the video has the screen to itself.
    let isFullScreen: Bool

    var barFrame: CGRect { barFrame(at: compactness) }
    var dockedVideoFrame: CGRect { dockedVideoFrame(at: compactness) }

    func barFrame(at compactness: CGFloat) -> CGRect {
        if style == .floatingVideo {
            let availableWidth = max(0, size.width - metrics.barInset * 2)
            #if os(macOS)
            let preferredWidth: CGFloat = switch floatingSize {
            case .compact: 260
            case .standard: metrics.floatingVideoWidth
            case .large: 400
            }
            #else
            let (minimum, maximum, fraction): (CGFloat, CGFloat, CGFloat) = switch floatingSize {
            case .compact: (190, 260, 0.44)
            case .standard: (220, 320, 0.54)
            case .large: (260, 400, 0.66)
            }
            let preferredWidth = min(maximum, max(minimum, size.width * fraction))
            #endif
            let expandedWidth = min(preferredWidth, availableWidth)
            let width = lerp(expandedWidth, compactBarWidth, compactness)
            let expandedVideoWidth = max(0, expandedWidth - metrics.artworkPadding * 2)
            let expandedHeight = expandedVideoWidth * 9 / 16 + metrics.artworkPadding * 2
            let height = lerp(expandedHeight, metrics.compactBarHeight, compactness)
            let clearance = lerp(
                metrics.tabBarClearance,
                metrics.compactTabBarClearance,
                compactness
            )
            let bottom = size.height - clearance
            let trailingX = max(metrics.barInset, size.width - metrics.barInset - width)
            let leadingX = min(trailingX, metrics.barInset + metrics.compactLeadingClearance * compactness)
            let anchorX = floatingOnLeft ? leadingX : trailingX
            return CGRect(
                x: min(max(leadingX, anchorX + horizontalDrag), trailingX),
                y: bottom - height,
                width: width,
                height: height
            )
        }
        let height = lerp(metrics.barHeight, metrics.compactBarHeight, compactness)
        let width = lerp(size.width - metrics.barInset * 2, compactBarWidth, compactness)
        let bottom = size.height - lerp(metrics.tabBarClearance, metrics.compactTabBarClearance, compactness)
        return CGRect(
            x: size.width - metrics.barInset - width,
            y: bottom - height,
            width: max(0, width),
            height: max(0, height)
        )
    }

    /// The artwork — really the video surface — inside the bar.
    func dockedVideoFrame(at compactness: CGFloat) -> CGRect {
        let bar = barFrame(at: compactness)
        if style == .floatingVideo {
            let expandedArtworkWidth = max(0, barFrame(at: 0).width - metrics.artworkPadding * 2)
            let expandedArtwork = CGRect(
                x: barFrame(at: 0).minX + metrics.artworkPadding,
                y: barFrame(at: 0).minY + metrics.artworkPadding,
                width: expandedArtworkWidth,
                height: expandedArtworkWidth * 9 / 16
            )
            let compactArtworkHeight = metrics.compactBarHeight - metrics.artworkPadding * 2
            let compactArtwork = CGRect(
                x: bar.minX + metrics.artworkPadding,
                y: bar.minY + metrics.artworkPadding,
                width: compactArtworkHeight * 16 / 9,
                height: compactArtworkHeight
            )
            return CGRect(
                x: bar.minX + metrics.artworkPadding,
                y: bar.minY + metrics.artworkPadding,
                width: lerp(expandedArtwork.width, compactArtwork.width, compactness),
                height: lerp(expandedArtwork.height, compactArtwork.height, compactness)
            )
        }
        let height = max(0, bar.height - metrics.artworkPadding * 2)
        return CGRect(
            x: bar.minX + metrics.artworkPadding,
            y: bar.minY + metrics.artworkPadding,
            width: height * 16 / 9,
            height: height
        )
    }

    /// The pill is exactly as wide as what stays inside it.
    var compactBarWidth: CGFloat {
        let artwork = (metrics.compactBarHeight - metrics.artworkPadding * 2) * 16 / 9
        return metrics.artworkPadding * 2 + artwork
            + metrics.playButtonWidth + metrics.controlsTrailingPadding
    }

    var barCornerRadius: CGFloat {
        return lerp(metrics.barCornerRadius, metrics.compactBarHeight / 2, compactness)
    }

    /// Where the video sits with the player open: under the header in portrait, alone on the
    /// screen in landscape.
    var expandedVideoFrame: CGRect {
        isFullScreen ? fullScreenVideoFrame : headedVideoFrame
    }

    /// The video across the width of the screen, sitting under the header.
    private var headedVideoFrame: CGRect {
        CGRect(x: 0, y: metrics.headerHeight, width: size.width, height: size.width * 9 / 16)
    }

    /// The biggest 16:9 the screen holds, centred in it — height-bound in landscape, so the
    /// video grows to the full height and leaves black to either side rather than being cropped.
    private var fullScreenVideoFrame: CGRect {
        let height = min(size.height, size.width * 9 / 16)
        let width = height * 16 / 9
        return CGRect(
            x: (size.width - width) / 2,
            y: (size.height - height) / 2,
            width: width,
            height: height
        )
    }

    /// How far the video travels between the bar and full screen — and therefore how far the
    /// pull-down runs, which is what keeps the video under the finger the whole way.
    var collapseTravel: CGFloat {
        max(1, dockedVideoFrame(at: 0).midY - expandedVideoFrame.midY)
    }

    /// Room the artwork takes at the bar's leading edge.
    var artworkExtent: CGFloat { dockedVideoFrame.maxX - barFrame.minX }

    /// What the title and channel get in the full bar. They keep that width as the bar shrinks
    /// and are clipped by it, so no text re-flows mid-animation.
    var labelWidth: CGFloat {
        let full = barFrame(at: 0)
        let artwork = dockedVideoFrame(at: 0).maxX - full.minX + metrics.labelGap
        let controls = metrics.playButtonWidth + metrics.closeButtonWidth + metrics.controlsTrailingPadding
        return max(0, full.width - artwork - controls - 4)
    }

    var floatingControlDiameter: CGFloat {
        // Visual size only. The buttons below keep a separate 44-point hit target and therefore
        // do not need the oversized circles produced by a padded button style.
        min(44, max(40, barFrame(at: 0).width * 0.14))
    }

    func videoCenter(expansion: CGFloat) -> CGPoint {
        CGPoint(
            x: lerp(dockedVideoFrame.midX, expandedVideoFrame.midX, expansion),
            y: lerp(dockedVideoFrame.midY, expandedVideoFrame.midY, expansion)
        )
    }

    /// The surface is laid out full screen and scaled down, never resized.
    func videoScale(expansion: CGFloat) -> CGFloat {
        guard expandedVideoFrame.width > 0 else { return 1 }
        return lerp(dockedVideoFrame.width / expandedVideoFrame.width, 1, expansion)
    }

    /// The radius the corners should *look* like; the clip shape is applied before the scale, so
    /// the caller divides it by that scale.
    func videoCornerRadius(expansion: CGFloat) -> CGFloat {
        // The visible inset curve is concentric with the glass card. A fixed 10 pt radius left
        // the floating video's corners visibly squarer than its 26 pt container.
        let dockedRadius: CGFloat
        if style == .floatingVideo {
            dockedRadius = min(
                dockedVideoFrame.height / 2,
                max(0, barCornerRadius - metrics.artworkPadding)
            )
        } else {
            dockedRadius = 10
        }
        return lerp(dockedRadius, 0, expansion)
    }
}

private func lerp(_ from: CGFloat, _ to: CGFloat, _ progress: CGFloat) -> CGFloat {
    from + (to - from) * progress
}

// MARK: - Bar chrome

/// The bar's Liquid Glass.
private struct MiniPlayerBackground: View {
    let cornerRadius: CGFloat

    var body: some View {
        Color.clear
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// Floating Liquid Glass button face used for transport controls.
private struct FloatingPlayerButtonFace: View {
    let systemImage: String
    let diameter: CGFloat
    let iconSize: CGFloat

    init(_ systemImage: String, diameter: CGFloat, iconSize: CGFloat) {
        self.systemImage = systemImage
        self.diameter = diameter
        self.iconSize = iconSize
    }

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: iconSize, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: diameter, height: diameter)
            .glassEffect(.regular.interactive(), in: Circle())
    }
}

/// Labels and transport of the docked player, laid out like Apple Music's: artwork, title and
/// artist, then play/pause and close. Drawn over the video surface, which stands in for artwork.
///
/// Nothing here is laid out against the bar's current width: the labels keep the width they have
/// in the full bar and the transport hugs the trailing edge, which never moves. The bar can then
/// shrink to its pill by clipping and fading rather than by re-flowing text on every frame.
private struct MiniPlayerControls: View {
    let metrics: PlayerMetrics
    /// Room the artwork takes at the bar's leading edge.
    let artworkExtent: CGFloat
    let labelWidth: CGFloat
    /// 0 the full-width bar, 1 the compact pill.
    let compactness: CGFloat
    let style: MiniPlayerStyle
    let floatingControlDiameter: CGFloat
    let barCornerRadius: CGFloat

    @EnvironmentObject private var player: PlayerManager

    /// What survives in the pill: everything else fades and is clipped away.
    private var isCompact: Bool { compactness > 0.5 }

    var body: some View {
        Group {
            if style == .floatingVideo {
                floatingControls
                    .overlay(alignment: .trailing) {
                        transport
                            .opacity(Double(compactness))
                            .allowsHitTesting(isCompact)
                    }
            } else {
                Color.clear
                    .overlay(alignment: .leading) { labels }
                    .overlay(alignment: .trailing) { transport }
                    .overlay(alignment: .bottom) { progressLine }
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: barCornerRadius, style: .continuous))
        #if !os(macOS)
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: barCornerRadius, style: .continuous))
#endif
    }

    /// YouTube's current mini-player shape: the picture is the card, with controls over it.
    private var floatingControls: some View {
        Color.clear
            .overlay {
                Button {
                    player.togglePlayPause()
                } label: {
                    FloatingPlayerButtonFace(
                        player.isPlaying ? "pause.fill" : "play.fill",
                        diameter: floatingControlDiameter,
                        iconSize: floatingControlDiameter * 0.36
                    )
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                .opacity(Double(1 - compactness))
                .allowsHitTesting(!isCompact)
            }
            .overlay(alignment: .topTrailing) {
                Button { player.close() } label: {
                    FloatingPlayerButtonFace("xmark", diameter: 32, iconSize: 12)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(4)
                .accessibilityLabel("Close player")
                .opacity(Double(1 - compactness))
                .allowsHitTesting(!isCompact)
            }
            .overlay(alignment: .bottom) { progressLine }
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(player.currentVideo?.title ?? "")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(player.currentVideo?.channelTitle ?? "")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: labelWidth, alignment: .leading)
        .padding(.leading, artworkExtent + metrics.labelGap)
        .opacity(Double(1 - compactness))
        .allowsHitTesting(false)
    }

    private var transport: some View {
        HStack(spacing: 0) {
            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: metrics.playButtonWidth, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            Button {
                player.close()
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: metrics.closeButtonWidth, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close player")
            .frame(width: metrics.closeButtonWidth * (1 - compactness))
            .opacity(Double(1 - compactness))
            .clipped()
            .allowsHitTesting(!isCompact)
        }
        .padding(.trailing, metrics.controlsTrailingPadding)
    }

    /// The shape clips the progress at its lower edge, including its rounded corners.
    private var progressLine: some View {
        MiniProgressLine(progress: player.progress)
            .allowsHitTesting(false)
    }
}

/// The complete card preview shown during a long-press on the docked player.
/// Lifts the entire box (background, artwork, labels, transport, progress) rather than just individual subviews.
private struct MiniPlayerBoxPreview: View {
    let video: Video?
    let isPlaying: Bool
    @ObservedObject var progress: PlaybackProgress
    let layout: PlayerLayout
    let metrics: PlayerMetrics

    private var isCompact: Bool { layout.compactness > 0.5 }
    private var bar: CGRect { layout.barFrame }

    var body: some View {
        ZStack(alignment: .leading) {
            MiniPlayerBackground(cornerRadius: layout.barCornerRadius)

            if layout.style == .floatingVideo {
                if let url = video?.thumbnailURL {
                    ArtworkView(
                        url: url,
                        cornerRadius: layout.barCornerRadius
                    )
                }

                FloatingPlayerButtonFace(
                    isPlaying ? "pause.fill" : "play.fill",
                    diameter: layout.floatingControlDiameter,
                    iconSize: layout.floatingControlDiameter * 0.36
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack {
                    HStack {
                        Spacer()
                        FloatingPlayerButtonFace("xmark", diameter: 32, iconSize: 12)
                            .padding(4)
                    }
                    Spacer()
                }

                VStack {
                    Spacer()
                    MiniProgressLine(progress: progress)
                }
            } else {
                HStack(spacing: 0) {
                    if let url = video?.thumbnailURL {
                        ArtworkView(
                            url: url,
                            cornerRadius: 10
                        )
                        .frame(
                            width: (metrics.barHeight - metrics.artworkPadding * 2) * 16 / 9,
                            height: metrics.barHeight - metrics.artworkPadding * 2
                        )
                        .padding(.leading, metrics.artworkPadding)
                    }

                    if !isCompact {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(video?.title ?? "")
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text(video?.channelTitle ?? "")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, metrics.labelGap)
                    } else {
                        Spacer(minLength: 0)
                    }

                    HStack(spacing: 0) {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .frame(width: metrics.playButtonWidth, height: 44)

                        if !isCompact {
                            Image(systemName: "xmark")
                                .font(.footnote.weight(.bold))
                                .foregroundStyle(.secondary)
                                .frame(width: metrics.closeButtonWidth, height: 44)
                        }
                    }
                    .padding(.trailing, metrics.controlsTrailingPadding)
                }

                if !isCompact {
                    VStack {
                        Spacer()
                        MiniProgressLine(progress: progress)
                    }
                }
            }
        }
        .frame(width: bar.width, height: bar.height)
        .clipShape(RoundedRectangle(cornerRadius: layout.barCornerRadius, style: .continuous))
    }
}

/// The played fraction, using the original size with rounded ends.
private struct MiniProgressLine: View {
    @ObservedObject var progress: PlaybackProgress

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(Color.accentColor)
                .frame(width: proxy.size.width * progress.fraction)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .frame(height: 2.5)
    }
}
