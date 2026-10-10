import SwiftUI

/// The foot of a list that goes on. It asks for the next page as it scrolls into view, and
/// offers to try again when a page doesn't come — a spinner that never stops is worse than a
/// list that admits where it ends.
struct LoadMoreFooter: View {
    /// Why the last page failed, if it did.
    let error: String?
    /// Changes whenever a page lands. A footer still on screen after one — a tall window, a
    /// short page — asks again rather than waiting to be scrolled away and back.
    let trigger: Int
    let loadMore: @MainActor @Sendable () async -> Void

    var body: some View {
        Group {
            if let error {
                VStack(spacing: 8) {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Try Again") {
                        Task { await loadMore() }
                    }
                }
            } else {
                ProgressView()
                    .task(id: trigger) {
                        // Detached from the footer's own task: scrolling it away mid-page cancels
                        // that, and a cancelled request would come back as an error to retry.
                        await Task { await loadMore() }.value
                    }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}
