import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The expanded player. The video is the shared surface drawn through the gap in this view.
///
/// On iOS the header sits above the video, clear of its playback controls. On macOS its actions
/// live in the window toolbar instead.
///
/// Its layout is fixed to the full-screen metrics even while the player is being pulled down —
/// the container fades and moves it as one piece, so none of this re-flows mid-drag.
struct ExpandedPlayerView: View {
    let videoWidth: CGFloat
    let videoHeight: CGFloat
    /// Set on a wide iPad, where the details stand in two columns — see `PlayerDetailsView`.
    var sideBySide: PlayerDetailsView.SideBySide? = nil
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
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button("Back to browsing", systemImage: "arrow.left") {
                        player.collapse()
                    }
                    .help("Back to browsing")
                    .buttonStyle(.borderedProminent)
                    .tint(.black)
                }
            }
            .toolbarBackground(.black, for: .windowToolbar)
            .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
            .toolbarColorScheme(.dark, for: .windowToolbar)
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
            #if os(iOS)
            header
                .frame(height: headerHeight)
                .contentShape(Rectangle())
                .gesture(collapseDrag.gesture)
            #endif

            // The video shows through this gap; touches must reach it. Side by side, the
            // details' first column leaves the gap itself.
            if sideBySide == nil {
                Color.clear
                    .frame(height: videoHeight)
                    .allowsHitTesting(false)
            }

            // One place for both layouts, so turning the iPad keeps the same details — and
            // what they have loaded — rather than starting a new set.
            if let video = player.currentVideo {
                PlayerDetailsView(video: video, sideBySide: sideBySide)
                    .id(video.id)
            }

            #if os(iOS)
            Spacer(minLength: 0)
            #endif
        }
        #if os(macOS)
        .frame(width: videoWidth, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .top)
        #else
        .frame(maxWidth: .infinity, alignment: .topLeading)
        #endif
    }

    private var actionsMenu: some View {
        Menu {
            PlayerActions(
                player: player,
                downloads: downloads,
                downloadManager: downloadManager,
                onAddToPlaylist: { showsPlaylistPicker = true }
            )
        } label: {
            #if os(macOS)
            Label("More", systemImage: "ellipsis")
            #else
            Image(systemName: "ellipsis")
                .font(.headline)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            #endif
        }
        .accessibilityLabel("More")
    }

    #if os(iOS)
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

            actionsMenu
        }
        .padding(.horizontal, 6)
        .foregroundStyle(.primary)
    }
    #endif
}

#if os(macOS)
/// The split view's detail column owns the trailing toolbar section. Actions declared on the
/// player overlay belong to the window's leading section, before the page's own controls.
struct MacPlayerActionsToolbar: ViewModifier {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var downloads: DownloadStore
    @EnvironmentObject private var downloadManager: DownloadManager
    @State private var showsPlaylistPicker = false
    @State private var browsingColorScheme: ColorScheme = NSApplication.shared.effectiveAppearance
        .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light

    func body(content: Content) -> some View {
        content
            .toolbar {
                if player.isExpanded, !player.isFullScreen {
                    ToolbarItem(placement: .automatic) {
                        Menu {
                            PlayerActions(
                                player: player,
                                downloads: downloads,
                                downloadManager: downloadManager,
                                onAddToPlaylist: { showsPlaylistPicker = true }
                            )
                        } label: {
                            Label("More", systemImage: "ellipsis")
                        }
                        .help("More")
                        .menuStyle(.button)
                        .buttonStyle(.borderedProminent)
                        .tint(.black)
                    }
                }
            }
            .toolbarColorScheme(player.isExpanded ? .dark : nil, for: .windowToolbar)
            // macOS keeps the previous window appearance when this preference becomes nil.
            // Restore the app's appearance explicitly and follow system appearance changes.
            .preferredColorScheme(player.isExpanded && !player.isFullScreen ? .dark : browsingColorScheme)
            .onReceive(NSApplication.shared.publisher(for: \.effectiveAppearance)) { appearance in
                browsingColorScheme = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
            }
            .sheet(isPresented: $showsPlaylistPicker) {
                if let video = player.currentVideo {
                    PlaylistPickerView(video: video)
                }
            }
    }
}
#endif
