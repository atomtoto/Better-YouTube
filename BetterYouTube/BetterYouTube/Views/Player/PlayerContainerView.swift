import SwiftUI

/// The player that lives above every screen. It morphs between a mini bar docked over the tab bar
/// and a full-screen player, moving one shared video surface between the two positions rather than
/// rebuilding it — so the video never restarts.
struct PlayerContainerView: View {
    @EnvironmentObject private var player: PlayerManager
    @State private var dragOffset: CGFloat = 0

    // The mini bar is shaped to sit with the floating tab bar: same horizontal inset, same corner
    // radius, just taller. Adjust these three together if the tab bar's own metrics change.
    private let miniBarHeight: CGFloat = 62
    private let miniBarInset: CGFloat = 20
    private let miniBarCornerRadius: CGFloat = 26
    /// Room left below the bar for the floating tab bar.
    private let tabBarClearance: CGFloat = 58

    private let artworkPadding: CGFloat = 8
    private let headerHeight: CGFloat = 44

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let expanded = player.isExpanded

            // Where the video sits in each state; the surface animates between the two.
            let miniArtworkHeight = miniBarHeight - artworkPadding * 2
            let miniArtworkWidth = miniArtworkHeight * 16 / 9
            let videoWidth = expanded ? size.width : miniArtworkWidth
            let videoHeight = expanded ? (size.width * 9 / 16) : miniArtworkHeight

            let miniBarCenterY = size.height - tabBarClearance - miniBarHeight / 2
            let videoCenterX = expanded
                ? size.width / 2
                : miniBarInset + artworkPadding + miniArtworkWidth / 2
            let videoCenterY = expanded ? headerHeight + videoHeight / 2 : miniBarCenterY

            ZStack(alignment: .topLeading) {
                // 1. Backdrops — drawn under the video surface.
                Color(uiColor: .systemBackground)
                    .opacity(expanded ? 1 : 0)
                    .ignoresSafeArea()
                    .allowsHitTesting(expanded)

                if !expanded {
                    MiniPlayerBackground(cornerRadius: miniBarCornerRadius)
                        .frame(width: size.width - miniBarInset * 2, height: miniBarHeight)
                        .position(x: size.width / 2, y: miniBarCenterY)
                        .onTapGesture { player.expand() }
                        .gesture(miniDragGesture)
                }

                // 2. The one and only video surface. Expanded, it takes the taps so YouTube's own
                //    controls work; collapsed, taps fall through to the bar and expand the player.
                PlayerSurface(webView: player.webView)
                    .frame(width: videoWidth, height: videoHeight)
                    .clipShape(RoundedRectangle(cornerRadius: expanded ? 0 : 10, style: .continuous))
                    .position(x: videoCenterX, y: videoCenterY)
                    .allowsHitTesting(expanded)

                // 3. Chrome — drawn over the video.
                if expanded {
                    ExpandedPlayerView(
                        videoHeight: videoHeight,
                        headerHeight: headerHeight,
                        dragOffset: $dragOffset
                    )
                    .frame(width: size.width, height: size.height)
                } else {
                    MiniPlayerControls(
                        leadingInset: artworkPadding * 2 + miniArtworkWidth,
                        cornerRadius: miniBarCornerRadius
                    )
                    .frame(width: size.width - miniBarInset * 2, height: miniBarHeight)
                    .position(x: size.width / 2, y: miniBarCenterY)
                }
            }
            .offset(y: dragOffset)
        }
        .opacity(player.currentVideo == nil ? 0 : 1)
        .allowsHitTesting(player.currentVideo != nil)
    }

    /// Flick the mini bar up to go full screen, down to dismiss it.
    private var miniDragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                dragOffset = value.translation.height / (value.translation.height < 0 ? 4 : 2)
            }
            .onEnded { value in
                withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
                    dragOffset = 0
                }
                if value.translation.height < -40 {
                    player.expand()
                } else if value.translation.height > 60 {
                    player.close()
                }
            }
    }
}

/// Liquid Glass where the OS provides it, a material slab everywhere else.
private struct MiniPlayerBackground: View {
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        if #available(iOS 26.0, *) {
            Color.clear
                .glassEffect(.regular, in: shape)
        } else {
            shape
                .fill(.regularMaterial)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
        }
    }
}

/// Labels and transport of the mini player, laid out like Apple Music's: artwork, title and
/// artist, then play/pause and skip. Drawn over the video surface, which stands in for artwork.
private struct MiniPlayerControls: View {
    let leadingInset: CGFloat
    let cornerRadius: CGFloat

    @EnvironmentObject private var player: PlayerManager

    var body: some View {
        HStack(spacing: 10) {
            // The video surface shows through here.
            Color.clear
                .frame(width: leadingInset - 10)
                .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 1) {
                Text(player.currentVideo?.title ?? "")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(player.currentVideo?.channelTitle ?? "")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
            .onTapGesture { player.expand() }

            Spacer(minLength: 4)

            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 38, height: 44)
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
                    .frame(width: 38, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close player")
        }
        .padding(.trailing, 10)
        .overlay(alignment: .bottom) { progressLine }
    }

    /// A hairline of progress, clipped to the bar so it follows the rounded corners.
    private var progressLine: some View {
        GeometryReader { proxy in
            let fraction = player.duration > 0 ? player.currentTime / player.duration : 0
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: proxy.size.width * fraction)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .frame(height: 2.5)
        .padding(.horizontal, 14)
        .padding(.bottom, 3)
        .allowsHitTesting(false)
    }
}
