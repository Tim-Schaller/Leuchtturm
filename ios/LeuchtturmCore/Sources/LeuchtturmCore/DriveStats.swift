import Foundation

/// Driving totals for one period, computed on the driver's own device from
/// a local archive of their trips. Only these sums go to the circles (inside
/// the encrypted profile); trips themselves stay in iCloud for 30 days.
public struct DriveStats: Sendable, Hashable, Codable {
    public enum Period: String, Sendable, CaseIterable, Codable, Identifiable {
        case week, month, year, all
        public var id: String { rawValue }

        /// Start of the period, or nil for "all time".
        public func start(before now: Date) -> Date? {
            switch self {
            case .week: now.addingTimeInterval(-7 * 86400)
            case .month: now.addingTimeInterval(-30 * 86400)
            case .year: now.addingTimeInterval(-365 * 86400)
            case .all: nil
            }
        }
    }

    public var trips: Int
    /// Meters.
    public var distance: Double
    /// Seconds.
    public var duration: Double
    /// m/s.
    public var topSpeed: Double
    public var hardBrakes: Int
    public var rapidAccelerations: Int
    /// Distance-weighted average of the trip scores, nil without trips.
    public var score: Int?

    public static let empty = DriveStats(trips: 0, distance: 0, duration: 0, topSpeed: 0, hardBrakes: 0, rapidAccelerations: 0, score: nil)

    public init(trips: Int, distance: Double, duration: Double, topSpeed: Double, hardBrakes: Int, rapidAccelerations: Int, score: Int?) {
        self.trips = trips
        self.distance = distance
        self.duration = duration
        self.topSpeed = topSpeed
        self.hardBrakes = hardBrakes
        self.rapidAccelerations = rapidAccelerations
        self.score = score
    }

    public init(_ trips: [Trip]) {
        let distance = trips.reduce(0) { $0 + $1.distance }
        let weighted = trips.reduce(0.0) { $0 + Double($1.score) * max(1, $1.distance) }
        let weight = trips.reduce(0.0) { $0 + max(1, $1.distance) }
        self.init(
            trips: trips.count,
            distance: distance,
            duration: trips.reduce(0) { $0 + $1.duration },
            topSpeed: trips.map(\.topSpeed).max() ?? 0,
            hardBrakes: trips.reduce(0) { $0 + $1.hardBrakes },
            rapidAccelerations: trips.reduce(0) { $0 + $1.rapidAccelerations },
            score: trips.isEmpty ? nil : Int((weighted / weight).rounded())
        )
    }

    /// Totals for every period.
    public static func summarize(_ trips: [Trip], now: Date = Date()) -> [Period: DriveStats] {
        Dictionary(uniqueKeysWithValues: Period.allCases.map { period in
            let since = period.start(before: now)
            // Rides as a passenger do not count.
            return (period, DriveStats(trips.filter { !$0.isPassenger && (since == nil || $0.end >= since!) }))
        })
    }

    /// False for numbers no real driver reaches (a forged or broken record).
    var isPlausible: Bool {
        (0 ... 1_000_000).contains(trips) && distance.isFinite && (0 ... 1e10).contains(distance)
            && duration.isFinite && (0 ... 1e10).contains(duration) && topSpeed.isFinite && (0 ... 150).contains(topSpeed)
            && (0 ... 10_000_000).contains(hardBrakes) && (0 ... 10_000_000).contains(rapidAccelerations)
            && (score.map { (0 ... 100).contains($0) } ?? true)
    }
}
