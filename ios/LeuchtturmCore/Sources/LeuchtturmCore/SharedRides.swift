import Foundation

/// Trips of several members that were the same drive: at the same time on
/// the same road. Each device detects its own trip; this puts them together
/// and works out who drove, so a car of four counts once.
public struct SharedRide: Sendable, Hashable, Identifiable {
    /// Oldest first; usually one per device.
    public let trips: [Trip]

    public var id: String { trips.map(\.id).sorted().joined(separator: "+") }
    public var devices: [String] { trips.map(\.deviceID).reduce(into: []) { if !$0.contains($1) { $0.append($1) } } }
    public var isShared: Bool { devices.count > 1 }

    public enum Certainty: Sendable, Hashable {
        /// Someone said so.
        case confirmed
        /// CarPlay or a known car, or everyone else rode along.
        case likely
    }

    public struct Driver: Sendable, Hashable {
        public let deviceID: String
        public let certainty: Certainty
        public let reason: Trip.Reason?
        public let carName: String?
    }

    /// Who drove, if the trips tell; nil when nobody knows or answers disagree.
    public var driver: Driver? {
        let devices = Set(devices)
        // Answers first: "I drove", or a passenger naming the driver.
        let said = Set(trips.filter { $0.role == .driver && $0.reason == .confirmed }.map(\.deviceID))
        let named = Set(trips.filter { $0.isPassenger && $0.reason == .confirmed }.compactMap(\.driverID).filter(devices.contains))
        let answers = said.union(named)
        if answers.count == 1, let id = answers.first {
            return Driver(deviceID: id, certainty: .confirmed, reason: .confirmed, carName: nil)
        }
        guard answers.isEmpty else { return nil }
        // Then guesses: connected to CarPlay or to one of „Meine Autos“.
        let guesses = trips.filter { $0.role == .driver && $0.reason != .confirmed }
        if Set(guesses.map(\.deviceID)).count == 1, let guess = guesses.first {
            return Driver(deviceID: guess.deviceID, certainty: .likely, reason: guess.reason, carName: guess.carName)
        }
        guard guesses.isEmpty else { return nil }
        // Everyone else rode along.
        let others = devices.subtracting(trips.filter(\.isPassenger).map(\.deviceID))
        if self.devices.count > 1, others.count == 1, let id = others.first {
            return Driver(deviceID: id, certainty: .likely, reason: nil, carName: nil)
        }
        return nil
    }

    /// The trips that count for the leaderboard: only the driver's, else all
    /// but the passengers'.
    public var counted: [Trip] {
        if isShared, let driver { return trips.filter { $0.deviceID == driver.deviceID } }
        return trips.filter { !$0.isPassenger }
    }

    /// Every trip in exactly one ride, newest first.
    public static func group(_ trips: [Trip]) -> [SharedRide] {
        let trips = trips.sorted { $0.start < $1.start }
        var parent = Array(trips.indices)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { i = parent[i] }
            return i
        }
        for i in trips.indices {
            for j in trips.indices where j > i {
                // Sorted by start: later trips cannot overlap once this one ended.
                if trips[j].start > trips[i].end { break }
                if together(trips[i], trips[j]) { parent[root(j)] = root(i) }
            }
        }
        return Dictionary(grouping: trips.indices, by: root).values
            .map { SharedRide(trips: $0.map { trips[$0] }) }
            .sorted { ($0.trips.first?.start ?? .distantPast) > ($1.trips.first?.start ?? .distantPast) }
    }

    /// The trips that count, over all rides.
    public static func counted(_ trips: [Trip]) -> [Trip] {
        group(trips).flatMap(\.counted)
    }

    /// Same time (most of the shorter trip) and same place (within about
    /// 300 m at the same moments).
    static func together(_ a: Trip, _ b: Trip) -> Bool {
        guard a.deviceID != b.deviceID else { return false }
        let from = max(a.start, b.start), to = min(a.end, b.end)
        let overlap = to.timeIntervalSince(from)
        guard overlap >= 0.6 * max(min(a.duration, b.duration), 60) else { return false }
        var distances: [Double] = []
        for k in 0 ..< 9 {
            let time = from.addingTimeInterval(overlap * Double(k) / 8)
            if let p = position(a, at: time), let q = position(b, at: time) {
                distances.append(TripDetector.meters(p.latitude, p.longitude, q.latitude, q.longitude))
            }
        }
        guard distances.count >= 3 else { return false }
        return distances.sorted()[distances.count / 2] <= 300
    }

    /// Where the trip was at `time`, between its route points.
    static func position(_ trip: Trip, at time: Date) -> (latitude: Double, longitude: Double)? {
        let route = trip.route
        guard let first = route.first, let last = route.last else { return nil }
        if time <= first.timestamp { return (first.latitude, first.longitude) }
        if time >= last.timestamp { return (last.latitude, last.longitude) }
        guard let i = route.firstIndex(where: { $0.timestamp >= time }), i > 0 else { return (first.latitude, first.longitude) }
        let (p, q) = (route[i - 1], route[i])
        let span = q.timestamp.timeIntervalSince(p.timestamp)
        let t = span > 0 ? time.timeIntervalSince(p.timestamp) / span : 0
        return (p.latitude + (q.latitude - p.latitude) * t, p.longitude + (q.longitude - p.longitude) * t)
    }
}
