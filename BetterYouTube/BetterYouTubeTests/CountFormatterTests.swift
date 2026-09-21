import Testing
@testable import BetterYouTube

struct CountFormatterTests {
    @Test("counts abbreviate at each threshold")
    func thresholds() {
        #expect(CountFormatter.abbreviated(nil) == "—")
        #expect(CountFormatter.abbreviated(0) == "0")
        #expect(CountFormatter.abbreviated(999) == "999")
        #expect(CountFormatter.abbreviated(1_000) == "1.0K")
        #expect(CountFormatter.abbreviated(1_500) == "1.5K")
        #expect(CountFormatter.abbreviated(999_999) == "1000.0K")
        #expect(CountFormatter.abbreviated(1_500_000) == "1.5M")
        #expect(CountFormatter.abbreviated(2_000_000_000) == "2.0B")
    }
}
