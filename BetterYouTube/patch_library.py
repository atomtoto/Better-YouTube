import re

with open("BetterYouTube/Views/LibraryView.swift", "r") as f:
    text = f.read()

text = text.replace(
    "SubscriptionsView(channels: viewModel.subscriptions)",
    "SubscriptionsView(channels: viewModel.subscriptions, onRefresh: reload)"
)

text = text.replace(
    """VideoListView(title: "Liked Videos", videos: viewModel.likedVideos)""",
    """VideoListView(title: "Liked Videos", videos: viewModel.likedVideos, onRefresh: reload)"""
)

text = text.replace(
    "PlaylistsView(playlists: viewModel.playlists)",
    "PlaylistsView(playlists: viewModel.playlists, onRefresh: reload)"
)

text = text.replace(
    """                        onDelete: { offsets in
                            Task { await watchLater.remove(atOffsets: offsets) }
                        }""",
    """                        onDelete: { offsets in
                            Task { await watchLater.remove(atOffsets: offsets) }
                        },
                        onRefresh: reload"""
)

with open("BetterYouTube/Views/LibraryView.swift", "w") as f:
    f.write(text)

