import Foundation
import Security

/// The keychain, as the two secrets in this app need it.
///
/// Both of them — the Google refresh token and the download service's bearer token — are
/// credentials, and a credential in `UserDefaults` is a credential in a plist anyone running as
/// this user can read. That is the whole reason this file exists.
///
/// `kSecUseDataProtectionKeychain` is the part that matters on macOS. Without it a Mac uses the
/// old file-based keychain, where `kSecAttrAccessible` means nothing, the item can end up in the
/// login keychain rather than the app's own, and the user is asked for a password the first time
/// the app reads back something it wrote itself. With it, both platforms use the same keychain
/// with the same semantics — which is also what makes an item follow the app rather than the Mac
/// it was signed on, and why the macOS build is sandboxed (see `BetterYouTube-macOS.entitlements`).
///
/// Every item is `AfterFirstUnlock`: the app has to be able to refresh a token from a background
/// task, which runs with the device locked.
enum Keychain {
    /// Writes the secret, and says whether it made it in.
    ///
    /// `errSecSuccess` when it did; anything else means the secret is not stored, and the caller
    /// has to know. A sign-in that pretends to have worked leaves the app signed out for the
    /// next launch, with nothing said.
    ///
    /// The item that is already there is updated rather than deleted and added again: a delete
    /// that succeeds followed by an add that fails leaves nothing behind — the secret is gone,
    /// and the app doesn't know.
    @discardableResult
    static func save(_ data: Data, service: String, account: String) -> OSStatus {
        let update = SecItemUpdate(query(service: service, account: account) as CFDictionary,
                                   [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock] as CFDictionary)
        if update == errSecSuccess { return update }
        // There was nothing to update: the secret is new to this device.
        guard update == errSecItemNotFound else { return update }

        var attributes = query(service: service, account: account)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attributes as CFDictionary, nil)
    }

    static func load(service: String, account: String) -> Data? {
        var request = query(service: service, account: account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return data
    }

    static func delete(service: String, account: String) {
        SecItemDelete(query(service: service, account: account) as CFDictionary)
    }

    /// What identifies one item, and nothing else — so save, load and delete cannot drift apart
    /// and leave a secret behind under a key nobody looks under any more.
    private static func query(service: String, account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }
}

// MARK: - Text

extension Keychain {
    /// A secret that is a string rather than a blob, which both of this app's are.
    ///
    /// An empty string deletes the item rather than storing nothing: "no token" and "an empty
    /// token" are the same thing to every caller, and only one of them leaves the keychain clean.
    @discardableResult
    static func saveText(_ text: String, service: String, account: String) -> OSStatus {
        guard !text.isEmpty else {
            delete(service: service, account: account)
            return errSecSuccess
        }
        return save(Data(text.utf8), service: service, account: account)
    }

    static func loadText(service: String, account: String) -> String? {
        load(service: service, account: account).flatMap { String(data: $0, encoding: .utf8) }
    }
}
