import SwiftUI

/// The expanded player. The video is the shared surface drawn through the gap in this view.
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
    @Binding var scrollOffset: CGFloat

    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var downloads: DownloadStore
    @EnvironmentObject private var downloadManager: DownloadManager
    @State private var showsPlaylistPicker = false

    var body: some View {
        Group {
            #if os(macOS)
            ScrollView {
                content
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                max(0, geometry.contentOffset.y + geometry.contentInsets.top)
            } action: { _, current in
                scrollOffset = current
            }
            #else
            content
            #endif
        }
        .sheet(isPresented: $showsPlaylistPicker) {
            if let video = player.currentVideo {
                PlaylistPickerView(video: video)
            }
        }
    }

    private var content: some View {
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

            #if os(iOS)
            Spacer(minLength: 0)
            #endif
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// The same pull-down the video surface answers to, so the gesture behaves identically
    /// wherever it starts.
    private var collapseDrag: PlayerCollapseDrag {
        PlayerCollapseDrag(state: $drag, travel: travel) { player.collapse() }
    }

    private var backSymbol: String {
        #if os(macOS)
        "arrow.left"
        #else
        "chevron.down"
        #endif
    }

    private var menuSymbol: String {
        #if os(macOS)
        "ellipsis.rectangle.fill"
        #else
        "ellipsis"
        #endif
    }

    private var header: some View {
        HStack(spacing: 4) {
            Button {
                player.collapse()
            } label: {
                Image(systemName: backSymbol)
                    .font(.headline)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            #if os(macOS)
            .buttonStyle(.plain)
            .accessibilityLabel("Back to browsing")
            #else
            .accessibilityLabel("Minimize player")
            #endif

            Spacer()

            #if os(iOS)
            Capsule()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 36, height: 5)

            Spacer()
            #endif

            Menu {
                PlayerActions(
                    player: player,
                    downloads: downloads,
                    downloadManager: downloadManager,
                    onAddToPlaylist: { showsPlaylistPicker = true }
                )
            } label: {
                Image(systemName: menuSymbol)
                    .font(.headline)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("More")
            #if os(macOS)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            #endif
        }
        .padding(.horizontal, 6)
        .foregroundStyle(.primary)
    }
}
