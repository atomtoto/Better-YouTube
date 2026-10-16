import SwiftUI

/// The video's chapters under its description, the way the comments have their card: the chapter
/// playing now, and a tap opens them all. Nothing at all for a video without chapters.
///
/// Observes the position on its own, so the rest of the details don't redraw with it.
struct ChaptersCard: View {
    @ObservedObject var options: PlaybackOptions
    @ObservedObject var progress: PlaybackProgress
    let onOpen: () -> Void

    var body: some View {
        if !options.chapters.isEmpty {
            let current = options.chapter(at: progress.currentTime) ?? options.chapters[0]
            let index = options.chapters.firstIndex(of: current) ?? 0
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Chapters")
                            .font(.title3.bold())
                        Spacer()
                        Text("\(index + 1) of \(options.chapters.count)")
                            .font(.footnote)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    ChapterRow(chapter: current, number: index + 1, isCurrent: false)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .cardBackground()
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens all chapters")
        }
    }
}

/// Every chapter, the one playing marked, a tap jumping to it. Opens on the chapter playing.
struct ChapterList: View {
    @ObservedObject var options: PlaybackOptions
    @ObservedObject var progress: PlaybackProgress
    let isPlaying: Bool
    let onSelect: (VideoChapter) -> Void

    var body: some View {
        let current = options.chapter(at: progress.currentTime)
        ScrollViewReader { proxy in
            List(Array(options.chapters.enumerated()), id: \.element.id) { index, chapter in
                Button {
                    onSelect(chapter)
                } label: {
                    ChapterRow(chapter: chapter, number: index + 1,
                               isCurrent: chapter == current, isPlaying: isPlaying)
                }
                .id(chapter.id)
            }
            .listStyle(.plain)
            .onAppear {
                if let current { proxy.scrollTo(current.id, anchor: .center) }
            }
        }
    }
}

/// One chapter: YouTube's picture of it with where it starts, and its title.
struct ChapterRow: View {
    let chapter: VideoChapter
    let number: Int
    let isCurrent: Bool
    var isPlaying = false

    private var title: String {
        chapter.title.isEmpty ? String(localized: "Chapter \(number)") : chapter.title
    }

    var body: some View {
        HStack(spacing: 12) {
            if let thumbnail = chapter.thumbnail {
                ArtworkView(url: thumbnail, duration: PlaybackTimeFormatter.string(chapter.start))
                    .frame(width: 112, height: 63)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                // The picture carries the time already; without one, it goes here.
                if chapter.thumbnail == nil {
                    Text(PlaybackTimeFormatter.string(chapter.start))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            if isCurrent {
                Image(systemName: "waveform")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tint)
                    .symbolEffect(.variableColor.iterative, isActive: isPlaying)
                    .accessibilityLabel("Playing Now")
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}
