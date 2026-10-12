import CoreLocation
import LeuchtturmCore
import MapKit
import SwiftUI

/// A path split into runs of similar speed, each drawn in its own colour:
/// green on foot, yellow in town, orange on country roads, red on the
/// motorway, purple above 200 km/h. Gaps of more than 15 minutes are left
/// out instead of drawing a straight line across them.
struct SpeedPath {
    struct Run {
        let coordinates: [CLLocationCoordinate2D]
        let color: Color
    }

    let runs: [Run]

    init(_ points: [HistoryDay.Point]) {
        var runs: [Run] = []
        var current: [CLLocationCoordinate2D] = []
        var currentBucket: Int?
        for (a, b) in zip(points, points.dropFirst()) {
            let seconds = b.timestamp.timeIntervalSince(a.timestamp)
            let from = CLLocation(latitude: a.latitude, longitude: a.longitude)
            let to = CLLocation(latitude: b.latitude, longitude: b.longitude)
            guard seconds > 0, seconds <= 15 * 60 else {
                if current.count > 1, let bucket = currentBucket { runs.append(Run(coordinates: current, color: Self.color(bucket: bucket))) }
                current = []
                currentBucket = nil
                continue
            }
            let kmh = to.distance(from: from) / seconds * 3.6
            let bucket = min(Int(kmh / 10), 25)
            if bucket != currentBucket {
                if current.count > 1, let previous = currentBucket {
                    runs.append(Run(coordinates: current, color: Self.color(bucket: previous)))
                }
                current = [a.coordinate]
                currentBucket = bucket
            }
            current.append(b.coordinate)
        }
        if current.count > 1, let bucket = currentBucket { runs.append(Run(coordinates: current, color: Self.color(bucket: bucket))) }
        self.runs = runs
    }

    /// Colour stops in km/h.
    static let stops: [(kmh: Double, red: Double, green: Double, blue: Double)] = [
        (0, 0.18, 0.62, 0.40), (30, 0.95, 0.78, 0.18), (80, 0.96, 0.52, 0.14), (130, 0.88, 0.20, 0.22), (200, 0.56, 0.22, 0.78),
    ]

    static func color(kmh: Double) -> Color {
        guard let upper = stops.firstIndex(where: { $0.kmh >= kmh }) else {
            let last = stops[stops.count - 1]
            return Color(red: last.red, green: last.green, blue: last.blue)
        }
        guard upper > 0 else { return Color(red: stops[0].red, green: stops[0].green, blue: stops[0].blue) }
        let (a, b) = (stops[upper - 1], stops[upper])
        let t = (kmh - a.kmh) / (b.kmh - a.kmh)
        return Color(red: a.red + (b.red - a.red) * t, green: a.green + (b.green - a.green) * t, blue: a.blue + (b.blue - a.blue) * t)
    }

    static func color(bucket: Int) -> Color {
        color(kmh: Double(bucket) * 10 + 5)
    }
}

/// The path on a map, coloured by speed.
struct SpeedPathContent: MapContent {
    let path: SpeedPath

    var body: some MapContent {
        ForEach(Array(path.runs.enumerated()), id: \.offset) { _, run in
            MapPolyline(coordinates: run.coordinates)
                .stroke(run.color, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
        }
    }
}

/// Which colour means which speed.
struct SpeedLegend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LinearGradient(
                stops: SpeedPath.stops.map { .init(color: SpeedPath.color(kmh: $0.kmh), location: $0.kmh / 200) },
                startPoint: .leading, endPoint: .trailing
            )
            .frame(height: 8)
            .clipShape(.capsule)
            HStack {
                Text("zu Fuß")
                Spacer()
                Text(Theme.speed(30 / 3.6))
                Spacer()
                Text(Theme.speed(80 / 3.6))
                Spacer()
                Text(Theme.speed(130 / 3.6))
                Spacer()
                Text(Theme.speed(200 / 3.6) + "+")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Farben nach Tempo: grün zu Fuß, gelb in der Stadt, orange auf der Landstraße, rot auf der Autobahn, lila über 200 km/h")
    }
}
