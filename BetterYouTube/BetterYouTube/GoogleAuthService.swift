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
    case consentDenied(String?)
    /// Signed in, but without the permission the app runs on.
    case scopeDeclined
    case exchangeFailed(String)
    /// Google rejected the credentials themselves (expired or revoked refresh token).
    case tokenRejected(String)

    var errorDescription: String? {
        switch self {
        case .missingClientId:
            return "Add your Google OAuth client ID in Settings before signing in."
        case .invalidClientId:
            return "That doesn't look like an iOS OAuth client ID (it should end in .apps.googleusercontent.com)."
        case .cancelled:
            return "Sign-in was cancelled."
        case .scopeDeclined:
            return """
            Google signed you in without the YouTube permission, which leaves the app able to do \
            nothing with the account. On the consent screen there is a tick box — "See, edit, and \
            permanently delete your YouTube videos, ratings, comments and captions" — and it has \
            to be ticked before Continue. Sign in again and tick it.
            """
        case .consentDenied(let reason):
            if reason == "access_denied" {
                return """
                Google refused the consent screen (access_denied). While the OAuth consent screen is \
                in Testing, only accounts listed as test users can sign in — add your Google account \
                under Google Auth Platform → Audience → Test users, or publish the app.
                """
            }
            return "Google refused the sign-in request" + (reason.map { " (\($0))" } ?? "") + "."
        case .exchangeFailed(let message):
            return message
        case .tokenRejected(let message):
            return message
        }
    }
}

// MARK: - Token storage

struct OAuthTokens: Codable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
    /// The scopes Google actually granted, space-separated, as it reports them back.
    ///
    /// Not the same thing as the scopes that were asked for. Google's consent screen puts a
    /// tick box against each sensitive permission, and leaving one unticked still produces a
    /// perfectly valid token — one that 403s on everything the app does with it.
    var grantedScope: String?

    /// Treat tokens as expired a minute early so a request never races the expiry.
    var isExpired: Bool { Date() >= expiresAt.addingTimeInterval(-60) }

    /// Whether Google handed over a particular permission.
    func grants(_ scope: String) -> Bool {
        grantedScope?.split(separator: " ").contains { $0 == scope } ?? false
    }
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
/// Reads the signed-in user's subscriptions, playlists and liked videos, and manages the one
/// playlist the app keeps as its Watch Later — which is why the scope is read/write.
@MainActor
final class GoogleAuthService: ObservableObject {
    static let shared = GoogleAuthService()

    @Published private(set) var isSignedIn: Bool = false
    /// Why the app signed itself out, when it wasn't you. Google rejecting a saved sign-in looks
    /// from the outside like the app losing it at random, and the usual cause has a fix worth
    /// naming. Cleared by the next successful sign-in.
    @Published private(set) var lastSignOutReason: String?

    /// What a rejected refresh token almost always means here.
    private static let testingExpiryExplanation = """
    Google stopped accepting the saved sign-in. While the OAuth consent screen is in Testing, \
    refresh tokens expire after seven days — publishing the app under Google Auth Platform → \
    Audience removes that limit. Sign in again to carry on.
    """
    @Published var clientId: String {
        didSet { UserDefaults.standard.set(clientId, forKey: Self.clientIdKey) }
    }

