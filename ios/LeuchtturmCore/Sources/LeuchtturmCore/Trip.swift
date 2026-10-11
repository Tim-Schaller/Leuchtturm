#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// A drive, detected on the driver's own device. Shared only if the
/// member turned trip sharing on; encrypted and signed like history.
public struct Trip: Sendable, Hashable, Identifiable {
    public let id: String
    public let deviceID: String
    public let start: Date
    public let end: Date
    /// Meters.
    public let distance: Double
    /// Meters per second.
    public let topSpeed: Double
    public let hardBrakes: Int
    public let rapidAccelerations: Int
    /// At most `maxRoutePoints`.
    public let route: [HistoryDay.Point]

    public static let maxRoutePoints = 300
    /// Above this (130 km/h) a trip loses points.
    public static let speedingLimit = 36.1

    public init(
        id: String, deviceID: String, start: Date, end: Date, distance: Double, topSpeed: Double,
        hardBrakes: Int, rapidAccelerations: Int, route: [HistoryDay.Point]
    ) {
        self.id = id
        self.deviceID = deviceID
        self.start = Date(timeIntervalSince1970: start.timeIntervalSince1970.rounded(.down))
        self.end = Date(timeIntervalSince1970: end.timeIntervalSince1970.rounded(.down))
        self.distance = distance
        self.topSpeed = topSpeed
        self.hardBrakes = hardBrakes
        self.rapidAccelerations = rapidAccelerations
        self.route = Array(route.prefix(Self.maxRoutePoints))
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }

    /// 0 to 100: fewer hard brakes, rapid accelerations and no speeding is better.
    public var score: Int {
        max(0, 100 - 8 * hardBrakes - 5 * rapidAccelerations - (topSpeed > Self.speedingLimit ? 10 : 0))
    }
}

/// Detects drives from location samples: a trip starts after two fast
/// samples (25 km/h and more) and ends after three minutes without one.
/// Short hops (under 1 km or 2 minutes) are dropped.
public struct TripDetector: Sendable, Codable, Equatable {
    private struct Running: Codable, Equatable {
        var start: Date
        var lastFast: Date
        var lastTime: Date
        var lastSpeed: Double
        var lastLatitude: Double
        var lastLongitude: Double
        var distance: Double
        var topSpeed: Double
        var hardBrakes: Int
        var rapidAccelerations: Int
        var lastEvent: Date
        var route: [HistoryDay.Point]
    }

    static let startSpeed = 7.0
    static let movingSpeed = 4.0
    static let endAfter: TimeInterval = 180
    static let hardBrake = -3.5
    static let rapidAcceleration = 3.0

    private var running: Running?
    private var pendingFast: Date?
    private var crash: Date?

    public init() {}

    public var isDriving: Bool { running != nil }

    /// When a possible crash was seen (and forgets it): from 40 km/h or
    /// more to standstill in about a second, far beyond braking.
    public mutating func takeCrash() -> Date? {
        defer { crash = nil }
        return crash
    }

    static let crashFromSpeed = 11.0
    static let crashDeceleration = 12.0

    /// Feeds one sample. Returns a trip when one just ended. `speed` is in
    /// m/s; pass a negative value if unknown.
    public mutating func update(latitude: Double, longitude: Double, speed: Double, at time: Date, deviceID: String) -> Trip? {
        var finished: Trip?
        if let r = running, time.timeIntervalSince(r.lastFast) > Self.endAfter {
            finished = finish(deviceID: deviceID)
        }
        guard var r = running else {
            if speed >= Self.startSpeed {
                if let first = pendingFast, time.timeIntervalSince(first) <= 60 {
                    running = Running(
                        start: first, lastFast: time, lastTime: time, lastSpeed: speed, lastLatitude: latitude,
                        lastLongitude: longitude, distance: 0, topSpeed: speed, hardBrakes: 0, rapidAccelerations: 0,
                        lastEvent: .distantPast, route: [HistoryDay.Point(latitude: latitude, longitude: longitude, timestamp: time)]
                    )
                    pendingFast = nil
                } else {
                    pendingFast = time
                }
            } else {
                pendingFast = nil
            }
            return finished
        }

        let dt = time.timeIntervalSince(r.lastTime)
        guard dt > 0 else { return finished }
        let step = Self.meters(r.lastLatitude, r.lastLongitude, latitude, longitude)
        let speed = speed >= 0 ? speed : step / dt
        r.distance += step
        r.topSpeed = max(r.topSpeed, speed)
        if dt <= 1.5, r.lastSpeed >= Self.crashFromSpeed, speed <= 1.5, (r.lastSpeed - speed) / dt >= Self.crashDeceleration {
            crash = time
        }
        if dt <= 10, time.timeIntervalSince(r.lastEvent) >= 10 {
            let acceleration = (speed - r.lastSpeed) / dt
            if acceleration <= Self.hardBrake {
                r.hardBrakes += 1
                r.lastEvent = time
            } else if acceleration >= Self.rapidAcceleration {
                r.rapidAccelerations += 1
                r.lastEvent = time
            }
        }
        if speed >= Self.movingSpeed { r.lastFast = time }
        if let last = r.route.last,
           Self.meters(last.latitude, last.longitude, latitude, longitude) >= 100 || time.timeIntervalSince(last.timestamp) >= 30 {
            r.route.append(HistoryDay.Point(latitude: latitude, longitude: longitude, timestamp: time))
        }
        r.lastTime = time
        r.lastSpeed = speed
        r.lastLatitude = latitude
        r.lastLongitude = longitude
        running = r
        return finished
    }

