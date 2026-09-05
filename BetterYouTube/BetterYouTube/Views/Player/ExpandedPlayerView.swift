import SwiftUI

/// The full-screen player: video pinned at the top with custom transport controls, details and
/// comments scrolling underneath — the layout both the YouTube app and Apple Music use.
struct ExpandedPlayerView: View {
    let videoHeight: CGFloat

    @EnvironmentObject private var player: PlayerManager

    var body: some View {
        VStack(spacing: 0) {
            // Sits exactly over the shared video surface drawn beneath this view.
            PlayerControlsOverlay()
                .frame(height: videoHeight)

            if let video = player.currentVideo {
                PlayerDetailsView(video: video)
                    .id(video.id)
            }
        }
    }
}

/// Tap-to-reveal transport controls drawn on top of the video.
private struct PlayerControlsOverlay: View {
    @EnvironmentObject private var player: PlayerManager

    var body: some View {
        ZStack {
            Color.black.opacity(player.areControlsVisible ? 0.35 : 0.001)
                .contentShape(Rectangle())
                .onTapGesture { player.toggleControls() }

            if player.areControlsVisible {
                controls
                    .transition(.opacity)
            }

            if player.isBuffering {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }
        }
        .clipped()
    }

    private var controls: some View {
        VStack {
            HStack {
                Button {
                    player.collapse()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Minimize player")

                Spacer()

                Button {
                    player.close()
                } label: {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Close player")
            }

            Spacer()

            HStack(spacing: 44) {
                Button {
                    player.skip(by: -10)
                } label: {
                    Image(systemName: "gobackward.10")
                        .font(.title2)
                        .foregroundStyle(.white)
                }
                .accessibilityLabel("Back 10 seconds")

                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.white)
                        .frame(width: 60, height: 60)
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

                Button {
                    player.skip(by: 10)
                } label: {
                    Image(systemName: "goforward.10")
                        .font(.title2)
                        .foregroundStyle(.white)
                }
                .accessibilityLabel("Forward 10 seconds")
            }

            Spacer()

            scrubber
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
        }
        .buttonStyle(.plain)
    }

    private var scrubber: some View {
        VStack(spacing: 2) {
            Slider(
                value: Binding(
                    get: { player.currentTime },
                    set: { player.scrub(to: $0) }
                ),
                in: 0...max(player.duration, 1),
                onEditingChanged: { isEditing in
                    player.isScrubbing = isEditing
                    if !isEditing {
                        player.seek(to: player.currentTime)
                    }
                    player.showControls()
                }
            )
            .tint(.red)

            HStack {
                Text(TimeFormatter.string(player.currentTime))
                Spacer()
                Text(TimeFormatter.string(player.duration))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white.opacity(0.85))
        }
    }
}

enum TimeFormatter {
    static func string(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}
