import ActivityKit
import Foundation

/// Live Activity while driving or on the way somewhere.
struct TripActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// km/h, nil when not driving.
        var speed: Int?
        /// Already formatted, e.g. "12,4 km".
        var distance: String
        /// Arrival time for "Bin auf dem Weg".
        var eta: Date?
    }

    /// "Fahrt" or "Auf dem Weg zu Zuhause".
    var title: String
    var started: Date
}
