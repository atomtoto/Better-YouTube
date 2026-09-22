import re

with open("BetterYouTube/ViewModels/VideoDetailViewModel.swift", "r") as f:
    text = f.read()

replacement = """    // MARK: - Comment actions

    func toggleCommentLike(_ comment: VideoComment) async {
        guard let index = comments.firstIndex(where: { $0.id == comment.id }) else { return }
        
        let isLiked = comments[index].isLiked
        let newRating: VideoRating = isLiked ? .none : .like
        
        // Optimistic update
        comments[index].isLiked = !isLiked
        comments[index].likeCount += isLiked ? -1 : 1
        
        do {
            try await service.rateComment(commentId: comment.id, rating: newRating)
        } catch {
            // Revert on failure
            comments[index].isLiked = isLiked
            comments[index].likeCount += isLiked ? 1 : -1
            commentActionError = error.localizedDescription
        }
    }

    func addComment(_ rawText: String) async -> Bool {"""

text = text.replace("    func addComment(_ rawText: String) async -> Bool {", replacement)

with open("BetterYouTube/ViewModels/VideoDetailViewModel.swift", "w") as f:
    f.write(text)

