import Testing
@testable import BetterYouTube

/// What the YouTube API actually hands back, and the one case that used to be read wrong.
struct DurationFormatterTests {
    @Test("the shapes a video's duration comes in")
    func videoDurations() {
        #expect(ISO8601DurationFormatter.humanReadable("PT4M13S") == "4:13")
        #expect(ISO8601DurationFormatter.humanReadable("PT45S") == "0:45")
        #expect(ISO8601DurationFormatter.humanReadable("PT1H2M3S") == "1:02:03")
        #expect(ISO8601DurationFormatter.humanReadable("PT1H") == "1:00:00")
        #expect(ISO8601DurationFormatter.humanReadable("PT0S") == "0:00")
    }

    /// The regression this file was written for: `M` means months before the `T` and minutes
    /// after it, and the parser used to read both as minutes.
    @Test("a month is not a minute")
    func monthsAreNotMinutes() {
        #expect(ISO8601DurationFormatter.humanReadable("PT1M") == "1:00")
        #expect(ISO8601DurationFormatter.humanReadable("P1M") == "0:00")
        #expect(ISO8601DurationFormatter.humanReadable("P1Y") == "0:00")
        // Both halves in one string: the month is dropped, the seconds are kept.
        #expect(ISO8601DurationFormatter.humanReadable("P1MT30S") == "0:30")
    }

    /// `P0D` is what a live stream comes back as, so the date half has to parse at all.
    @Test("days and weeks fold into hours")
    func dateHalf() {
        #expect(ISO8601DurationFormatter.humanReadable("P0D") == "0:00")
        #expect(ISO8601DurationFormatter.humanReadable("P1DT2H30M") == "26:30:00")
        #expect(ISO8601DurationFormatter.humanReadable("P1W") == "168:00:00")
    }

    @Test("nothing recognisable reads as zero rather than crashing")
    func nonsense() {
        #expect(ISO8601DurationFormatter.humanReadable("") == "0:00")
        #expect(ISO8601DurationFormatter.humanReadable("banana") == "0:00")
    }
}
