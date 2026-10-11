import Foundation

/// "Tell me if Ben is not at school by 8:15." Stays on the device that set
/// it: the app schedules a local notification for each deadline and
/// withdraws it once the member is known to have arrived.
public struct ArrivalWatch: Sendable, Hashable, Codable, Identifiable {
    public enum Repeat: String, Sendable, Codable, CaseIterable {
        case once
        case weekdays
        case daily
    }

    public let id: String
    public let circleID: String
    public let memberID: String
    public let placeID: String
    public let hour: Int
    public let minute: Int
    public let repeats: Repeat
    /// For `once`: the day it is for (its deadline may already be past).
    public let created: Date

    public init(id: String, circleID: String, memberID: String, placeID: String, hour: Int, minute: Int, repeats: Repeat, created: Date) {
        self.id = id
        self.circleID = circleID
        self.memberID = memberID
        self.placeID = placeID
        self.hour = hour
        self.minute = minute
        self.repeats = repeats
        self.created = created
    }

    /// Deadlines from `now` on within `days` days, in `calendar`'s time zone.
    public func deadlines(after now: Date, days: Int, calendar: Calendar) -> [Date] {
        let startOfToday = calendar.startOfDay(for: now)
        var out: [Date] = []
        for offset in 0 ..< days {
            guard let day = calendar.date(byAdding: .day, value: offset, to: startOfToday),
                  let deadline = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
                  deadline > now
            else { continue }
            switch repeats {
            case .once:
                // The first deadline after it was set, then never again.
                if let first = Self.firstDeadline(of: self, calendar: calendar), first == deadline { out.append(deadline) }
            case .weekdays:
                // Monday to Friday (Gregorian weekday 1 is Sunday, 7 Saturday).
                let weekday = calendar.component(.weekday, from: day)
                if weekday != 1 && weekday != 7 { out.append(deadline) }
            case .daily:
                out.append(deadline)
            }
        }
        return out
    }

    private static func firstDeadline(of watch: ArrivalWatch, calendar: Calendar) -> Date? {
        let day = calendar.startOfDay(for: watch.created)
        guard let sameDay = calendar.date(bySettingHour: watch.hour, minute: watch.minute, second: 0, of: day) else { return nil }
        if sameDay > watch.created { return sameDay }
        return calendar.date(byAdding: .day, value: 1, to: sameDay)
    }

    /// The member has arrived for the deadline on `deadline`'s day: they are
    /// inside the place now, or sent an arrival there since the day began.
    public func isSatisfied(
        deadline: Date, place: CirclePlace, location: SharedLocation?, notes: [CircleNote], calendar: Calendar
    ) -> Bool {
        let dayStart = calendar.startOfDay(for: deadline)
        if let location, location.fogRadius == nil, location.timestamp >= dayStart,
           place.distance(toLatitude: location.latitude, longitude: location.longitude) <= Double(place.radius) {
            return true
        }
        return notes.contains {
            $0.senderID == memberID && $0.kind == .arrival && $0.text == place.name && $0.timestamp >= dayStart && $0.timestamp <= deadline
        }
    }
}
