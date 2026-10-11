import Foundation
import LeuchtturmCore

/// Today's path on this device, kept in a file (protected like the
/// keychain items: readable after first unlock) and uploaded with the
/// location while history sharing is on.
@MainActor
final class HistoryRecorder {
    private struct Stored: Codable {
        let day: String
        let points: [HistoryDay.Point]
    }

    private var stored: Stored?
    private let fileURL: URL?

    /// Not persistent in the simulation.
    init(persistent: Bool) {
        fileURL = persistent
            ? URL.applicationSupportDirectory.appending(path: "history-today.json")
            : nil
        if let fileURL, let data = try? Data(contentsOf: fileURL) {
            stored = try? JSONDecoder().decode(Stored.self, from: data)
        }
    }

    /// Adds a point if it is far or long enough from the last one and
    /// returns today's path.
    func add(latitude: Double, longitude: Double, at time: Date, deviceID: String) -> HistoryDay {
        let day = HistoryDay.dayKey(for: time)
        var points = stored?.day == day ? stored?.points ?? [] : []
        let point = HistoryDay.Point(latitude: latitude, longitude: longitude, timestamp: time)
        if let last = points.last {
            let meters = hypot((latitude - last.latitude) * 111_320, (longitude - last.longitude) * 111_320 * cos(latitude * .pi / 180))
            if meters >= 40 || time.timeIntervalSince(last.timestamp) >= 300 { points.append(point) }
        } else {
            points.append(point)
        }
        stored = Stored(day: day, points: Array(points.suffix(HistoryDay.maxPoints)))
        save()
        return HistoryDay(deviceID: deviceID, day: day, points: stored?.points ?? [])
    }

    func clear() {
        stored = nil
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    private func save() {
        guard let fileURL, let data = try? JSONEncoder().encode(stored) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
