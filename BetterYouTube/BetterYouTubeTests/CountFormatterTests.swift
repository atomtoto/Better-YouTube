import Foundation
import Testing
@testable import BetterYouTube

struct CountFormatterTests {
    private let english = Locale(identifier: "en_US")
    private let french = Locale(identifier: "fr_FR")

    @Test("counts abbreviate at each threshold")
    func thresholds() {
        #expect(CountFormatter.abbreviated(nil, locale: english) == "—")
        #expect(CountFormatter.abbreviated(0, locale: english) == "0")
        #expect(CountFormatter.abbreviated(999, locale: english) == "999")
        #expect(CountFormatter.abbreviated(1_000, locale: english) == "1K")
        #expect(CountFormatter.abbreviated(1_500, locale: english) == "1.5K")
        #expect(CountFormatter.abbreviated(12_345, locale: english) == "12K")
        #expect(CountFormatter.abbreviated(1_500_000, locale: english) == "1.5M")
        #expect(CountFormatter.abbreviated(2_000_000_000, locale: english) == "2B")
    }

    @Test("rounding carries into the next unit")
    func roundsAcrossUnits() {
        // The hand-rolled formatter printed this as "1000.0K".
        #expect(CountFormatter.abbreviated(999_999, locale: english) == "1M")
    }

    @Test("counts follow the reader's language")
    func localized() {
        let thousands = CountFormatter.abbreviated(1_500, locale: french)
        #expect(thousands.hasPrefix("1,5"))
        #expect(thousands.hasSuffix("k"))
        #expect(CountFormatter.abbreviated(2_000_000_000, locale: french).hasSuffix("Md"))
    }
}