    private static let clientIdKey = "google_oauth_client_id"
    private static let grantedScopeKey = "google_oauth_granted_scope"
    /// Read/write: the app creates and edits its own Watch Later playlist. `youtube.readonly`
    /// would only let it read, and a token granted for that scope can never be upgraded in
    /// place — see `discardTokensGrantedForAnotherScope`.
    private static let scope = "https://www.googleapis.com/auth/youtube"
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
        discardTokensGrantedForAnotherScope()
    }

    /// A refresh token carries the scope it was granted with; asking for more later doesn't widen
    /// it, the request simply comes back 403. So when the scope the app asks for has changed since
    /// the token was issued — an update that added write access, say — the token is dropped and the
    /// user signs in once more. Without this the app would look signed in and refuse every write.
    private func discardTokensGrantedForAnotherScope() {
        guard tokens != nil else { return }
        // Membership, not equality: Google returns the granted scopes as a list, and hands back
        // more than was asked for often enough (`openid`, a profile scope) that comparing the
        // whole string would throw away a perfectly good sign-in on every launch.
        let granted = UserDefaults.standard.string(forKey: Self.grantedScopeKey)
        let holdsScope = granted?.split(separator: " ").contains { $0 == Self.scope } ?? false
        guard !holdsScope else { return }
        signOut()
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
        let callbackItems = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []

        // Google reports refusals on the redirect itself (e.g. error=access_denied), not as a failure.
        if let error = callbackItems.first(where: { $0.name == "error" })?.value {
            throw AuthError.consentDenied(error)
        }

        guard let code = callbackItems.first(where: { $0.name == "code" })?.value else {
            throw AuthError.cancelled
        }

        let tokens = try await exchange(
            code: code,
            verifier: verifier,
            redirectURI: redirectURI,
            clientId: trimmedClientId
        )

        // Google's consent screen puts a tick box against the YouTube permission, and leaving it
        // unticked still issues a valid token — one that 403s on every call the app makes. The
        // app used to record the scope it *asked* for and call itself signed in, so this showed
        // up as being thrown out again seconds later with no way to tell why. Refuse it here,
        // where the reason can still be explained.
        guard tokens.grants(Self.scope) else { throw AuthError.scopeDeclined }

        KeychainStore.save(tokens)
        UserDefaults.standard.set(tokens.grantedScope, forKey: Self.grantedScopeKey)
        self.tokens = tokens
        lastSignOutReason = nil
    }

    func signOut() {
        signOut(reason: nil)
    }

    /// `reason` is set only when the app is the one ending the session, so Settings can say what
    /// happened instead of leaving you to discover it.
    private func signOut(reason: String?) {
        KeychainStore.clear()
        UserDefaults.standard.removeObject(forKey: Self.grantedScopeKey)
        tokens = nil
        lastSignOutReason = reason
        // Set outright rather than leaning on the observer: this also runs from `init`, where
        // property observers stay quiet.
        isSignedIn = false
    }

    /// Called when Google refuses a request for lack of scope. The stored token can't be widened,
    /// so the only way forward is a fresh consent — the safety net for a token whose recorded
    /// scope and real scope have drifted apart.
    func signOutForInsufficientScope() {
        signOut(reason: """
        Google refused the request for lack of permission, and a token's scope can't be widened \
        in place. This almost always means the YouTube tick box on the consent screen — "See, \
        edit, and permanently delete your YouTube videos, ratings, comments and captions" — was \
        left unticked. Sign in again and tick it before Continue.
        """)
    }

    /// Returns a valid access token, refreshing it first when needed. `nil` means "not signed in".
    func accessToken() async -> String? {
        guard let current = tokens else { return nil }
        guard current.isExpired else { return current.accessToken }
        return await renewAccessToken()
    }

    /// Refreshes whatever the stored token's expiry says — for a 401, which means Google has
    /// stopped honouring an access token that still looks good from here.
    func refreshedAccessToken() async -> String? {
        guard tokens != nil else { return nil }
        return await renewAccessToken()
    }

    private func renewAccessToken() async -> String? {
        guard let refreshToken = tokens?.refreshToken else {
            signOut(reason: Self.testingExpiryExplanation)
            return nil
        }
        do {
            var refreshed = try await refresh(refreshToken: refreshToken)
            // Google omits the refresh token on refresh responses; keep the original. It can
            // leave out the scope too, which doesn't mean the grant shrank.
            if refreshed.refreshToken == nil { refreshed.refreshToken = refreshToken }
            if refreshed.grantedScope == nil { refreshed.grantedScope = tokens?.grantedScope }
            KeychainStore.save(refreshed)
            tokens = refreshed
            return refreshed.accessToken
        } catch AuthError.tokenRejected {
            // Revoked, or a Testing-mode refresh token past its 7-day life: ask for a fresh consent.
            signOut(reason: Self.testingExpiryExplanation)
            return nil
        } catch {
            // Transient failure (offline, 5xx): keep the session and retry on the next request.
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
        /// What Google actually granted, which is not always what was asked for — see
        /// `OAuthTokens.grantedScope`.
        let scope: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case scope
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
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // 400/401 means Google rejected the grant itself, not a transient problem.
            throw (400...401).contains(status)
                ? AuthError.tokenRejected(message)
                : AuthError.exchangeFailed(message)
        }

        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        return OAuthTokens(
            accessToken: decoded.accessToken,
            refreshToken: decoded.refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(decoded.expiresIn)),
            grantedScope: decoded.scope
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
