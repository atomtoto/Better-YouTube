import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// A download service handed over as a link, so setting one up is a tap rather than typing a URL
/// into a phone.
///
/// `betteryoutube://downloads?endpoint=…&token=…`
///
/// This is what makes the feature reachable by people who aren't going to read a README: whoever
/// runs the resolver configures the app once, shares the link or its QR code, and everyone else
/// scans it. The service still belongs to them rather than to the app — the link only saves the
/// typing.
///
/// **A link is never applied on its own.** Opening one shows what it points at and waits to be
/// told to go ahead: a link is something anyone can send you, and pointing the app at a stranger's
/// server would mean every video you download goes through them.
struct DownloadConfigLink: Equatable, Identifiable {
    let endpoint: String
    let token: String

    /// Identity for `sheet(item:)`. Two links naming the same service are the same
    /// prompt, so re-opening one while its sheet is up doesn't stack a second.
    var id: String { endpoint }

    static let scheme = "betteryoutube"
    static let host = "downloads"

    init(endpoint: String, token: String = "") {
        self.endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reads a link, keeping only what is actually usable as a service address.
    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              url.host?.lowercased() == Self.host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let items = components.queryItems ?? []
        let endpoint = items.first { $0.name == "endpoint" }?.value ?? ""
        let token = items.first { $0.name == "token" }?.value ?? ""

        self.init(endpoint: endpoint, token: token)
        guard isUsable else { return nil }
    }

    var url: URL? {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        var items = [URLQueryItem(name: "endpoint", value: endpoint)]
        if !token.isEmpty { items.append(URLQueryItem(name: "token", value: token)) }
        components.queryItems = items
        return components.url
    }

    /// The same rule the settings field applies, so a link can't configure something the app
    /// would have refused if it were typed.
    var isUsable: Bool {
        guard !endpoint.isEmpty, let url = URL(string: endpoint),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else { return false }
        return true
    }

    /// The host on its own, which is the part worth putting in front of someone before they
    /// agree to it — the full URL is too long to read on a sheet and buries the thing that matters.
    var displayHost: String {
        URL(string: endpoint)?.host ?? endpoint
    }

    /// True when the address isn't encrypted. Worth saying out loud: the token, and every video
    /// id, cross the network in the clear.
    var isInsecure: Bool {
        URL(string: endpoint)?.scheme?.lowercased() == "http"
    }
}

// MARK: - QR

/// A QR code for a configuration link.
///
/// Generated on the device rather than fetched: the link can carry a token, and a token that goes
/// through somebody's chart service to be drawn is a token that has left the building.
struct QRCodeView: View {
    let text: String
    var size: CGFloat = 220

    var body: some View {
        Group {
            if let image = Self.image(for: text) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(Color(uiColor: .tertiarySystemFill))
                    .overlay(
                        Image(systemName: "qrcode")
                            .font(.largeTitle)
                            .foregroundStyle(.tertiary)
                    )
            }
        }
        .frame(width: size, height: size)
        .padding(12)
        .background(.white, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    private static let context = CIContext()

    static func image(for text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        // A phone camera reads this from a few inches away on a screen; the middle correction
        // level keeps the pattern coarse enough to scan without making it enormous.
        filter.correctionLevel = "M"

        guard let output = filter.outputImage else { return nil }
        // The generator returns one pixel per module, which upscales to mush unless it is scaled
        // before rasterizing and drawn without interpolation.
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
