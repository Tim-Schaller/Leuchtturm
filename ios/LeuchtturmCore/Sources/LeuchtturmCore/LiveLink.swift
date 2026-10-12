#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// A web link that shows one person's location for a limited time to
/// someone without the app:
///
///     https://…/live/#<environment>.<link id>.<key>
///
/// The fragment never reaches a web server. The location is encrypted with
/// AES-GCM (so a browser can open it with WebCrypto) and stored in the
/// public iCloud database under `live-<link id>`, where only its creator
/// can change it.
public struct LiveLink: Sendable, Equatable, Codable {
    public let id: String
    public let key: Data
    public let expires: Date
    /// "d" for the CloudKit Development environment, "p" for Production.
    public let environment: String

    public static let defaultDuration: TimeInterval = 3600

    public init(id: String, key: Data, expires: Date, environment: String) {
        self.id = id
        self.key = key
        self.expires = Date(timeIntervalSince1970: expires.timeIntervalSince1970.rounded(.down))
        self.environment = environment
    }

    public static func create(now: Date = Date(), duration: TimeInterval = defaultDuration, production: Bool) -> LiveLink {
        LiveLink(id: Base64URL.encode(randomBytes(16)), key: randomBytes(32), expires: now.addingTimeInterval(duration), environment: production ? "p" : "d")
    }

    public var recordName: String { "live-" + id }

    public func url(base: URL) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.fragment = [environment, id, Base64URL.encode(key)].joined(separator: ".")
        return components.url!
    }

    public init?(url: URL) {
        let parts = (url.fragment ?? "").split(separator: ".").map(String.init)
        guard parts.count == 3, ["d", "p"].contains(parts[0]), DeviceID.raw(parts[1]) != nil,
              let key = Base64URL.decode(parts[2]), key.count == 32
        else { return nil }
        self.init(id: parts[1], key: key, expires: .distantFuture, environment: parts[0])
    }

    public func isActive(at now: Date) -> Bool { now < expires }
}

/// What the web page shows.
public struct LiveLocation: Sendable, Equatable {
    public let name: String
    public let latitude: Double
    public let longitude: Double
    public let accuracy: Double
    public let timestamp: Date
    public let battery: Int?
    public let expires: Date

    public init(name: String, latitude: Double, longitude: Double, accuracy: Double, timestamp: Date, battery: Int?, expires: Date) {
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        // Whole metres and seconds, as on the wire.
        self.accuracy = accuracy.rounded()
        self.timestamp = Date(timeIntervalSince1970: timestamp.timeIntervalSince1970.rounded(.down))
        self.battery = battery
        self.expires = Date(timeIntervalSince1970: expires.timeIntervalSince1970.rounded(.down))
    }
}

private struct LivePayload: Codable {
    let v: Int
    let n: String
    let la: Double
    let lo: Double
    let ac: Double
    /// Unix seconds.
    let t: Int64
    var b: Int?
    let e: Int64
}

extension CircleCrypto {
    /// Layout: `nonce (12) | ciphertext | tag (16)` (AES-256-GCM, CryptoKit's
    /// combined form). AAD: `"leuchtturm/v1/live" ‖ link id`. The JSON is
    /// padded with spaces to a multiple of 256 bytes.
    public static func sealLive(_ location: LiveLocation, link: LiveLink) throws -> Data {
        let payload = LivePayload(
            v: 1, n: String(location.name.prefix(60)), la: location.latitude, lo: location.longitude,
            ac: location.accuracy, t: Int64(location.timestamp.timeIntervalSince1970), b: location.battery,
            e: Int64(location.expires.timeIntervalSince1970)
        )
        var json = try JSONEncoder().encode(payload)
        json.append(Data(repeating: 0x20, count: (256 - json.count % 256) % 256))
        guard let combined = try AES.GCM.seal(json, using: SymmetricKey(data: link.key), authenticating: liveAAD(link.id)).combined
        else { throw ProtocolError.malformed }
        return combined
    }

    public static func openLive(_ blob: Data, link: LiveLink) throws -> LiveLocation {
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: blob), using: SymmetricKey(data: link.key), authenticating: liveAAD(link.id))
        let p = try JSONDecoder().decode(LivePayload.self, from: plain)
        guard p.v == 1, (-90...90).contains(p.la), (-180...180).contains(p.lo) else { throw ProtocolError.malformed }
        return LiveLocation(
            name: p.n, latitude: p.la, longitude: p.lo, accuracy: p.ac, timestamp: Date(timeIntervalSince1970: TimeInterval(p.t)),
            battery: p.b, expires: Date(timeIntervalSince1970: TimeInterval(p.e))
        )
    }

    static func liveAAD(_ id: String) -> Data {
        Data("leuchtturm/v1/live".utf8) + Data(id.utf8)
    }
}
