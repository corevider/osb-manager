import Foundation
import Testing
@testable import OsbManagerCore

struct PackRequestTests {
    private static let pack = "game-audio-001-1b1f41de894d.bin"
    private static let url = "https://opensro.online/assets/packs/game-audio-001-1b1f41de894d.bin"

    @Test func matchesAClosedRangeOfAPackWithGet() {
        let request = PackRequest.match(method: "GET", url: Self.url, rangeHeader: "bytes=0-65535")

        #expect(request == PackRequest(url: Self.url, pack: Self.pack, range: ByteRange(start: 0, end: 65535)))
    }

    @Test func acceptsLowerCaseMethodsAndRangeUnits() {
        #expect(PackRequest.match(method: "get", url: Self.url, rangeHeader: "Bytes=10-19")?.range == ByteRange(start: 10, end: 19))
    }

    @Test(arguments: [
        ("POST", "https://opensro.online/assets/packs/game-audio-001-1b1f41de894d.bin", "bytes=0-9"),
        ("HEAD", "https://opensro.online/assets/packs/game-audio-001-1b1f41de894d.bin", "bytes=0-9"),
        ("GET", "https://opensro.online/assets/packs/game-audio-001-1b1f41de894d.bin", nil),
        ("GET", "https://opensro.online/assets/packs/game-audio-001-1b1f41de894d.bin", ""),
        ("GET", "https://opensro.online/assets/packs/game-audio-001-1b1f41de894d.bin", "bytes=5-"),
        ("GET", "https://opensro.online/assets/packs/game-audio-001-1b1f41de894d.bin", "bytes=-500"),
        ("GET", "https://opensro.online/assets/packs/game-audio-001-1b1f41de894d.bin", "bytes=0-9,20-29"),
        ("GET", "https://opensro.online/assets/packs/game-audio-001-1b1f41de894d.bin", "bytes=9-0"),
        ("GET", "https://opensro.online/assets/packs/game-audio-001-1b1f41de894d.bin", "bytes=0-67108864"),
        ("GET", "https://opensro.online/assets/packs/game-audio-001-1b1f41de894d.bin?x=1", "bytes=0-9"),
        ("GET", "http://opensro.online/assets/packs/game-audio-001-1b1f41de894d.bin", "bytes=0-9"),
        ("GET", "https://cdn.opensro.online/assets/packs/game-audio-001-1b1f41de894d.bin", "bytes=0-9"),
        ("GET", "https://opensro.online/assets/other/game-audio-001-1b1f41de894d.bin", "bytes=0-9"),
        ("GET", "https://opensro.online/assets/packs/not-a-pack.bin", "bytes=0-9"),
        ("GET", "https://opensro.online/assets/packs/game-audio-001-1b1f41de894d.bin.index", "bytes=0-9"),
        ("GET", "https://opensro.online/play", "bytes=0-9"),
    ] as [(String, String, String?)])
    func ignoresEverythingElse(method: String, url: String, range: String?) {
        #expect(PackRequest.match(method: method, url: url, rangeHeader: range) == nil)
    }

    @Test func takesTheLargestAllowedRange() {
        #expect(PackRequest.match(method: "GET", url: Self.url, rangeHeader: "bytes=0-67108863")?.range.length == ByteRange.maxLength)
    }

    @Test func writesTheWindowsResponseHeaders() {
        let headers = PackResponse.headers(range: ByteRange(start: 100, end: 199), total: 5000)

        #expect(headers == [
            "Content-Type": "application/octet-stream",
            "Content-Length": "100",
            "Content-Range": "bytes 100-199/5000",
            "Accept-Ranges": "bytes",
            "Cache-Control": "no-store",
        ])
        #expect(PackResponse.status == 206)
        #expect(PackResponse.statusText == "Partial Content")
    }

    @Test func servesOnlyAnswersOfTheRightLengthInsideThePack() {
        let range = ByteRange(start: 10, end: 19)

        #expect(PackResponse.isServable(CachedRange(bytes: Data(count: 10), total: 100, fromDisk: true), for: range))
        #expect(!PackResponse.isServable(CachedRange(bytes: Data(count: 9), total: 100, fromDisk: true), for: range))
        #expect(!PackResponse.isServable(CachedRange(bytes: Data(count: 11), total: 100, fromDisk: false), for: range))
        #expect(!PackResponse.isServable(CachedRange(bytes: Data(count: 10), total: 19, fromDisk: false), for: range))
    }
}
