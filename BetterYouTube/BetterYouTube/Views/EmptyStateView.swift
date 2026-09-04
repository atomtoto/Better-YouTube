import SwiftUI

/// Lightweight stand-in for `ContentUnavailableView` so the app can target iOS 16.
struct EmptyStateView: View {
    let title: String
    var systemImage: String = "exclamationmark.triangle"
    var message: String?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
