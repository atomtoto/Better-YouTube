import SwiftUI

/// Shared design tokens so every screen reads as one system.
enum Theme {
    enum Radius {
        static let thumbnail: CGFloat = 10
        static let card: CGFloat = 14
        static let hero: CGFloat = 18
    }

    enum Spacing {
        static let section: CGFloat = 28
        static let card: CGFloat = 14
        static let gutter: CGFloat = 16
    }

    enum Size {
        static let carouselCard: CGFloat = 260
        static let compactThumbnail: CGFloat = 132
    }
}

extension View {
    /// Soft elevation used on artwork, matching the depth Apple Music gives its cards.
    func artworkShadow() -> some View {
        shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 5)
    }

    func cardBackground(cornerRadius: CGFloat = Theme.Radius.card) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
    }
}

/// 16:9 artwork with a rounded, continuous corner and an optional duration badge.
struct ArtworkView: View {
    let url: URL?
    var duration: String?
    var cornerRadius: CGFloat = Theme.Radius.thumbnail

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                case .empty:
                    placeholder.overlay(ProgressView().controlSize(.small))
                default:
                    placeholder.overlay(
                        Image(systemName: "play.rectangle")
                            .font(.title2)
                            .foregroundStyle(.tertiary)
                    )
                }
            }

            if let duration, !duration.isEmpty {
                Text(duration)
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.72), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(6)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }

    private var placeholder: some View {
        Rectangle().fill(Color(uiColor: .tertiarySystemFill))
    }
}

/// Circular channel avatar with a graceful fallback.
struct AvatarView: View {
    let url: URL?
    var size: CGFloat = 44

    var body: some View {
        AsyncImage(url: url) { phase in
            if case .success(let image) = phase {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Circle().fill(Color(uiColor: .tertiarySystemFill))
                    Image(systemName: "person.fill")
                        .font(.system(size: size * 0.45))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

/// Section title with an optional "See All" affordance, as used across Apple's apps.
struct SectionHeader<Destination: View>: View {
    private let title: String
    private let subtitle: String?
    private let showsSeeAll: Bool
    private let destination: () -> Destination

    init(title: String, subtitle: String? = nil, @ViewBuilder destination: @escaping () -> Destination) {
        self.title = title
        self.subtitle = subtitle
        self.showsSeeAll = true
        self.destination = destination
    }

    fileprivate init(title: String, subtitle: String?, showsSeeAll: Bool, destination: @escaping () -> Destination) {
        self.title = title
        self.subtitle = subtitle
        self.showsSeeAll = showsSeeAll
        self.destination = destination
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                if let subtitle {
                    Text(subtitle.uppercased())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(title)
                    .font(.title2.bold())
            }
            Spacer(minLength: 12)
            if showsSeeAll {
                NavigationLink(destination: destination) {
                    Text("See All")
                        .font(.subheadline.weight(.semibold))
                }
            }
        }
    }
}

extension SectionHeader where Destination == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle, showsSeeAll: false) { EmptyView() }
    }
}
