import SwiftUI

/// The full-screen player. The video itself is the shared surface drawn underneath this view, so
/// everything here sits either above it (the header) or below it (the details).
///
/// The header deliberately sits *above* the video rather than overlaying it: the embed draws
/// YouTube's own transport controls, and an overlay would swallow the taps meant for them.
///
/// Its layout is fixed to the full-screen metrics even while the player is being pulled down —
/// the container fades and moves it as one piece, so none of this re-flows mid-drag.
struct ExpandedPlayerView: View {
    let videoHeight: CGFloat
    let headerHeight: CGFloat
    /// How far the video travels to reach the docked bar.
    let travel: CGFloat
    @Binding var drag: PlayerDragState

    @EnvironmentObject private var player: PlayerManager

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(height: headerHeight)
                .contentShape(Rectangle())
                .gesture(collapseDrag.gesture)

            // The video shows through this gap; touches must reach it.
            Color.clear
                .frame(height: videoHeight)
                .allowsHitTesting(false)

            if let video = player.currentVideo {
                PlayerDetailsView(video: video)
                    .id(video.id)
            }

            Spacer(minLength: 0)
        }
    }

    /// The same pull-down the video surface answers to, so the gesture behaves identically
    /// wherever it starts.
    private var collapseDrag: PlayerCollapseDrag {
        PlayerCollapseDrag(state: $drag, travel: travel) { player.collapse() }
    }

    private var header: some View {
        HStack(spacing: 4) {
            Button {
                player.collapse()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.headline)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Minimize player")

            Spacer()

            Capsule()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 36, height: 5)

            Spacer()

            Menu {
                PlayerActions(player: player)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.headline)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("More")
        }
        .padding(.horizontal, 6)
        .foregroundStyle(.primary)
    }
}
