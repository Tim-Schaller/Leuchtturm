import CoreLocation
import LeuchtturmCore
import SwiftUI

/// What someone is up to, for rows, pins and the person's page: where or
/// what ("Bei Büro", "Fährt · 42 km/h") and how fresh ("seit 9:12 · 1,2 km").
/// Everything is worked out on this iPhone from the shared records; no
/// address lookup, so no position goes to a map service.
struct PersonStatus: Equatable {
    /// Where or what, if there is something to say.
    var headline: String?
    var symbol: String?
    /// Time and distance, or why there is no position.
    var detail: String
    /// The position is old (over an hour).
    var isStale = false
    /// Moving fast enough to call it driving.
    var isDriving = false
    /// "42 km/h" while driving, for the pin.
    var speed: String?

    /// Faster than about 22 km/h counts as driving, from 7 km/h as on the move.
    static let drivingSpeed = 6.0
    static let movingSpeed = 2.0

    @MainActor
    static func of(_ member: CircleMember, model: AppModel, now: Date = .now) -> PersonStatus {
        let details = model.latestCircle(model.circleOf(member.id) ?? "")
        return of(member, places: details?.places ?? [], notes: details?.notes ?? [], model: model, now: now)
    }

    @MainActor
    static func of(_ member: CircleMember, places: [CirclePlace], notes: [CircleNote], model: AppModel, now: Date = .now) -> PersonStatus {
        if member.isMe { return mine(places: places, notes: notes, model: model, now: now) }
        if member.isPending {
            return PersonStatus(detail: String(localized: "Wartet auf Bestätigung"))
        }
        guard let location = member.location else {
            return PersonStatus(detail: String(localized: "Teilt noch keinen Standort"))
        }
        let age = now.timeIntervalSince(location.timestamp)
        let fresh = age < 300
        var status = PersonStatus(detail: "", isStale: age > 3600)
        var parts: [String] = []

        if let journey = activeJourney(of: member.id, in: notes, now: now), let deadline = journey.deadline {
            let time = deadline.formatted(date: .omitted, time: .shortened)
            status.headline = journey.kind == .walkHome
                ? String(localized: "Heimweg zu \(journey.text) · bis \(time)")
                : String(localized: "Auf dem Weg zu \(journey.text) · ca. \(time)")
            status.symbol = journey.kind == .walkHome ? "house.and.flag.fill" : "figure.walk.motion"
        } else if location.fogRadius != nil {
            status.headline = String(localized: "Im Nebel")
            status.symbol = "cloud.fog.fill"
        } else if fresh, let speed = location.speed, speed >= drivingSpeed {
            status.headline = String(localized: "Fährt · \(Theme.speed(speed))")
            status.symbol = "car.fill"
            status.isDriving = true
            status.speed = Theme.speed(speed)
        } else if let place = place(containing: location, in: places) {
            status.headline = place.name
            status.symbol = "mappin"
            if let since = arrival(of: member.id, at: place, in: notes) {
                parts.append(sinceText(since, now: now))
            }
        } else if fresh, let speed = location.speed, speed >= movingSpeed {
            status.headline = String(localized: "Unterwegs")
            status.symbol = "figure.walk"
        }

        // How fresh: always when there is no "seit", else only when it is old,
        // and then clearly as the age of the position.
        if parts.isEmpty {
            parts.append(FreshnessText.text(for: location.timestamp, now: now))
        } else if age >= 300 {
            parts.append(String(localized: "aktualisiert \(FreshnessText.text(for: location.timestamp, now: now))"))
        }
        if location.fogRadius == nil, let distance = distance(to: location, from: model.tracker.location) {
            parts.append(distance)
        }
        status.detail = parts.joined(separator: " · ")
        return status
    }

    @MainActor
    private static func mine(places: [CirclePlace], notes: [CircleNote], model: AppModel, now: Date) -> PersonStatus {
        if !model.isSharingLocation {
            return PersonStatus(headline: String(localized: "Teilen pausiert"), symbol: "pause.circle.fill", detail: String(localized: "Die anderen sehen deinen letzten Standort"))
        }
        if let fog = model.activeFog {
            return PersonStatus(headline: String(localized: "Im Nebel"), symbol: "cloud.fog.fill",
                                detail: String(localized: "Nur ungefähr, bis \(fog.until.formatted(date: .omitted, time: .shortened))"))
        }
        if model.tracker.isDenied { return PersonStatus(detail: String(localized: "Standortzugriff ist aus")) }
        guard let here = model.tracker.location else { return PersonStatus(detail: String(localized: "Suche Standort …")) }
        var status = PersonStatus(detail: model.tracker.isAlwaysAllowed || model.isSimulation
            ? String(localized: "Wird geteilt")
            : String(localized: "Nur solange die App läuft"))
        if here.speed >= drivingSpeed {
            status.headline = String(localized: "Fährt · \(Theme.speed(here.speed))")
            status.symbol = "car.fill"
        } else if let shared = SharedLocation(here), let place = place(containing: shared, in: places) {
            status.headline = place.name
            status.symbol = "mappin"
            if let me = model.client?.deviceID, let since = arrival(of: me, at: place, in: notes) {
                status.detail = sinceText(since, now: now) + " · " + status.detail
            }
        }
        return status
    }

    /// The nearest place whose circle the position is in.
    static func place(containing location: SharedLocation, in places: [CirclePlace]) -> CirclePlace? {
        place(atLatitude: location.latitude, longitude: location.longitude, in: places)
    }

    static func place(atLatitude latitude: Double, longitude: Double, in places: [CirclePlace]) -> CirclePlace? {
        places
            .map { ($0, $0.distance(toLatitude: latitude, longitude: longitude)) }
            .filter { $0.1 <= Double($0.0.radius) }
            .min { $0.1 < $1.1 }?.0
    }

    /// When the member last arrived at the place, if they have not left since.
    static func arrival(of memberID: String, at place: CirclePlace, in notes: [CircleNote]) -> Date? {
        let theirs = notes.filter { $0.senderID == memberID && $0.text == place.name }
        guard let arrived = theirs.filter({ $0.kind == .arrival }).map(\.timestamp).max() else { return nil }
        let left = theirs.filter { $0.kind == .departure }.map(\.timestamp).max()
        return left.map { $0 > arrived } == true ? nil : arrived
    }

    /// "seit 9:12", or with the day when it was not today.
    static func sinceText(_ date: Date, now: Date = .now) -> String {
        let time = Calendar.current.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        return String(localized: "seit \(time)")
    }

    static func distance(to location: SharedLocation, from me: CLLocation?) -> String? {
        guard let me else { return nil }
        let meters = me.distance(from: location.clLocation)
        return Measurement(value: meters, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road))
    }
}
