import SwiftUI

/// The full-screen player. The video itself is the shared surface drawn underneath this view, so
/// everything here sits either above it (the header) or below it (the details).
///
/// The header deliberately sits *above* the video rather than overlaying it: the embed draws
/// YouTube's own transport controls, and an overlay would swallow the taps meant for them.
struct ExpandedPlayerView: View {
    let videoHeight: CGFloat
    let headerHeight: CGFloat
    @Binding var dragOffset: CGFloat

    @EnvironmentObject private var player: PlayerManager

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(height: headerHeight)
                .contentShape(Rectangle())
                .gesture(dragGesture)

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

    /// Pull the header down to shrink back to the mini player.
    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                dragOffset = max(0, value.translation.height)
            }
            .onEnded { value in
                withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
                    dragOffset = 0
                }
                if value.translation.height > 100 {
                    player.collapse()
                }
            }
    }
}
