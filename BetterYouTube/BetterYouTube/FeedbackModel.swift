import Foundation
import Observation

/// Set these values when the Formspree form and contact address are available.
enum FeedbackConfiguration {
    static let formspreeEndpoint: URL? = URL(string: "https://formspree.io/f/xljbegvp")
    static let supportEmail: String? = "atom.dejonghe@ecomail.fr"
}

enum FeedbackLinks {
    static func githubIssue(message: String) -> URL? {
        var components = URLComponents(string: "https://github.com/atomtoto/Better-YouTube/issues/new")!
        components.percentEncodedQuery = query([("title", "Feedback"), ("body", message)])
        return components.url
    }

    static func email(message: String, address: String) -> URL? {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, !address.contains(where: { $0.isWhitespace || $0.isNewline }),
              address.filter({ $0 == "@" }).count == 1,
              !address.hasPrefix("@"), !address.hasSuffix("@") else { return nil }
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = address
        components.percentEncodedQuery = query([("subject", "Better YouTube feedback"), ("body", message)])
        return components.url
    }

    private static func query(_ items: [(String, String)]) -> String? {
        // Encode '+' as well as '&' and '=' so mail clients and GitHub do not
        // reinterpret user input as spaces or additional query parameters.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let parts = items.compactMap { name, value -> String? in
            guard let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
            return "\(name)=\(encoded)"
        }
        return parts.count == items.count ? parts.joined(separator: "&") : nil
    }
}

@MainActor
@Observable
final class FeedbackModel {
    enum SubmissionState: Equatable {
        case idle, success, failure
    }

    var message = ""
    var email = ""
    private(set) var isSending = false
    private(set) var submissionState: SubmissionState = .idle

    private let endpoint: URL?
    private let session: URLSession

    init(endpoint: URL? = FeedbackConfiguration.formspreeEndpoint, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    var isConfigured: Bool {
        guard let endpoint, let components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { return false }
        return components.scheme?.lowercased() == "https"
            && components.host?.lowercased() == "formspree.io"
            && components.path.hasPrefix("/f/") && components.path.count > 3
            && components.user == nil && components.password == nil
    }

    var canSend: Bool {
        isConfigured && !isSending && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func send() async {
        guard canSend, let endpoint else { return }
        isSending = true
        submissionState = .idle
        defer { isSending = false }

        let sentMessage = message
        let replyAddress = email.trimmingCharacters(in: .whitespacesAndNewlines)
        var fields = ["message": sentMessage]
        if !replyAddress.isEmpty { fields["email"] = replyAddress }

        do {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.httpBody = try JSONEncoder().encode(fields)
            let (_, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                submissionState = .failure
                return
            }
            if message == sentMessage { message = "" }
            submissionState = .success
        } catch {
            submissionState = .failure
        }
    }
}
