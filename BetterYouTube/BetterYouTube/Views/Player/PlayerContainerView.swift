import SwiftUI

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
    /// The pull-down that shrinks the expanded player back into the bar.
    @State private var drag = PlayerDragState()
    /// The separate flick that expands or dismisses the docked bar.
    @State private var barDragOffset: CGFloat = 0

    private let metrics = PlayerMetrics()

    var body: some View {
        GeometryReader { proxy in
            let layout = PlayerLayout(
                size: proxy.size,
                metrics: metrics,
                compactness: player.isBarCompact ? 1 : 0
            )
            playerBody(in: layout)
                .offset(y: barDragOffset)
        }
        .opacity(player.currentVideo == nil ? 0 : 1)
        .allowsHitTesting(player.currentVideo != nil)
    }

    @ViewBuilder
    private func playerBody(in layout: PlayerLayout) -> some View {
        let expansion = currentExpansion(travel: layout.collapseTravel)
        let bar = layout.barFrame
        let video = layout.expandedVideoFrame
        let scale = layout.videoScale(expansion: expansion)
        let center = layout.videoCenter(expansion: expansion)

        ZStack(alignment: .topLeading) {
            // 1. Backdrops — drawn under the video surface.
            Color(uiColor: .systemBackground)
                .opacity(Double(expansion))
                .ignoresSafeArea()
                .allowsHitTesting(player.isExpanded)

            MiniPlayerBackground(cornerRadius: layout.barCornerRadius)
                .frame(width: bar.width, height: bar.height)
                .position(x: bar.midX, y: bar.midY)
                .opacity(Double(1 - expansion))
                .onTapGesture { player.expand() }
                .gesture(barDragGesture)
                .allowsHitTesting(!player.isExpanded)

            // 2. The one and only video surface. It keeps its full-screen layout size in every
            //    state and is *scaled* into the bar rather than resized: re-laying out a web view
            //    on every frame of a drag is what made collapsing the player stutter. Expanded,
            //    it takes the taps so YouTube's own controls work; docked, they fall through to
            //    the bar and expand the player.
            PlayerSurface(webView: player.webView)
                .frame(width: video.width, height: video.height)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: layout.videoCornerRadius(expansion: expansion) / max(scale, 0.01),
                        style: .continuous
                    )
                )
                .simultaneousGesture(collapseDrag(travel: layout.collapseTravel).gesture)
                .scaleEffect(scale)
                .position(x: center.x, y: center.y)
                .allowsHitTesting(player.isExpanded)

            // 3. Chrome — drawn over the video. The details are mounted only while the player is
            //    expanded, and follow the finger point for point as it pulls them away.
            if player.isExpanded {
                ExpandedPlayerView(
                    videoHeight: video.height,
                    headerHeight: metrics.headerHeight,
                    travel: layout.collapseTravel,
                    drag: $drag
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
                compactness: layout.compactness
            )
            .frame(width: bar.width, height: bar.height)
            .clipShape(RoundedRectangle(cornerRadius: layout.barCornerRadius, style: .continuous))
            .position(x: bar.midX, y: bar.midY)
            .opacity(Double(1 - expansion))
            .allowsHitTesting(!player.isExpanded)
        }
    }

    /// 1 full screen, 0 docked. Pulling the expanded player down walks it between the two, over
    /// exactly the distance the video has to travel.
    private func currentExpansion(travel: CGFloat) -> CGFloat {
        guard player.isExpanded else { return 0 }
        return max(0, 1 - drag.translation / travel)
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
        DragGesture()
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

// MARK: - Shrinking the bar on scroll

extension View {
    /// Shrinks the docked bar to its pill as you scroll down and brings it back when you scroll
    /// up, so it behaves like the tab bar it sits on — `tabBarMinimizeBehavior` is the tab bar's
    /// half of the same idea. Attach it to a screen's scroll view.
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
    let barInset: CGFloat = 20
    let barCornerRadius: CGFloat = 26
    /// Room left below the bar for the floating tab bar.
    let tabBarClearance: CGFloat = 52
    let artworkPadding: CGFloat = 8
    let headerHeight: CGFloat = 44
    /// The pill the bar shrinks to on scroll keeps the artwork and play/pause, nothing else.
    let compactBarHeight: CGFloat = 52
    let playButtonWidth: CGFloat = 38
    let closeButtonWidth: CGFloat = 38
    let controlsTrailingPadding: CGFloat = 10
    /// Gap between the artwork and the title.
    let labelGap: CGFloat = 10
}

/// Interpolates the player between the three shapes it can take. The bar keeps its trailing edge
/// as it shrinks, so the pill ends up in the bottom-right corner, clear of the minimized tab bar.
private struct PlayerLayout {
    let size: CGSize
    let metrics: PlayerMetrics
    /// 0 the full-width bar, 1 the compact pill.
    let compactness: CGFloat

    var barFrame: CGRect { barFrame(at: compactness) }
    var dockedVideoFrame: CGRect { dockedVideoFrame(at: compactness) }

    func barFrame(at compactness: CGFloat) -> CGRect {
        let height = lerp(metrics.barHeight, metrics.compactBarHeight, compactness)
        let width = lerp(size.width - metrics.barInset * 2, compactBarWidth, compactness)
        let bottom = size.height - metrics.tabBarClearance
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
        lerp(metrics.barCornerRadius, metrics.compactBarHeight / 2, compactness)
    }

    /// The video full screen, sitting under the header.
    var expandedVideoFrame: CGRect {
        CGRect(x: 0, y: metrics.headerHeight, width: size.width, height: size.width * 9 / 16)
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
        lerp(10, 0, expansion)
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

    @EnvironmentObject private var player: PlayerManager

    /// What survives in the pill: everything else fades and is clipped away.
    private var isCompact: Bool { compactness > 0.5 }

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .overlay(alignment: .leading) { labels }
            .overlay(alignment: .trailing) { transport }
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
        .contentShape(Rectangle())
        .onTapGesture { player.expand() }
        .opacity(Double(1 - compactness))
        .allowsHitTesting(!isCompact)
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

    /// A hairline of progress, clipped to the bar so it follows the rounded corners.
    private var progressLine: some View {
        MiniProgressLine(progress: player.progress)
            .padding(.horizontal, 14)
            .padding(.bottom, 3)
            .allowsHitTesting(false)
    }
}

/// The played fraction. It watches the progress object rather than the player itself, so the
/// position ticks — several a second — only ever redraw these two and a half points.
private struct MiniProgressLine: View {
    @ObservedObject var progress: PlaybackProgress

    var body: some View {
        GeometryReader { proxy in
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: proxy.size.width * progress.fraction)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .frame(height: 2.5)
    }
}
