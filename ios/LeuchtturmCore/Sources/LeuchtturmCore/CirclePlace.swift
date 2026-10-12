#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// A place of a circle, e.g. home or school. Encrypted under the circle key
/// and signed by the device that created it. Arrivals and departures are
/// detected on each member's own device (`PlaceTracker`).
public struct CirclePlace: Sendable, Hashable, Identifiable {
    public let id: String
    /// Device ID of the member who created it.
    public let creatorID: String
    public let name: String
    /// One emoji shown on the map.
    public let emoji: String
    public let latitude: Double
    public let longitude: Double
    /// Meters.
    public let radius: Int

    public static let radii: ClosedRange<Int> = 50 ... 2000
    public static let maxNameLength = 40

    /// Returns nil for names, emojis, coordinates or radii that cannot be used.
    public init?(id: String, creatorID: String, name: String, emoji: String, latitude: Double, longitude: Double, radius: Int) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= Self.maxNameLength, emoji.count == 1,
              (-90 ... 90).contains(latitude), (-180 ... 180).contains(longitude), Self.radii.contains(radius)
        else { return nil }
        self.id = id
        self.creatorID = creatorID
        self.name = name
        self.emoji = emoji
        self.latitude = latitude
        self.longitude = longitude
        self.radius = radius
    }

    /// Meters from the place's center (haversine; good enough for geofences).
    public func distance(toLatitude latitude: Double, longitude: Double) -> Double {
        let r = 6_371_000.0
        let dLat = (latitude - self.latitude) * .pi / 180
        let dLon = (longitude - self.longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(self.latitude * .pi / 180) * cos(latitude * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(a)))
    }
}

/// Plaintext inside a place blob.
private struct PlacePayload: Codable {
    let n: String
    let e: String
    let lat: Double
    let lon: Double
    let r: Int
}

extension CircleCrypto {
    static func sealPlace(_ place: CirclePlace, key: SymmetricKey, epoch: Int64, circleID: String) throws -> Data {
        let payload = PlacePayload(n: place.name, e: place.emoji, lat: place.latitude, lon: place.longitude, r: place.radius)
        return try sealContent(JSONEncoder().encode(payload), key: key, epoch: epoch, context: placeContext(circleID: circleID, placeID: place.id))
    }

    /// Returns nil when no key is known for the blob's epoch.
    static func openPlace(
        _ blob: Data, id: String, creatorID: String, circleID: String, keyForEpoch: (Int64) -> SymmetricKey?
    ) throws -> CirclePlace? {
        guard let (plain, _) = try openContent(blob, context: placeContext(circleID: circleID, placeID: id), keyForEpoch: keyForEpoch)
        else { return nil }
        let p = try JSONDecoder().decode(PlacePayload.self, from: plain)
        guard let place = CirclePlace(id: id, creatorID: creatorID, name: p.n, emoji: p.e, latitude: p.lat, longitude: p.lon, radius: p.r)
        else { throw ProtocolError.malformed }
        return place
    }

    /// Bytes the creating device signs for a place record.
    static func placeRecordStatement(circleID: String, placeID: String, creatorID: String, blob: Data) -> Data {
        Wire.context("leuchtturm/v1/place-record", circleID, placeID, creatorID) + blob
    }

    static func placeContext(circleID: String, placeID: String) -> Data {
        Wire.context("leuchtturm/v1/place", circleID, placeID)
    }
}

/// Detects arrivals at and departures from places, on the device. Leaving
/// needs a margin beyond the radius so GPS jitter at the edge does not
/// cause a flood of alerts. The first look at a place only records where
/// you are, so creating a place you are at does not announce an arrival.
/// Passing through at driving speed is no arrival (and so no departure).
public struct PlaceTracker: Sendable, Codable, Equatable {
    public enum Event: Sendable, Equatable {
        case arrived(CirclePlace)
        case left(CirclePlace)
    }

    public private(set) var inside: Set<String> = []
    private var known: Set<String> = []

    /// Faster than this (m/s, about 25 km/h) one is passing by, not arriving.
    public static let passingSpeed = 7.0

    public init() {}

    /// `speed` in m/s; nil or negative if unknown.
    public mutating func update(latitude: Double, longitude: Double, accuracy: Double, speed: Double? = nil, places: [CirclePlace]) -> [Event] {
        let passing = (speed ?? -1) >= Self.passingSpeed
        let ids = Set(places.map(\.id))
        inside.formIntersection(ids)
        known.formIntersection(ids)
        var events: [Event] = []
        for place in places where accuracy <= Double(max(100, place.radius)) {
            let distance = place.distance(toLatitude: latitude, longitude: longitude)
            let isInside = inside.contains(place.id)
            let firstLook = !known.contains(place.id)
            known.insert(place.id)
            if !isInside, distance <= Double(place.radius), !passing {
                inside.insert(place.id)
                if !firstLook { events.append(.arrived(place)) }
            } else if isInside, distance > Double(place.radius) + max(50, accuracy) {
                inside.remove(place.id)
                events.append(.left(place))
            }
        }
        return events
    }
}
