import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

// MARK: - Errors

enum AuthError: LocalizedError {
    case missingClientId
    case invalidClientId
    case cancelled
    case exchangeFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingClientId:
            return "Add your Google OAuth client ID in Settings before signing in."
        case .invalidClientId:
            return "That doesn't look like an iOS OAuth client ID (it should end in .apps.googleusercontent.com)."
        case .cancelled:
            return "Sign-in was cancelled."
        case .exchangeFailed(let message):
            return message
        }
    }
}

// MARK: - Token storage

struct OAuthTokens: Codable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date

    /// Treat tokens as expired a minute early so a request never races the expiry.
    var isExpired: Bool { Date() >= expiresAt.addingTimeInterval(-60) }
}

/// Tokens live in the keychain rather than UserDefaults — they're credentials.
enum KeychainStore {
    private static let service = "com.atomtoto.BetterYouTube.oauth"
    private static let account = "google"

    static func save(_ tokens: OAuthTokens) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func load() -> OAuthTokens? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(OAuthTokens.self, from: data)
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Presentation anchor

final class WebAuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}

// MARK: - Service

/// Google sign-in for installed apps: OAuth 2.0 authorization code flow with PKCE, no client secret.
/// Grants read-only access to the signed-in user's subscriptions, playlists and liked videos.
@MainActor
final class GoogleAuthService: ObservableObject {
    static let shared = GoogleAuthService()

    @Published private(set) var isSignedIn: Bool = false
    @Published var clientId: String {
        didSet { UserDefaults.standard.set(clientId, forKey: Self.clientIdKey) }
    }

    private static let clientIdKey = "google_oauth_client_id"
    private static let scope = "https://www.googleapis.com/auth/youtube.readonly"
    private static let authEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    private static let tokenEndpoint = "https://oauth2.googleapis.com/token"

    private let presenter = WebAuthPresenter()
    private var session: ASWebAuthenticationSession?
    private var tokens: OAuthTokens? {
        didSet { isSignedIn = tokens != nil }
    }

    private init() {
        self.clientId = UserDefaults.standard.string(forKey: Self.clientIdKey) ?? ""
        self.tokens = KeychainStore.load()
        self.isSignedIn = tokens != nil
    }

    /// Google's iOS clients use the reversed client ID as their custom URL scheme.
    var redirectScheme: String? {
        let suffix = ".apps.googleusercontent.com"
        let trimmed = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(suffix) else { return nil }
        let prefix = String(trimmed.dropLast(suffix.count))
        guard !prefix.isEmpty else { return nil }
        return "com.googleusercontent.apps.\(prefix)"
    }

    // MARK: Sign in / out

    func signIn() async throws {
        let trimmedClientId = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedClientId.isEmpty else { throw AuthError.missingClientId }
        guard let scheme = redirectScheme else { throw AuthError.invalidClientId }

        let verifier = Self.randomCodeVerifier()
        let redirectURI = "\(scheme):/oauth2redirect"

        guard var components = URLComponents(string: Self.authEndpoint) else {
            throw AuthError.exchangeFailed("Invalid authorization endpoint.")
        }
        components.queryItems = [
            URLQueryItem(name: "client_id", value: trimmedClientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "code_challenge", value: Self.codeChallenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent")
        ]
        guard let authURL = components.url else {
            throw AuthError.exchangeFailed("Could not build the sign-in URL.")
        }

        let callbackURL = try await authenticate(url: authURL, scheme: scheme)
        guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "code" })?
            .value else {
            throw AuthError.cancelled
        }

        let tokens = try await exchange(
            code: code,
            verifier: verifier,
            redirectURI: redirectURI,
            clientId: trimmedClientId
        )
        KeychainStore.save(tokens)
        self.tokens = tokens
    }

    func signOut() {
        KeychainStore.clear()
        tokens = nil
    }

    /// Returns a valid access token, refreshing it first when needed. `nil` means "not signed in".
    func accessToken() async -> String? {
        guard let current = tokens else { return nil }
        guard current.isExpired else { return current.accessToken }
        guard let refreshToken = current.refreshToken else {
            signOut()
            return nil
        }
        do {
            var refreshed = try await refresh(refreshToken: refreshToken)
            // Google omits the refresh token on refresh responses; keep the original.
            if refreshed.refreshToken == nil { refreshed.refreshToken = refreshToken }
            KeychainStore.save(refreshed)
            tokens = refreshed
            return refreshed.accessToken
        } catch {
            return nil
        }
    }

    // MARK: Private

    private func authenticate(url: URL, scheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callbackURL, error in
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: AuthError.cancelled)
                }
            }
            session.presentationContextProvider = presenter
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                continuation.resume(throwing: AuthError.cancelled)
            }
        }
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }

    private func exchange(code: String, verifier: String, redirectURI: String, clientId: String) async throws -> OAuthTokens {
        try await postToken(parameters: [
            "code": code,
            "client_id": clientId,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI
        ])
    }

    private func refresh(refreshToken: String) async throws -> OAuthTokens {
        let trimmedClientId = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await postToken(parameters: [
            "client_id": trimmedClientId,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ])
    }

    private func postToken(parameters: [String: String]) async throws -> OAuthTokens {
        guard let url = URL(string: Self.tokenEndpoint) else {
            throw AuthError.exchangeFailed("Invalid token endpoint.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = parameters
            .map { "\($0.key)=\(Self.formEncode($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Token request failed."
            throw AuthError.exchangeFailed(message)
        }

        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        return OAuthTokens(
            accessToken: decoded.accessToken,
            refreshToken: decoded.refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(decoded.expiresIn))
        )
    }

    // MARK: PKCE helpers

    private static func randomCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URL(Data(digest))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
