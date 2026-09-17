import Foundation
import Testing
@testable import BetterYouTube

/// The Takeout reader is a scanner rather than a CSV parser on purpose — Google has changed the
/// shape of this file more than once — so what is worth pinning down is everything it survives.
struct TakeoutPlaylistCSVTests {
    @Test("a plain export: header skipped, ids and dates read")
    func plainExport() {
        let csv = """
        Video ID,Playlist Video Creation Timestamp
        dQw4w9WgXcQ,2024-03-01T12:00:00+00:00
        aaaaaaaaaaa,2024-01-05T09:30:00+00:00
        """
        let rows = TakeoutPlaylistCSV.rows(in: csv)
        #expect(rows.map(\.id) == ["dQw4w9WgXcQ", "aaaaaaaaaaa"])
        #expect(rows.allSatisfy { $0.addedAt != nil })
    }

    /// A byte-order mark, CRLF endings, quoting and stray spaces all arrive in real exports.
    @Test("the mess a real export arrives in")
    func messyExport() {
        let csv = "\u{FEFF}dQw4w9WgXcQ,2024-03-01T12:00:00Z\r\n\"aaaaaaaaaaa\" , \"2024-01-05T09:30:00Z\"\r\n"
        let rows = TakeoutPlaylistCSV.rows(in: csv)
        #expect(rows.map(\.id) == ["dQw4w9WgXcQ", "aaaaaaaaaaa"])
        #expect(rows.allSatisfy { $0.addedAt != nil })
    }

    /// Only the first column is ever looked at, which is what carries the reader over the
    /// metadata block some exports put on top.
    @Test("a preamble, blank lines and a repeat are all stepped over")
    func preambleAndDuplicates() {
        let csv = """
        Playlist Id,PLabcdefghijk
        Title,Watch later

        Video ID,Playlist Video Creation Timestamp
        dQw4w9WgXcQ,2024-03-01T12:00:00Z
        dQw4w9WgXcQ,2024-03-02T12:00:00Z
        bbbbbbbbbbb,2024-02-01T12:00:00Z
        """
        let rows = TakeoutPlaylistCSV.rows(in: csv)
        #expect(rows.map(\.id) == ["dQw4w9WgXcQ", "bbbbbbbbbbb"])
        // The first sighting wins, so the repeat doesn't move the date.
        #expect(rows.first?.addedAt == date("2024-03-01T12:00:00Z"))
    }

    @Test("anything that isn't eleven characters of the id alphabet is not an id")
    func rejectsNonIDs() {
        let csv = """
        short,2024-03-01T12:00:00Z
        waytoolongtobeanid,2024-03-01T12:00:00Z
        has spaces,2024-03-01T12:00:00Z
        exclaim!!!!,2024-03-01T12:00:00Z
        """
        #expect(TakeoutPlaylistCSV.rows(in: csv).isEmpty)
    }

    /// It is generous on purpose — an eleven-letter word in a preamble looks exactly like an id,
    /// and nothing here can tell them apart. That is safe because ids are resolved against
    /// `videos.list` afterwards, where an invented one comes back as missing rather than believed.
    @Test("an eleven-letter word is taken for an id, and that is the deal")
    func generousByDesign() {
        #expect(TakeoutPlaylistCSV.rows(in: "abcdefghijk,").map(\.id) == ["abcdefghijk"])
    }

    @Test("dates decide the order, not the file")
    func datesDecide() {
        let rows = [
            TakeoutPlaylistCSV.Row(id: "aaaaaaaaaaa", addedAt: date("2024-01-01T00:00:00Z")),
            TakeoutPlaylistCSV.Row(id: "bbbbbbbbbbb", addedAt: date("2024-06-01T00:00:00Z")),
            TakeoutPlaylistCSV.Row(id: "ccccccccccc", addedAt: date("2024-03-01T00:00:00Z"))
        ]
        #expect(TakeoutPlaylistCSV.mostRecentlyAdded(in: rows, limit: 2) == ["bbbbbbbbbbb", "ccccccccccc"])
    }

    /// With no dates at all the file's own order is the best there is, and a real export lists
    /// the newest first — so the head is already the wanted end.
    @Test("with no dates the file's order is taken")
    func undatedFallsBackToOrder() {
        let rows = [
            TakeoutPlaylistCSV.Row(id: "aaaaaaaaaaa", addedAt: nil),
            TakeoutPlaylistCSV.Row(id: "bbbbbbbbbbb", addedAt: nil)
        ]
        #expect(TakeoutPlaylistCSV.mostRecentlyAdded(in: rows, limit: 1) == ["aaaaaaaaaaa"])
    }

    /// Half-dated is not sortable, so it falls back too rather than sorting the ones it can and
    /// silently dropping the rest.
    @Test("a partly dated file falls back rather than sorting half of it")
    func partlyDatedFallsBack() {
        let rows = [
            TakeoutPlaylistCSV.Row(id: "aaaaaaaaaaa", addedAt: nil),
            TakeoutPlaylistCSV.Row(id: "bbbbbbbbbbb", addedAt: date("2024-06-01T00:00:00Z"))
        ]
        #expect(TakeoutPlaylistCSV.mostRecentlyAdded(in: rows, limit: 2) == ["aaaaaaaaaaa", "bbbbbbbbbbb"])
    }

    @Test("an empty file asks for nothing")
    func empty() {
        #expect(TakeoutPlaylistCSV.rows(in: "").isEmpty)
        #expect(TakeoutPlaylistCSV.mostRecentlyAdded(in: [], limit: 10).isEmpty)
    }

    private func date(_ iso: String) -> Date {
        YTDateParser.parse(iso) ?? .distantPast
    }
}
