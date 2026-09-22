import re

with open("BetterYouTube/Views/VideoListView.swift", "r") as f:
    text = f.read()

# VideoListView
text = text.replace(
    "var onDelete: ((IndexSet) -> Void)?",
    "var onDelete: ((IndexSet) -> Void)?\n    var onRefresh: (@Sendable () async -> Void)? = nil"
)

# SubscriptionsView
text = text.replace(
    "let channels: [Channel]",
    "let channels: [Channel]\n    var onRefresh: (@Sendable () async -> Void)? = nil"
)

# PlaylistsView
text = text.replace(
    "let playlists: [Playlist]\n\n    private",
    "let playlists: [Playlist]\n    var onRefresh: (@Sendable () async -> Void)? = nil\n\n    private"
)

def replacer(match):
    return match.group(1) + "\n                .refreshable { if let onRefresh { await onRefresh() } }"

# Replace exactly the first 3 occurrences of utilizes .minimizesPlayerBarOnScroll()
text = re.sub(r'(\.minimizesPlayerBarOnScroll\(\))', replacer, text, count=3)

with open("BetterYouTube/Views/VideoListView.swift", "w") as f:
    f.write(text)

