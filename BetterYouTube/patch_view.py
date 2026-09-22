import re

with open("BetterYouTube/Views/Player/PlayerDetailsView.swift", "r") as f:
    text = f.read()

replacement = """                Button {
                    Haptics.light()
                    Task { await viewModel.toggleCommentLike(comment) }
                } label: {
                    Label(
                        comment.likeCount > 0 ? CountFormatter.abbreviated(comment.likeCount) : "Like",
                        systemImage: comment.isLiked ? "hand.thumbsup.fill" : "hand.thumbsup"
                    )
                }
                .accessibilityHint("Likes or unlikes this comment")"""

text = re.sub(
    r'                Button \{\s*if let url = youTubeURL\(for: comment\.id\) \{ openURL\(url\) \}\s*\} label: \{\s*Label\(\s*comment\.likeCount > 0 \? CountFormatter\.abbreviated\(comment\.likeCount\) : "Like",\s*systemImage: "hand\.thumbsup"\s*\)\s*\}\s*\.accessibilityHint\("Opens this comment on YouTube to like it"\)',
    replacement,
    text
)

with open("BetterYouTube/Views/Player/PlayerDetailsView.swift", "w") as f:
    f.write(text)

