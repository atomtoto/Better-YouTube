import Foundation
import Security
import Testing
@testable import BetterYouTube

/// Runs inside the app, with the app's own signature, so it checks the build as much as the code:
/// a Mac build signed without an `application-identifier` can't write to the data-protection
/// keychain at all, and every sign-in it makes is lost at the next launch.
struct KeychainTests {
    private let service = "com.atomtoto.BetterYouTube.tests.\(UUID().uuidString)"
    private let account = "secret"

    @Test("a secret written to the keychain reads back, and replaces the one before it")
    func roundTrip() {
        defer { Keychain.delete(service: service, account: account) }

        #expect(Keychain.saveText("first", service: service, account: account) == errSecSuccess)
        #expect(Keychain.saveText("second", service: service, account: account) == errSecSuccess)
        #expect(Keychain.loadText(service: service, account: account) == "second")
    }

    @Test("an empty secret removes the item")
    func emptyDeletes() {
        defer { Keychain.delete(service: service, account: account) }

        Keychain.saveText("token", service: service, account: account)
        #expect(Keychain.saveText("", service: service, account: account) == errSecSuccess)
        #expect(Keychain.loadText(service: service, account: account) == nil)
    }
}
