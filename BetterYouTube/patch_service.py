import re

with open("BetterYouTube/YouTubeAPIService.swift", "r") as f:
    text = f.read()

replacement = """    /// Likes a comment on the account, or clears the rating with `.none`.
    func rateComment(commentId: String, rating: VideoRating) async throws {
        try await sendDiscardingResponse(
            "POST",
            path: "comments/rate",
            query: ["id": commentId, "rating": rating.rawValue]
        )
    }

    func comments(videoId: String, maxResults: Int = 20) async throws -> [VideoComment] {"""

text = text.replace("    func comments(videoId: String, maxResults: Int = 20) async throws -> [VideoComment] {", replacement)

with open("BetterYouTube/YouTubeAPIService.swift", "w") as f:
    f.write(text)

