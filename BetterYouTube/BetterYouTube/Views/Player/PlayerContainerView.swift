import SwiftUI

/// The player that lives above every screen. It morphs between a mini bar docked over the tab bar
/// and a full-screen player, moving one shared video surface between the two positions rather than
/// rebuilding it — so the video never restarts.
struct PlayerContainerView: View {
    @EnvironmentObject private var player: PlayerManager
    @State private var dragOffset: CGFloat = 0

    private let miniBarHeight: CGFloat = 62
    private let tabBarHeight: CGFloat = 49
    private let miniVideoWidth: CGFloat = 104

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let expanded = player.isExpanded

            // Where the video sits in each state; the surface animates between the two.
            let videoWidth = expanded ? size.width : miniVideoWidth
            let videoHeight = expanded ? (size.width * 9 / 16) : miniBarHeight - 12
            let miniBarCenterY = size.height - tabBarHeight - miniBarHeight / 2
            let videoCenterX = expanded ? size.width / 2 : (miniVideoWidth / 2) + 14
            let videoCenterY = expanded ? videoHeight / 2 : miniBarCenterY

            ZStack(alignment: .topLeading) {
                // 1. Backdrops — drawn under the video surface.
                Color(uiColor: .systemBackground)
                    .opacity(expanded ? 1 : 0)
                    .ignoresSafeArea()
                    .allowsHitTesting(expanded)

                if !expanded {
                    MiniPlayerBackground()
                        .frame(width: size.width - 16, height: miniBarHeight)
                        .position(x: size.width / 2, y: miniBarCenterY)
                        .onTapGesture { player.expand() }
                }

                // 2. The one and only video surface.
                PlayerSurface(webView: player.webView)
                    .frame(width: videoWidth, height: videoHeight)
                    .clipShape(RoundedRectangle(cornerRadius: expanded ? 0 : 8, style: .continuous))
                    .position(x: videoCenterX, y: videoCenterY)
                    .allowsHitTesting(false)

                // 3. Chrome — drawn over the video.
                if expanded {
                    ExpandedPlayerView(videoHeight: videoHeight)
                        .frame(width: size.width, height: size.height)
                } else {
                    MiniPlayerControls(leadingInset: miniVideoWidth + 20)
                        .frame(width: size.width - 16, height: miniBarHeight)
                        .position(x: size.width / 2, y: miniBarCenterY)
                }
            }
            .offset(y: dragOffset)
            .gesture(dragGesture(expanded: expanded))
        }
        .opacity(player.currentVideo == nil ? 0 : 1)
        .allowsHitTesting(player.currentVideo != nil)
    }

    /// Drag down to shrink the full player, drag up on the mini bar to bring it back.
    private func dragGesture(expanded: Bool) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if expanded {
                    dragOffset = max(0, value.translation.height)
                } else {
                    dragOffset = min(0, value.translation.height) / 4
                }
            }
            .onEnded { value in
                let translation = value.translation.height
                withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
                    dragOffset = 0
                }
                if expanded, translation > 120 {
                    player.collapse()
                } else if !expanded, translation < -40 {
                    player.expand()
                }
            }
    }
}

/// The material slab behind the mini player, drawn under the video surface.
private struct MiniPlayerBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(.regularMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
    }
}

/// Labels and transport buttons of the mini player, drawn over the video surface.
private struct MiniPlayerControls: View {
    let leadingInset: CGFloat
    @EnvironmentObject private var player: PlayerManager

    var body: some View {
        HStack(spacing: 12) {
            Color.clear.frame(width: leadingInset - 12)

            VStack(alignment: .leading, spacing: 2) {
                Text(player.currentVideo?.title ?? "")
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                Text(player.currentVideo?.channelTitle ?? "")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
            .onTapGesture { player.expand() }

            Spacer(minLength: 0)

            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 40, height: 40)
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
                    .frame(width: 36, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close player")
        }
        .padding(.trailing, 6)
        .overlay(alignment: .bottom) {
            // A hairline of progress, the way the YouTube mini player shows it.
            GeometryReader { proxy in
                let fraction = player.duration > 0 ? player.currentTime / player.duration : 0
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: proxy.size.width * fraction, height: 2)
            }
            .frame(height: 2)
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
        }
    }
}
