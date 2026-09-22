import re

with open("BetterYouTube/Views/VideoListView.swift", "r") as f:
    text = f.read()

extension_code = """

private extension View {
    @ViewBuilder
    func optionalRefreshable(action: (@Sendable () async -> Void)?) -> some View {
        if let action {
            self.refreshable(action: action)
        } else {
            self
        }
    }
}
"""

if "func optionalRefreshable" not in text:
    text += extension_code

with open("BetterYouTube/Views/VideoListView.swift", "w") as f:
    f.write(text)