    /// Ends a trip whose last fast sample is too long ago, e.g. because
    /// iOS paused location updates after parking.
    public mutating func finishIfStale(now: Date, deviceID: String) -> Trip? {
        guard let r = running, now.timeIntervalSince(r.lastFast) > Self.endAfter else { return nil }
        return finish(deviceID: deviceID)
    }

    private mutating func finish(deviceID: String) -> Trip? {
        guard let r = running else { return nil }
        running = nil
        let end = r.lastFast
        guard r.distance >= 1000, end.timeIntervalSince(r.start) >= 120 else { return nil }
        // Keep the route within the limit by thinning it evenly.
        let route = r.route.filter { $0.timestamp <= end }
        let stride = max(1, Int((Double(route.count) / Double(Trip.maxRoutePoints)).rounded(.up)))
        let thinned = route.enumerated().filter { $0.offset % stride == 0 || $0.offset == route.count - 1 }.map(\.element)
        return Trip(
            id: CircleCrypto.newCircleID(), deviceID: deviceID, start: r.start, end: end, distance: r.distance,
            topSpeed: r.topSpeed, hardBrakes: r.hardBrakes, rapidAccelerations: r.rapidAccelerations, route: thinned
        )
    }

    static func meters(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let dLat = (lat2 - lat1) * 111_320
        let dLon = (lon2 - lon1) * 111_320 * cos((lat1 + lat2) / 2 * .pi / 180)
        return (dLat * dLat + dLon * dLon).squareRoot()
    }
}

/// One member's driving in a period, for the circle's leaderboard.
public struct DriverStats: Sendable, Hashable, Identifiable {
    public var id: String { deviceID }
    public let deviceID: String
    public let trips: Int
    /// Meters.
    public let distance: Double
    public let topSpeed: Double
    public let hardBrakes: Int
    public let rapidAccelerations: Int
    /// Distance-weighted average of the trip scores.
    public let score: Int

    /// Best score first; on a tie, more distance first.
    public static func leaderboard(_ trips: [Trip]) -> [DriverStats] {
        Dictionary(grouping: trips, by: \.deviceID).map { deviceID, trips in
            let distance = trips.reduce(0) { $0 + $1.distance }
            let weighted = trips.reduce(0.0) { $0 + Double($1.score) * max($1.distance, 1) }
            return DriverStats(
                deviceID: deviceID, trips: trips.count, distance: distance,
                topSpeed: trips.map(\.topSpeed).max() ?? 0,
                hardBrakes: trips.reduce(0) { $0 + $1.hardBrakes },
                rapidAccelerations: trips.reduce(0) { $0 + $1.rapidAccelerations },
                score: Int((weighted / max(trips.reduce(0.0) { $0 + max($1.distance, 1) }, 1)).rounded())
            )
        }
        .sorted { ($0.score, $0.distance) > ($1.score, $1.distance) }
    }
}

private struct TripPayload: Codable {
    let s: Double
    let e: Double
    let d: Double
    let v: Double
    let hb: Int
    let ra: Int
    let p: [[Double]]
}

extension CircleCrypto {
    static func sealTrip(_ trip: Trip, key: SymmetricKey, epoch: Int64, circleID: String) throws -> Data {
        let payload = TripPayload(
            s: trip.start.timeIntervalSince1970, e: trip.end.timeIntervalSince1970, d: trip.distance.rounded(),
            v: (trip.topSpeed * 10).rounded() / 10, hb: trip.hardBrakes, ra: trip.rapidAccelerations,
            p: trip.route.map { [($0.latitude * 1e6).rounded() / 1e6, ($0.longitude * 1e6).rounded() / 1e6, $0.timestamp.timeIntervalSince1970] }
        )
        return try sealContent(JSONEncoder().encode(payload), key: key, epoch: epoch, context: tripContext(circleID: circleID, tripID: trip.id))
    }

    static func openTrip(
        _ blob: Data, id: String, deviceID: String, circleID: String, keyForEpoch: (Int64) -> SymmetricKey?
    ) throws -> Trip? {
        guard let (plain, _) = try openContent(blob, context: tripContext(circleID: circleID, tripID: id), keyForEpoch: keyForEpoch)
        else { return nil }
        let p = try JSONDecoder().decode(TripPayload.self, from: plain)
        guard p.s > 0, p.e >= p.s, p.d >= 0, p.v >= 0, p.v < 150, p.hb >= 0, p.ra >= 0, p.p.count <= Trip.maxRoutePoints
        else { throw ProtocolError.malformed }
        let route = try p.p.map { t -> HistoryDay.Point in
            guard t.count == 3, (-90 ... 90).contains(t[0]), (-180 ... 180).contains(t[1]) else { throw ProtocolError.malformed }
            return HistoryDay.Point(latitude: t[0], longitude: t[1], timestamp: Date(timeIntervalSince1970: t[2]))
        }
        return Trip(
            id: id, deviceID: deviceID, start: Date(timeIntervalSince1970: p.s), end: Date(timeIntervalSince1970: p.e),
            distance: p.d, topSpeed: p.v, hardBrakes: p.hb, rapidAccelerations: p.ra, route: route
        )
    }

    static func tripRecordStatement(circleID: String, tripID: String, deviceID: String, blob: Data) -> Data {
        Wire.context("leuchtturm/v1/trip-record", circleID, tripID, deviceID) + blob
    }

    static func tripContext(circleID: String, tripID: String) -> Data {
        Wire.context("leuchtturm/v1/trip", circleID, tripID)
    }
}
