import Foundation

/// Where downloads come from, and the rules the app downloads under.
///
/// There is deliberately no service here by default. The app can play a video through YouTube's
/// own embed, but it has no way to get at the media file behind one — that takes a resolver, and
/// which resolver to trust is not a decision an app should make on its owner's behalf. So the
/// endpoint is yours: a small service you run, which the app treats as an ordinary HTTP API. With
/// the field empty, downloading is simply off, and the app says so rather than failing later.
///
/// Running your own is also the only version that stays working. A resolver is a moving target;
/// one you control can be updated the day it breaks, where a stranger's public instance goes dark,
/// rate-limits you, or quietly starts logging what you watch.
@MainActor
final class DownloadSettings: ObservableObject {
    static let shared = DownloadSettings()

    /// The download service. Two shapes, told apart by whether it carries a placeholder — see
    /// `DownloadResolver`.
    @Published var endpoint: String {
        didSet { UserDefaults.standard.set(endpoint, forKey: Self.endpointKey) }
    }

    /// Sent as `Authorization: Bearer …` when set, for a service that isn't open to the internet.
    @Published var token: String {
        didSet { UserDefaults.standard.set(token, forKey: Self.tokenKey) }
    }

    @Published var quality: DownloadQuality {
        didSet { UserDefaults.standard.set(quality.rawValue, forKey: Self.qualityKey) }
    }

    /// Video is the one thing in this app worth a mobile data plan's attention, so this starts on.
    @Published var wifiOnly: Bool {
        didSet { UserDefaults.standard.set(wifiOnly, forKey: Self.wifiOnlyKey) }
    }

    /// A ceiling on the Downloads folder, in gigabytes. Zero means no ceiling.
    @Published var storageLimitGB: Int {
        didSet { UserDefaults.standard.set(storageLimitGB, forKey: Self.storageLimitKey) }
    }

    private static let endpointKey = "download_endpoint"
    private static let tokenKey = "download_token"
    private static let qualityKey = "download_quality"
    private static let wifiOnlyKey = "download_wifi_only"
    private static let storageLimitKey = "download_storage_limit_gb"

    private init() {
        let defaults = UserDefaults.standard
        endpoint = defaults.string(forKey: Self.endpointKey) ?? ""
        token = defaults.string(forKey: Self.tokenKey) ?? ""
        quality = defaults.string(forKey: Self.qualityKey)
            .flatMap(DownloadQuality.init(rawValue:)) ?? .medium
        wifiOnly = defaults.object(forKey: Self.wifiOnlyKey) as? Bool ?? true
        storageLimitGB = defaults.object(forKey: Self.storageLimitKey) as? Int ?? 8
    }

    var trimmedEndpoint: String {
        endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isConfigured: Bool { endpointURL != nil }

    /// The endpoint as a URL, if it is one at all. Only `http` and `https` — a `file://` typed in
    /// here would otherwise have the app reading its own container as if it were a service.
    var endpointURL: URL? {
        let text = trimmedEndpoint
        guard !text.isEmpty, let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return url
    }

    /// True when the endpoint carries a placeholder, which is what puts it in template mode.
    var usesTemplate: Bool { DownloadResolver.placeholders.contains { trimmedEndpoint.contains($0) } }

    var storageLimitBytes: Int64? {
        guard storageLimitGB > 0 else { return nil }
        return Int64(storageLimitGB) * 1_000_000_000
    }

    var snapshot: DownloadSourceSnapshot {
        DownloadSourceSnapshot(
            endpoint: trimmedEndpoint,
            token: token.trimmingCharacters(in: .whitespacesAndNewlines),
            wifiOnly: wifiOnly
        )
    }
}

/// The settings a resolve needs, lifted off the main actor so the resolver can be asked from
/// anywhere.
struct DownloadSourceSnapshot: Sendable, Equatable {
    let endpoint: String
    let token: String
    let wifiOnly: Bool
}

/// A media file the service pointed at.
struct ResolvedMedia: Sendable, Equatable {
    let url: URL
    /// What the service said it weighs, when it says.
    let byteCount: Int64?
}

enum DownloadError: LocalizedError, Equatable {
    case notConfigured
    case badEndpoint
    /// The service answered, and said no.
    case service(String)
    /// The service answered, and the answer had no media URL in it.
    case noMedia
    case http(Int)
    case transport(String)
    /// The download would push the folder past the limit set in Settings.
    case overStorageLimit(String)
    case noSpace

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Set a download service in Settings first. The app has no way to reach a video's media file on its own."
        case .badEndpoint:
            return "That download service address isn't a valid http or https URL."
        case .service(let message):
            return message
        case .noMedia:
            return "The download service replied, but there was no media link in its answer."
        case .http(let code):
            return "The download service answered with status \(code)."
        case .transport(let message):
            return message
        case .overStorageLimit(let message):
            return message
        case .noSpace:
            return "There isn't enough free space on this device for that video."
        }
    }
}

