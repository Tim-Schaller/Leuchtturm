import CoreLocation
import Foundation
import LeuchtturmCore
import Observation
import WeatherKit

/// The own paths of all days, only on this device, for "Heute vor einem Jahr".
@MainActor
@Observable
final class MemoryArchive {
    private(set) var days: [String: [HistoryDay.Point]] = [:]
    @ObservationIgnored private let fileURL: URL?

    init(persistent: Bool) {
        fileURL = persistent ? URL.applicationSupportDirectory.appending(path: "memories.json") : nil
        if let fileURL, let data = try? Data(contentsOf: fileURL) {
            days = (try? JSONDecoder().decode([String: [HistoryDay.Point]].self, from: data)) ?? [:]
        }
    }

    /// Adds a point to today's path (at most 300 per day, thinned evenly).
    func add(_ point: HistoryDay.Point) {
        let key = HistoryDay.dayKey(for: point.timestamp)
        var points = days[key] ?? []
        if let last = points.last, point.timestamp.timeIntervalSince(last.timestamp) < 120 { return }
        points.append(point)
        if points.count > 300 { points = points.enumerated().filter { $0.offset % 2 == 0 }.map(\.element) }
        days[key] = points
        save()
    }

    func set(_ points: [HistoryDay.Point], on date: Date) {
        days[HistoryDay.dayKey(for: date)] = points
    }

    func clear() {
        days = [:]
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    /// The best memory for today: a year, a month or a week ago.
    func memory(for now: Date = Date()) -> (title: String, points: [HistoryDay.Point])? {
        let calendar = Calendar.current
        let candidates: [(DateComponents, String)] = [
            (DateComponents(year: -1), String(localized: "Heute vor einem Jahr")),
            (DateComponents(month: -1), String(localized: "Heute vor einem Monat")),
            (DateComponents(day: -7), String(localized: "Heute vor einer Woche")),
        ]
        for (offset, title) in candidates {
            guard let date = calendar.date(byAdding: offset, to: now), let points = days[HistoryDay.dayKey(for: date)], points.count >= 3
            else { continue }
            return (title, points)
        }
        return nil
    }

    private func save() {
        guard let fileURL, let data = try? JSONEncoder().encode(days) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// Current weather at people's places, rounded to about 1 km before asking
/// Apple Weather, cached for 30 minutes.
@MainActor
final class WeatherCache {
    struct Entry {
        let symbol: String
        let temperature: Measurement<UnitTemperature>
        let fetched: Date
    }

    private var entries: [String: Entry] = [:]
    private var loading: Set<String> = []
    private(set) var attribution: WeatherAttribution?

    func weather(at coordinate: CLLocationCoordinate2D) async -> Entry? {
        let lat = (coordinate.latitude * 100).rounded() / 100
        let lon = (coordinate.longitude * 100).rounded() / 100
        let key = "\(lat),\(lon)"
        if let entry = entries[key], Date().timeIntervalSince(entry.fetched) < 1800 { return entry }
        guard !loading.contains(key) else { return entries[key] }
        loading.insert(key)
        defer { loading.remove(key) }
        guard let current = try? await WeatherService.shared.weather(for: CLLocation(latitude: lat, longitude: lon), including: .current)
        else { return entries[key] }
        if attribution == nil { attribution = try? await WeatherService.shared.attribution }
        let entry = Entry(symbol: current.symbolName, temperature: current.temperature, fetched: Date())
        entries[key] = entry
        return entry
    }
}
