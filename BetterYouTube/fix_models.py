import re

with open("BetterYouTube/Models.swift", "r") as f:
    text = f.read()

# Make likeCount mutable and add isLiked to VideoComment
text = re.sub(
    r'let likeCount: Int\n    let publishedAt: Date\?',
    r'var likeCount: Int\n    let publishedAt: Date?\n    var isLiked: Bool = false',
    text
)

# Add viewerRating to YTCommentSnippet
text = re.sub(
    r'let likeCount: Int\n    let publishedAt: String\?',
    r'let likeCount: Int\n    let publishedAt: String?\n    let viewerRating: String?',
    text
)

# Initialize isLiked in VideoComment
text = re.sub(
    r'self.likeCount = snippet.likeCount\n        self.publishedAt',
    r'self.likeCount = snippet.likeCount\n        self.isLiked = snippet.viewerRating == "like"\n        self.publishedAt',
    text
)

with open("BetterYouTube/Models.swift", "w") as f:
    f.write(text)

