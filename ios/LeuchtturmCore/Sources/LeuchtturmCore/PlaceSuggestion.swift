import Foundation

/// A stay at one spot, as iOS reports it (CLVisit). Kept only on the device.
public struct Visit: Sendable, Hashable, Codable {
    public let latitude: Double
    public let longitude: Double
    public let arrival: Date
    public let departure: Date

    public init(latitude: Double, longitude: Double, arrival: Date, departure: Date) {
        self.latitude = latitude
        self.longitude = longitude
        self.arrival = arrival
        self.departure = departure
    }

    public var duration: TimeInterval { departure.timeIntervalSince(arrival) }
}

/// A spot you often stay at that is not a place yet.
public struct PlaceSuggestion: Sendable, Hashable, Identifiable {
    public var id: String { "\(latitude),\(longitude)" }
    public let latitude: Double
    public let longitude: Double
    public let visits: Int
    public let totalTime: TimeInterval

    /// Groups stays of 15 minutes or more that lie within 150 m of each
    /// other; suggests groups with at least two stays on different days
    /// that are not inside an existing place. Most visited first.
    public static func suggest(visits: [Visit], existing: [CirclePlace], calendar: Calendar, limit: Int = 3) -> [PlaceSuggestion] {
        struct Cluster {
            var latitude: Double
            var longitude: Double
            var members: [Visit]
        }
        var clusters: [Cluster] = []
        for visit in visits where visit.duration >= 15 * 60 {
            let probe = CirclePlace(id: "", creatorID: "", name: "x", emoji: "📍", latitude: visit.latitude, longitude: visit.longitude, radius: 150)!
            if let i = clusters.firstIndex(where: { probe.distance(toLatitude: $0.latitude, longitude: $0.longitude) <= 150 }) {
                clusters[i].members.append(visit)
                let n = Double(clusters[i].members.count)
                clusters[i].latitude += (visit.latitude - clusters[i].latitude) / n
                clusters[i].longitude += (visit.longitude - clusters[i].longitude) / n
            } else {
                clusters.append(Cluster(latitude: visit.latitude, longitude: visit.longitude, members: [visit]))
            }
        }
        return clusters
            .filter { cluster in
                let days = Set(cluster.members.map { calendar.startOfDay(for: $0.arrival) })
                let covered = existing.contains {
                    $0.distance(toLatitude: cluster.latitude, longitude: cluster.longitude) <= Double($0.radius) + 100
                }
                return days.count >= 2 && !covered
            }
            .map { PlaceSuggestion(
                latitude: $0.latitude, longitude: $0.longitude, visits: $0.members.count,
                totalTime: $0.members.reduce(0) { $0 + $1.duration }
            ) }
            .sorted { ($0.visits, $0.totalTime) > ($1.visits, $1.totalTime) }
            .prefix(limit)
            .map { $0 }
    }
}
