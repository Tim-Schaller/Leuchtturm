#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// A position shared with a circle. Encrypted under the circle key and
/// signed by the device it belongs to, so no other member can fake it.
public struct SharedLocation: Sendable, Hashable {
    public let latitude: Double
    public let longitude: Double
    /// Horizontal accuracy in meters.
    public let accuracy: Double
    /// When the position was measured (whole seconds).
    public let timestamp: Date
    /// Battery level in percent, if the device shares it.
    public let battery: Int?
    public let isCharging: Bool

    /// Returns nil for coordinates, accuracies or battery levels that cannot be real.
    public init?(
        latitude: Double, longitude: Double, accuracy: Double, timestamp: Date,
        battery: Int? = nil, isCharging: Bool = false
    ) {
        guard (-90 ... 90).contains(latitude), (-180 ... 180).contains(longitude),
              accuracy.isFinite, (0 ... 100_000).contains(accuracy),
              timestamp.timeIntervalSince1970 > 0,
              battery.map({ (0 ... 100).contains($0) }) ?? true
        else { return nil }
        self.latitude = latitude
        self.longitude = longitude
        self.accuracy = accuracy
        self.timestamp = Date(timeIntervalSince1970: timestamp.timeIntervalSince1970.rounded(.down))
        self.battery = battery
        self.isCharging = isCharging
    }
}

/// Plaintext inside a location blob.
private struct LocationPayload: Codable {
    let lat: Double
    let lon: Double
    let acc: Double
    let t: Int64
    /// Battery percent and charging; optional so older records still decode.
    var bat: Int?
    var chg: Bool?
}

extension CircleCrypto {
    public static func sealLocation(_ location: SharedLocation, key: SymmetricKey, epoch: Int64, circleID: String, deviceID: String) throws -> Data {
        let payload = LocationPayload(
            lat: location.latitude, lon: location.longitude, acc: location.accuracy,
            t: Int64(location.timestamp.timeIntervalSince1970),
            bat: location.battery, chg: location.battery == nil ? nil : location.isCharging
        )
        return try sealContent(JSONEncoder().encode(payload), key: key, epoch: epoch, context: locationContext(circleID: circleID, deviceID: deviceID))
    }

    /// Returns nil when no key is known for the blob's epoch.
    public static func openLocation(
        _ blob: Data, circleID: String, deviceID: String, keyForEpoch: (Int64) -> SymmetricKey?
    ) throws -> (location: SharedLocation, epoch: Int64)? {
        guard let (plain, epoch) = try openContent(blob, context: locationContext(circleID: circleID, deviceID: deviceID), keyForEpoch: keyForEpoch)
        else { return nil }
        let p = try JSONDecoder().decode(LocationPayload.self, from: plain)
        guard let location = SharedLocation(
            latitude: p.lat, longitude: p.lon, accuracy: p.acc, timestamp: Date(timeIntervalSince1970: TimeInterval(p.t)),
            battery: p.bat, isCharging: p.chg ?? false
        ) else { throw ProtocolError.malformed }
        return (location, epoch)
    }

    /// Bytes a device signs for its own location record.
    public static func locationRecordStatement(circleID: String, deviceID: String, blob: Data) -> Data {
        Wire.context("leuchtturm/v1/location-record", circleID, deviceID) + blob
    }

    static func locationContext(circleID: String, deviceID: String) -> Data {
        Wire.context("leuchtturm/v1/location", circleID, deviceID)
    }
}
