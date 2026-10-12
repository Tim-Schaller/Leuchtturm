import Foundation
import LeuchtturmCore

/// One's own finished trips, kept only on this device (without routes), for
/// the long-term driving statistics. iCloud keeps trips for 30 days only.
@MainActor
@Observable
final class TripArchive {
    private(set) var trips: [Trip] = []
    @ObservationIgnored private let fileURL: URL?

    /// Not persistent in the simulation.
    init(persistent: Bool) {
        fileURL = persistent ? URL.applicationSupportDirectory.appending(path: "trips.json") : nil
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let stored = try? JSONDecoder().decode([Stored].self, from: data) {
            trips = stored.map(\.trip)
        }
    }

    func add(_ trip: Trip) {
        guard !trips.contains(where: { $0.id == trip.id }) else { return }
        trips = Array((trips + [trip]).sorted { $0.end < $1.end }.suffix(20_000))
        save()
    }

    func clear() {
        trips = []
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    var stats: [DriveStats.Period: DriveStats] { DriveStats.summarize(trips) }

    private func save() {
        guard let fileURL, let data = try? JSONEncoder().encode(trips.map(Stored.init)) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// The numbers of a trip, without the route.
    private struct Stored: Codable {
        var id: String
        var start, end: Date
        var distance, topSpeed: Double
        var hardBrakes, rapidAccelerations: Int

        init(_ trip: Trip) {
            (id, start, end, distance, topSpeed) = (trip.id, trip.start, trip.end, trip.distance, trip.topSpeed)
            (hardBrakes, rapidAccelerations) = (trip.hardBrakes, trip.rapidAccelerations)
        }

        var trip: Trip {
            Trip(id: id, deviceID: "", start: start, end: end, distance: distance, topSpeed: topSpeed,
                 hardBrakes: hardBrakes, rapidAccelerations: rapidAccelerations, route: [])
        }
    }
}
