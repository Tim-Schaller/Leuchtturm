import ActivityKit
import AppIntents
import CoreLocation
import LeuchtturmCore
import UIKit
import WidgetKit

// MARK: Widgets

extension AppModel {
    /// Writes what the widgets show for this circle and reloads them (at most once a minute).
    func updateWidgets(with details: CircleDetails) {
        let people = details.members.filter { !$0.isMe && !$0.isPending }.map { member -> WidgetSnapshot.Person in
            let profile = member.profile
            var place = String(localized: "teilt keinen Standort")
            if let location = member.location {
                if let here = details.places.first(where: { $0.distance(toLatitude: location.latitude, longitude: location.longitude) <= Double($0.radius) }),
                   location.fogRadius == nil {
                    place = here.name
                } else if let speed = location.speed, speed >= 2 {
                    place = String(localized: "unterwegs · \(Theme.speed(speed))")
                } else if location.fogRadius != nil {
                    place = String(localized: "im Nebel")
                } else {
                    place = location.timestamp.formatted(.relative(presentation: .named))
                }
            }
            let status = profile?.status(at: Date()).map { [$0.emoji, $0.text].compactMap { $0 }.joined(separator: " ") }
            let initials = (member.name ?? "?").split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
            return WidgetSnapshot.Person(
                id: member.id, name: member.name ?? String(localized: "Unbekannt"), initials: initials,
                colorHex: profile?.color ?? Theme.color(for: member.id).hex, emoji: profile?.emoji, status: status, place: place,
                battery: member.location?.battery, updated: member.location?.timestamp,
                photo: profile?.photo.flatMap { UIImage(data: $0) }.flatMap { ProfileEditor.compress($0, side: 64, maxBytes: 12_000, square: true) }
            )
        }
        WidgetSnapshot(circleName: details.name ?? String(localized: "Leuchtturm"), people: people, written: Date()).save()
        if Date().timeIntervalSince(lastWidgetReload) > 60 {
            lastWidgetReload = Date()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    // MARK: Live Activity

    /// Keeps the Live Activity in step with a drive or "Bin auf dem Weg".
    func updateLiveActivity(location: CLLocation, driving: Bool) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let title: String
        var eta: Date?
        var distance: String
        if let journey {
            title = String(localized: "Auf dem Weg zu \(journey.destination)")
            eta = journey.isWalkHome ? nil : journey.deadline
            distance = WeekView.km(location.distance(from: CLLocation(latitude: journey.latitude, longitude: journey.longitude)))
        } else if driving {
            title = String(localized: "Fahrt")
            if let last = lastActivityLocation { activityDistance += location.distance(from: last) }
            lastActivityLocation = location
            distance = WeekView.km(activityDistance)
        } else {
            endLiveActivity()
            return
        }
        let state = TripActivityAttributes.ContentState(
            speed: driving && location.speed >= 0 ? Int((location.speed * 3.6).rounded()) : nil, distance: distance, eta: eta
        )
        if !Activity<TripActivityAttributes>.activities.isEmpty {
            Task {
                for activity in Activity<TripActivityAttributes>.activities {
                    await activity.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(300)))
                }
            }
        } else {
            activityDistance = 0
            _ = try? Activity.request(
                attributes: TripActivityAttributes(title: title, started: Date()),
                content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(300))
            )
        }
    }

    func endLiveActivity() {
        lastActivityLocation = nil
        activityDistance = 0
        guard !Activity<TripActivityAttributes>.activities.isEmpty else { return }
        Task {
            for activity in Activity<TripActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .default)
            }
        }
    }
}

// MARK: Siri and Shortcuts

struct PersonEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Person"
    static let defaultQuery = PersonQuery()
    let id: String
    let name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct PersonQuery: EntityQuery, EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [PersonEntity] {
        (WidgetSnapshot.load()?.people ?? []).filter { identifiers.contains($0.id) }.map { PersonEntity(id: $0.id, name: $0.name) }
    }

    func entities(matching string: String) async throws -> [PersonEntity] {
        (WidgetSnapshot.load()?.people ?? []).filter { $0.name.localizedCaseInsensitiveContains(string) }.map { PersonEntity(id: $0.id, name: $0.name) }
    }

    func suggestedEntities() async throws -> [PersonEntity] {
        (WidgetSnapshot.load()?.people ?? []).map { PersonEntity(id: $0.id, name: $0.name) }
    }
}

struct WhereIsIntent: AppIntent {
    static let title: LocalizedStringResource = "Wo ist …?"
    static let description = IntentDescription("Sagt, wo jemand aus deinem Leuchtturm gerade ist.")
    @Parameter(title: "Person") var person: PersonEntity

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let entry = WidgetSnapshot.load()?.people.first(where: { $0.id == person.id }) else {
            return .result(dialog: "Das weiß ich gerade nicht. Öffne Leuchtturm einmal.")
        }
        let battery = entry.battery.map { String(localized: ", Akku \($0) %") } ?? ""
        return .result(dialog: "\(entry.name): \(entry.place)\(battery).")
    }
}

struct FogIntent: AppIntent {
    static let title: LocalizedStringResource = "Nebel einschalten"
    static let description = IntentDescription("Teilt für eine Weile nur die ungefähre Gegend.")
    @Parameter(title: "Stunden", default: 1) var hours: Int

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let model = AppModel.current else { return .result(dialog: "Öffne Leuchtturm einmal.") }
        await model.startFog(radius: 1000, hours: Double(max(1, min(hours, 8))))
        return .result(dialog: "Nebel ist an.")
    }
}

struct CheckInIntent: AppIntent {
    static let title: LocalizedStringResource = "Einchecken"
    static let description = IntentDescription("Sagt deinem Leuchtturm, wo du gerade bist.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let model = AppModel.current, let ref = model.circles.first?.ref else { return .result(dialog: "Öffne Leuchtturm einmal.") }
        let ok = await model.send(.checkIn, in: ref)
        return .result(dialog: ok ? "Eingecheckt." : "Das hat nicht geklappt.")
    }
}

struct LeuchtturmShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: WhereIsIntent(), phrases: ["Wo ist \(\.$person) in \(.applicationName)", "\(.applicationName) wo ist \(\.$person)"],
                    shortTitle: "Wo ist …?", systemImageName: "location.magnifyingglass")
        AppShortcut(intent: FogIntent(), phrases: ["Nebel in \(.applicationName)", "\(.applicationName) Nebel einschalten"],
                    shortTitle: "Nebel", systemImageName: "circle.dashed")
        AppShortcut(intent: CheckInIntent(), phrases: ["Bei \(.applicationName) einchecken", "\(.applicationName) einchecken"],
                    shortTitle: "Einchecken", systemImageName: "mappin.and.ellipse")
    }
}
