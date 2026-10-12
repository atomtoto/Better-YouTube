import Foundation
import Testing
@testable import BetterYouTube

/// Reads the same `UserDefaults` key the app does, so each test puts back what it found.
@Suite(.serialized)
struct LaunchSectionTests {
    private let defaults = UserDefaults.standard

    private func withSaved(_ value: String?, _ body: () -> Void) {
        let key = LaunchSectionPreference.storageKey
        let previous = defaults.object(forKey: key)
        defaults.set(value, forKey: key)
        defer { defaults.set(previous, forKey: key) }
        body()
    }

    @Test("opens on Home when nothing has been chosen")
    func defaultsToHome() {
        withSaved(nil) {
            #expect(LaunchSectionPreference.stored == .home)
        }
    }

    @Test("opens on Library when Library was chosen")
    func opensOnLibrary() {
        withSaved(LaunchSectionPreference.library.rawValue) {
            #expect(LaunchSectionPreference.stored.tab == .library)
        }
    }

    @Test("a saved value that no longer exists opens on Home")
    func unknownValueFallsBackToHome() {
        withSaved("search") {
            #expect(LaunchSectionPreference.stored == .home)
        }
    }
}
