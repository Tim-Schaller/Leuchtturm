import Foundation
import Testing
@testable import LeuchtturmCore

/// The one-hour web link: URL format, encryption, and the vector the web
/// page is checked against (docs/test-vectors/live-v1.json).
struct LiveLinkTests {
    let base = URL(string: "https://tim-schaller.github.io/Leuchtturm/live/")!

    func sample(expires: Date) -> LiveLocation {
        LiveLocation(name: "Tim", latitude: 53.5502, longitude: 9.992, accuracy: 12.4, timestamp: Date(timeIntervalSince1970: 1_791_000_000), battery: 77, expires: expires)
    }

    @Test func linkRoundTripsThroughTheURL() throws {
        let link = LiveLink.create(now: Date(timeIntervalSince1970: 1_791_000_000), production: true)
        let url = link.url(base: base)
        #expect(url.absoluteString.hasPrefix("https://tim-schaller.github.io/Leuchtturm/live/#p."))
        let parsed = try #require(LiveLink(url: url))
        #expect(parsed.id == link.id && parsed.key == link.key && parsed.environment == "p")
        #expect(link.expires == Date(timeIntervalSince1970: 1_791_003_600))
        #expect(link.isActive(at: Date(timeIntervalSince1970: 1_791_003_599)))
        #expect(!link.isActive(at: link.expires))
        #expect(LiveLink(url: URL(string: "https://example.com/#x.y.z")!) == nil)
    }

    @Test func locationOpensOnlyWithTheRightLink() throws {
        let link = LiveLink.create(production: false)
        let location = sample(expires: link.expires)
        let blob = try CircleCrypto.sealLive(location, link: link)
        #expect(try CircleCrypto.openLive(blob, link: link) == location)
        #expect((blob.count - 12 - 16) % 256 == 0)

        let other = LiveLink.create(production: false)
        #expect(throws: (any Error).self) { try CircleCrypto.openLive(blob, link: other) }
        // Same key under another ID (record moved by someone) fails too.
        let moved = LiveLink(id: other.id, key: link.key, expires: link.expires, environment: "d")
        #expect(throws: (any Error).self) { try CircleCrypto.openLive(blob, link: moved) }
    }

    struct Vector: Codable {
        let url: String
        let blob: String
        let name: String
        let latitude: Double
        let longitude: Double
        let accuracy: Double
        let timestamp: Int64
        let battery: Int
        let expires: Int64
    }

    static var vectorURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/test-vectors/live-v1.json")
    }

    /// Set LEUCHTTURM_WRITE_VECTORS=1 to write a fresh vector.
    @Test func vectorOpens() throws {
        if ProcessInfo.processInfo.environment["LEUCHTTURM_WRITE_VECTORS"] == "1" {
            let link = LiveLink.create(now: Date(timeIntervalSince1970: 1_791_000_000), production: true)
            let location = sample(expires: link.expires)
            let vector = Vector(
                url: link.url(base: base).absoluteString, blob: try CircleCrypto.sealLive(location, link: link).base64EncodedString(),
                name: location.name, latitude: location.latitude, longitude: location.longitude, accuracy: 12,
                timestamp: Int64(location.timestamp.timeIntervalSince1970), battery: 77, expires: Int64(link.expires.timeIntervalSince1970)
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(vector).write(to: Self.vectorURL)
        }
        let vector = try JSONDecoder().decode(Vector.self, from: Data(contentsOf: Self.vectorURL))
        let url = try #require(URL(string: vector.url))
        let link = try #require(LiveLink(url: url))
        let blob = try #require(Data(base64Encoded: vector.blob))
        let opened = try CircleCrypto.openLive(blob, link: link)
        #expect(opened.name == vector.name)
        #expect(opened.latitude == vector.latitude && opened.longitude == vector.longitude)
        #expect(opened.accuracy == vector.accuracy && opened.battery == vector.battery)
        #expect(opened.timestamp == Date(timeIntervalSince1970: TimeInterval(vector.timestamp)))
        #expect(opened.expires == Date(timeIntervalSince1970: TimeInterval(vector.expires)))
    }
}
