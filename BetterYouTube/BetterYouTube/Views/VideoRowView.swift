import SwiftUI

struct VideoRowView: View {
    let video: Video

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ThumbnailView(url: video.thumbnailURL, duration: video.duration)
                .frame(width: 160, height: 90)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(video.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)

                Text(video.channelTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(metadataLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var metadataLine: String {
        var parts: [String] = []
        if let views = video.viewCount {
            parts.append("\(CountFormatter.abbreviated(views)) views")
        }
        if let date = video.publishedAt {
            parts.append(RelativeDateFormatter.string(from: date))
        }
        return parts.joined(separator: " • ")
    }
}

struct ThumbnailView: View {
    let url: URL?
    var duration: String?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                case .failure:
                    placeholder
                case .empty:
                    placeholder.overlay(ProgressView())
                @unknown default:
                    placeholder
                }
            }

            if let duration, !duration.isEmpty {
                Text(duration)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.white)
                    .padding(4)
            }
        }
        .clipped()
    }

    private var placeholder: some View {
        Rectangle().fill(Color.gray.opacity(0.25))
    }
}

#Preview {
    VideoRowView(video: Video(
        id: "dQw4w9WgXcQ",
        title: "Example video with a fairly long title to test wrapping",
        channelId: "UC123",
        channelTitle: "Example Channel",
        description: "",
        thumbnailURL: nil,
        publishedAt: Date(),
        viewCount: 1_234_567,
        likeCount: 12_345,
        duration: "3:45"
    ))
    .padding()
}
