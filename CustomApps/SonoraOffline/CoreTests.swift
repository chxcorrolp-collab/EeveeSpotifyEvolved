import XCTest
@testable import SonoraCore

final class CoreTests: XCTestCase {
    func testRejectsUnexpectedHostsAndCommandLikeInputs() throws {
        for value in ["https://open.spotify.com.evil.example/track/0VjIjW4GlUZAMYd2vXMi3b", "file:///tmp/a", "https://open.spotify.com:444/track/0VjIjW4GlUZAMYd2vXMi3b", "https://example.com/track/0VjIjW4GlUZAMYd2vXMi3b", "spotify:track:../../Documents"] {
            XCTAssertThrowsError(try SpotifyCatalog.reference(value))
        }
        XCTAssertEqual(try SpotifyCatalog.reference("https://open.spotify.com/intl-es/album/4yP0hdKOZPNshxUOjY0cZj?si=example").kind, "album")
    }
    func testJSONParserHandlesBracesAndEscapedQuotes() throws {
        let input = #"var ytInitialData = {"title":"a } \" b", "nested":{"ok":true}}; other();"#
        let object = try WebData.object(in: input, after: "var ytInitialData =")
        XCTAssertEqual(object["title"] as? String, "a } \" b")
        XCTAssertThrowsError(try WebData.object(in: "var ytInitialData = {\"x\": {", after: "var ytInitialData ="))
    }
    func testCatalogImportsFullDurationAndIgnoresPreviewAudio() throws {
        let row: [String: Any] = ["type":"track", "uri":"spotify:track:0VjIjW4GlUZAMYd2vXMi3b", "title":"Blinding Lights", "artists":[["name":"The Weeknd"]], "duration":200040, "audioPreview":["url":"https://example.com/30-seconds.mp3"]]
        let catalog = try SpotifyCatalog.parse(row)
        XCTAssertEqual(catalog.tracks.first?.duration ?? 0, 200.04, accuracy: 0.01)
        XCTAssertEqual(catalog.tracks.first?.artist, "The Weeknd")
        XCTAssertEqual(catalog.tracks.count, 1)
    }
    func testAlbumDeduplicatesTracksAndRejectsEmptyCatalog() throws {
        let row: [String: Any] = ["uri":"spotify:track:0VjIjW4GlUZAMYd2vXMi3b", "title":"Song", "subtitle":"Artist", "duration":200000]
        XCTAssertEqual(try SpotifyCatalog.parse(["type":"album", "title":"Album", "trackList":[row,row]]).tracks.count, 1)
        XCTAssertThrowsError(try SpotifyCatalog.parse(["type":"album", "trackList":[]]))
    }
    func testMatchingRejectsWrongVersionsAndLongVideos() throws {
        let track = CatalogTrack(id: "0VjIjW4GlUZAMYd2vXMi3b", title: "Blinding Lights", artist: "The Weeknd", duration: 200, coverURL: nil)
        let root: [String:Any] = ["items":[
            ["videoRenderer":["videoId":"abcdefghijk", "title":["simpleText":"The Weeknd - Blinding Lights (Official Audio)"], "lengthText":["simpleText":"3:20"], "ownerText":["simpleText":"The Weeknd"]]],
            ["videoRenderer":["videoId":"abcdefghijl", "title":["simpleText":"Blinding Lights karaoke"], "lengthText":["simpleText":"3:20"]]],
            ["videoRenderer":["videoId":"abcdefghijm", "title":["simpleText":"The Weeknd Blinding Lights"], "lengthText":["simpleText":"1:00:00"]]]]]
        let videos = YouTubeSearch.candidates(from: root)
        XCTAssertGreaterThan(YouTubeSearch.score(videos[0], for: track), 0.9)
        XCTAssertEqual(YouTubeSearch.score(videos[1], for: track), 0)
        XCTAssertEqual(YouTubeSearch.score(videos[2], for: track), 0)
    }
}