/// Asks the configured service where a video's media file is.
///
/// Two shapes of service, told apart by the address alone, so the simplest possible one needs no
/// agreement about JSON at all:
///
/// **Template.** An address containing `{id}`, `{videoId}` or `{url}` is filled in and used as the
/// media URL directly — `https://box.local/yt/{id}.mp4` is a complete, working configuration for a
/// service that is a directory of files, or a script that streams one back.
///
/// **JSON.** Any other address is sent `POST` with
/// `{"url": …, "videoId": …, "quality": "720", "maxHeight": 720}` and answers with JSON carrying a
/// media link. Where that link sits is read generously — `url`, `downloadUrl`, `link`, a `urls`
/// array, or the first entry of `formats`/`streams`/`medias` — because every resolver spells it
/// differently and none of them is going to change for this app. A reply that says it failed,
/// through `status: "error"` or an `error` of its own, is reported in the service's own words.
actor DownloadResolver {
    static let shared = DownloadResolver()

    static let placeholders = ["{id}", "{videoId}", "{url}"]

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func resolve(
        video: Video,
        quality: DownloadQuality,
        source: DownloadSourceSnapshot
    ) async throws -> ResolvedMedia {
        let endpoint = source.endpoint
        guard !endpoint.isEmpty else { throw DownloadError.notConfigured }

        let watchURL = "https://www.youtube.com/watch?v=\(video.id)"

        if Self.placeholders.contains(where: { endpoint.contains($0) }) {
            return try Self.expandTemplate(endpoint, videoId: video.id, watchURL: watchURL)
        }
        return try await resolveJSON(
            endpoint: endpoint,
            videoId: video.id,
            watchURL: watchURL,
            quality: quality,
            source: source
        )
    }

    // MARK: - Template mode

    private static func expandTemplate(
        _ template: String,
        videoId: String,
        watchURL: String
    ) throws -> ResolvedMedia {
        let escapedWatch = watchURL
            .addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? watchURL

        let filled = template
            .replacingOccurrences(of: "{videoId}", with: videoId)
            .replacingOccurrences(of: "{id}", with: videoId)
            .replacingOccurrences(of: "{url}", with: escapedWatch)

        guard let url = URL(string: filled), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw DownloadError.badEndpoint
        }
        return ResolvedMedia(url: url, byteCount: nil)
    }

    // MARK: - JSON mode

    private func resolveJSON(
        endpoint: String,
        videoId: String,
        watchURL: String,
        quality: DownloadQuality,
        source: DownloadSourceSnapshot
    ) async throws -> ResolvedMedia {
        guard let url = URL(string: endpoint), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw DownloadError.badEndpoint
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        if !source.token.isEmpty {
            request.setValue("Bearer \(source.token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "url": watchURL,
            "videoId": videoId,
            "quality": String(quality.maxHeight),
            "maxHeight": quality.maxHeight,
            "audioOnly": false
        ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw DownloadError.transport(error.localizedDescription)
        }

        let object = try? JSONSerialization.jsonObject(with: data)
        let json = object as? [String: Any]

        // A service that explains itself is worth quoting, whatever its status code — plenty
        // answer 200 with `{"status": "error"}`.
        if let message = Self.failureMessage(in: json) {
            throw DownloadError.service(message)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw DownloadError.http(http.statusCode)
        }
        guard let json else { throw DownloadError.noMedia }
        guard let media = Self.mediaURL(in: json) else { throw DownloadError.noMedia }

        return ResolvedMedia(url: media, byteCount: Self.byteCount(in: json))
    }

    // MARK: - Reading the reply

    /// The keys a resolver is likely to put a media link under, best first.
    private static let urlKeys = [
        "url", "downloadUrl", "download_url", "downloadURL",
        "link", "media", "mediaUrl", "media_url", "file", "fileUrl", "src", "tunnel"
    ]

    /// Keys holding a list of candidates, which the first usable entry is taken from. The service
    /// has already been told the quality wanted, so its own ordering is trusted rather than
    /// second-guessed here.
    private static let listKeys = ["urls", "links", "formats", "streams", "medias", "results", "items"]

    private static func mediaURL(in json: [String: Any]) -> URL? {
        if let direct = firstURL(in: json) { return direct }

        for key in listKeys {
            guard let list = json[key] as? [Any] else { continue }
            for entry in list {
                if let text = entry as? String, let url = url(from: text) { return url }
                if let object = entry as? [String: Any], let url = firstURL(in: object) { return url }
            }
        }

        // One level down, for a reply that wraps everything in `data` or `result`.
        for key in ["data", "result", "response", "payload"] {
            if let nested = json[key] as? [String: Any], let url = mediaURL(in: nested) { return url }
        }
        return nil
    }

    private static func firstURL(in object: [String: Any]) -> URL? {
        for key in urlKeys {
            if let text = object[key] as? String, let url = url(from: text) { return url }
        }
        return nil
    }

    /// Only an absolute http(s) URL counts. A relative path or a `data:` blob would be handed
    /// straight to the downloader, which is a worse place to find out about it.
    private static func url(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host != nil else { return nil }
        return url
    }

    private static func byteCount(in json: [String: Any]) -> Int64? {
        for key in ["size", "filesize", "fileSize", "contentLength", "bytes"] {
            if let number = json[key] as? NSNumber { return number.int64Value }
            if let text = json[key] as? String, let value = Int64(text) { return value }
        }
        return nil
    }

    /// The service's own account of what went wrong, in whichever of the usual places it put it.
    private static func failureMessage(in json: [String: Any]?) -> String? {
        guard let json else { return nil }

        if let status = json["status"] as? String,
           ["error", "failed", "failure"].contains(status.lowercased()) {
            return text(fromError: json["error"]) ?? text(fromError: json["text"])
                ?? "The download service reported an error."
        }
        if let error = json["error"], let message = text(fromError: error) {
            return message
        }
        if let message = json["message"] as? String, json["success"] as? Bool == false {
            return message
        }
        return nil
    }

    /// An `error` comes back as a string, or as an object with the message somewhere inside.
    private static func text(fromError error: Any?) -> String? {
        if let text = error as? String, !text.isEmpty { return text }
        guard let object = error as? [String: Any] else { return nil }
        for key in ["message", "text", "description", "code"] {
            if let text = object[key] as? String, !text.isEmpty { return text }
        }
        return nil
    }
}

extension CharacterSet {
    /// A query *value*, which is stricter than `.urlQueryAllowed`: that one lets `&` and `=`
    /// through, and a watch URL pasted into a template would break the query it landed in.
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=?+/:")
        return set
    }()
}
