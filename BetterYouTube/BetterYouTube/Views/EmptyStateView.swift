import SwiftUI

/// Lightweight stand-in for `ContentUnavailableView` so the app can target iOS 16.
struct EmptyStateView: View {
    let title: String
    var systemImage: String = "exclamationmark.triangle"
    var message: String?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 4)

            Text(title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)

            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    EmptyStateView(
        title: "No Results",
        systemImage: "magnifyingglass",
        message: "Try a different search term."
    )
}
