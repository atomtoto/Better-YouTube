import Foundation
import CoreGraphics

/// The right size of a YouTube picture for the space it is drawn in.
///
/// YouTube keeps every video frame and channel avatar in several sizes, and the API hands this
/// app the largest: a 1280-pixel frame, about 110 KB, even for a row thumbnail 120 points wide, and
/// an 800-pixel avatar for a 36-point circle. These ask for the smallest size that is still sharp
/// where it is shown — a sixth of the data for a small thumbnail, which on a phone network and in
/// a long list adds up. Only ever smaller than the URL given: a picture is never asked for in a
/// size YouTube may not have.
enum ImageSizing {
    /// The fixed sizes every video has on `i.ytimg.com`, by width in pixels. `sddefault` and
    /// `maxresdefault` are left out on purpose: older videos lack them.
    private static let videoSizes: [(name: String, width: CGFloat)] = [
        ("mqdefault", 320),
        ("hqdefault", 480),
    ]

    /// Every name YouTube gives a video's frame, by width. A URL ending in another name is left
    /// alone.
    private static let knownVideoWidths: [String: CGFloat] = [
        "default": 120, "mqdefault": 320, "hqdefault": 480, "sddefault": 640,
        "hq720": 1280, "maxresdefault": 1280,
    ]

    /// A video's frame no wider than it needs to be for `pixelWidth`.
    ///
    /// `mqdefault` is 16:9; `hqdefault` is 4:3 with black bars above and below, which a 16:9 frame
    /// filled with it crops away exactly.
    static func video(_ url: URL?, pixelWidth: CGFloat) -> URL? {
        guard let url, pixelWidth > 0,
              let host = url.host(), host.hasSuffix("ytimg.com"),
              case let parts = url.pathComponents, parts.count == 4, parts[1] == "vi" || parts[1] == "vi_webp",
              case let name = (parts[3] as NSString).deletingPathExtension,
              let currentWidth = knownVideoWidths[name],
              let size = videoSizes.first(where: { $0.width >= pixelWidth }),
              size.width < currentWidth
        else { return url }
        // Without the query: the larger names come signed for themselves, the fixed ones need none.
        return URL(string: "https://i.ytimg.com/vi/\(parts[2])/\(size.name).jpg")
    }

    /// A channel avatar no larger than `pixelSize` square. Avatars are served at any size,
    /// named by an `=s<pixels>` option at the end of the URL.
    static func avatar(_ url: URL?, pixelSize: CGFloat) -> URL? {
        guard let url, pixelSize > 0,
              let host = url.host(), host.hasPrefix("yt3.") || host.hasSuffix("googleusercontent.com")
        else { return url }
        let string = url.absoluteString
        guard let range = string.range(of: #"=s\d+"#, options: .regularExpression),
              let current = Int(string[range].dropFirst(2))
        else { return url }
        let wanted = Int(pixelSize.rounded(.up))
        guard wanted < current else { return url }
        return URL(string: string.replacingCharacters(in: range, with: "=s\(wanted)"))
    }
}
