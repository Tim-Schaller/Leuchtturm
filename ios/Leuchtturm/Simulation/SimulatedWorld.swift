#if DEBUG
import CoreLocation
import Foundation
import LeuchtturmCore

/// Stand-in for iCloud with three made-up people, so the app can be tried
/// without an Apple Account (debug builds only). The people run the real
/// `LeuchtturmClient` with their own keys; only storage is simulated, by the
/// same `InMemoryCloud` the core tests use. Nothing touches iCloud, the
/// Keychain or the saved settings, and everything is gone when the app quits.
@MainActor
final class SimulatedWorld {
    /// Starts the app in the simulation, e.g.
    /// `xcrun simctl launch booted de.timschaller.leuchtturm -simulation`.
    static let launchArgument = "-simulation"
    /// Like `-simulation`, but already set up as "Tim" with a full demo circle.
    static let demoArgument = "-simulationDemo"

    struct Person: Identifiable, Sendable {
        /// Simulated iCloud user ID.
        let id: String
        let name: String
        let client: LeuchtturmClient
    }

    struct Membership: Identifiable, Sendable {
        let person: Person
        let isOwner: Bool
        var id: String { person.id }
    }

    let people: [Person]
    /// Storage and keys of this device (you).
    let backend: InMemoryBackend
    let secrets = InMemorySecretStore()
    /// The name chosen during setup.
    var savedName: String?

    private let cloud: InMemoryCloud
    private var strangers = 0
    private let startedAt = Date()
    /// Where the people hang out; fixed on the first move.
    private var home: CLLocationCoordinate2D?
    private var lastMoved: [String: Date] = [:]
    private var lastPositions: [String: SharedLocation] = [:]
    private var placeTrackers: [String: PlaceTracker] = [:]
    /// Anna's and Ben's paths today; they share their history.
    private var paths: [String: [HistoryDay.Point]] = [:]
    /// People who currently share only an approximate area.
    var inFog: Set<String> = []
    /// People who already warned about their battery.
    private var batteryWarned: Set<String> = []
    /// Notes the people already answered.
    private var answered: Set<String> = []

    /// Used when your own position is unknown (e.g. no simulator location).
    static let fallbackHome = CLLocationCoordinate2D(latitude: 53.5502, longitude: 9.9920)

    init() throws {
        let cloud = InMemoryCloud()
        self.cloud = cloud
        backend = cloud.backend(for: "sim-me")
        people = try ["Anna", "Ben", "Clara"].map { name in
            let id = "sim-" + name.lowercased()
            let client = try LeuchtturmClient(backend: cloud.backend(for: id), secrets: InMemorySecretStore(), displayName: name)
            return Person(id: id, name: name, client: client)
        }
    }

    /// The people open their app: owners confirm new members, everyone picks
    /// up new keys and keeps their member card current. Notes sent to them
    /// get a friendly answer.
    func tick() async {
        for person in people {
            for circle in (try? await person.client.circles()) ?? [] {
                guard let details = try? await person.client.circle(circle.ref) else { continue }
                for note in details.notes where note.recipientID == person.client.deviceID && !answered.contains(note.id) {
                    answered.insert(note.id)
                    _ = try? await person.client.send(.reaction, text: note.kind == .text ? "👍" : "😊", to: note.senderID, in: circle.ref)
                }
            }
        }
    }

    /// The person sends a note to all their circles, optionally addressed to
    /// someone. A check-in uses their current position.
    func send(_ kind: CircleNote.Kind, text: String = "", from person: Person, to recipientID: String? = nil) async throws {
        let location = kind == .checkIn || kind == .sos ? lastPositions[person.id] : nil
        for circle in try await person.client.circles() {
            try await person.client.send(kind, text: text, to: recipientID, location: location, in: circle.ref)
        }
    }

    /// The person receives the invite link as text, like via a messenger, and joins.
    func join(_ person: Person, using link: InviteLink) async throws {
        guard let received = InviteLink(url: link.url) else { throw ClientError.inviteInvalid }
        _ = try await person.client.join(received)
    }

    /// The person leaves the circle, or deletes it if they own it.
    func leave(_ person: Person, circleID: String) async throws {
        guard let ref = try await person.client.circles().first(where: { $0.id == circleID })?.ref else {
            throw BackendError.notFound
        }
        if ref.isOwned {
            try await person.client.deleteCircle(ref)
        } else {
            try await person.client.leave(ref)
        }
    }

    /// The person invites you to their own circle, created on first use.
    func invitation(from person: Person) async throws -> InviteLink {
        let ref: CircleRef
        if let owned = try await person.client.circles().first(where: \.isOwner)?.ref {
            ref = owned
        } else {
            ref = try await person.client.createCircle(name: "\(person.name)s Leuchtturm")
        }
        return try await person.client.createInvite(for: ref)
    }

    /// Someone who got hold of the iCloud share link, but not the invite
    /// secret, opens it. The owner sees them as an unverified participant.
    func strangerOpensShareLink(of circle: CircleRef) async throws {
        strangers += 1
        let url = try await backend.inviteURL(for: circle)
        _ = try await cloud.backend(for: "sim-stranger-\(strangers)").accept(inviteURL: url)
    }

    /// The people share their current position: Anna walks a loop, Ben
    /// drives a bigger one, Clara is at home and reports only now and then.
    func move(near location: CLLocation?) async {
        let home = self.home ?? location?.coordinate ?? Self.fallbackHome
        self.home = home
        let now = Date()
        let t = now.timeIntervalSince(startedAt)
        for (index, person) in people.enumerated() {
            let interval: TimeInterval = index == 2 ? 300 : 0
            if let last = lastMoved[person.id], now.timeIntervalSince(last) < interval { continue }
            // Not in a circle yet: report as soon as they join one.
            if (try? await person.client.circles())?.isEmpty ?? true { continue }
            let (north, east) = Self.route(index, at: t)
            let (latitude, longitude) = Self.offset(home, north: north, east: east)
            // Anna's battery drains, Ben charges in the car, Clara runs low.
            let (battery, charging): (Int, Bool) = switch index {
            case 0: (max(20, 82 - Int(t / 120)), false)
            case 1: (min(100, 34 + Int(t / 60)), true)
            default: (9, false)
            }
            guard let position = SharedLocation(
                latitude: latitude, longitude: longitude, accuracy: index == 1 ? 25 : 10, timestamp: now,
                battery: battery, isCharging: charging, speed: index == 1 ? 2 * .pi * 1500 / 600 : nil
            ) else { continue }
            lastMoved[person.id] = now
            lastPositions[person.id] = position
            if battery <= 15, !charging, batteryWarned.insert(person.id).inserted {
                try? await send(.lowBattery, text: "\(battery)", from: person)
            }
            let shared = inFog.contains(person.id) ? position.inFog(radius: 1000) ?? position : position
            var history: HistoryUpdate?
            if index < 2 && !inFog.contains(person.id) {
                // The last half hour of the route, then every move.
                var path = paths[person.id] ?? stride(from: -1800.0, to: 0, by: 30).map { dt in
                    let (n, e) = Self.route(index, at: t + dt)
                    let (lat, lon) = Self.offset(home, north: n, east: e)
                    return HistoryDay.Point(latitude: lat, longitude: lon, timestamp: now.addingTimeInterval(dt))
                }
                path.append(HistoryDay.Point(latitude: latitude, longitude: longitude, timestamp: now))
                paths[person.id] = path
                let today = HistoryDay(
                    deviceID: person.client.deviceID, day: HistoryDay.dayKey(for: now),
                    points: path.filter { HistoryDay.dayKey(for: $0.timestamp) == HistoryDay.dayKey(for: now) }
                )
                history = HistoryUpdate(today: today, keepDays: 7)
            }
            try? await person.client.shareLocation(shared, history: history)
            if !inFog.contains(person.id) { await watchPlaces(of: person, at: position) }
        }
    }

    /// Like the app does on a real iPhone: check the person's places and
    /// tell the circle about arrivals and departures.
    private func watchPlaces(of person: Person, at position: SharedLocation) async {
        for circle in (try? await person.client.circles()) ?? [] {
            guard let places = try? await person.client.circle(circle.ref).places else { continue }
            var tracker = placeTrackers[person.id + circle.id] ?? PlaceTracker()
            let events = tracker.update(latitude: position.latitude, longitude: position.longitude, accuracy: position.accuracy, places: places)
            placeTrackers[person.id + circle.id] = tracker
            for event in events {
                switch event {
                case let .arrived(place): _ = try? await person.client.send(.arrival, text: place.name, in: circle.ref)
                case let .left(place): _ = try? await person.client.send(.departure, text: place.name, in: circle.ref)
                }
            }
        }
    }

    /// Anna's café and Ben's office lie on their routes, so arrivals and
    /// departures happen within a few minutes.
    func addDemoPlaces(circleID: String, near location: CLLocation?) async throws {
        let home = self.home ?? location?.coordinate ?? Self.fallbackHome
        self.home = home
        for (person, name, emoji, north, east, radius) in [
            (people[0], "Café am See", "☕️", 850.0, 450.0, 120), (people[1], "Büro", "💼", 600.0, 700.0, 200),
        ] {
            guard let ref = try await person.client.circles().first(where: { $0.id == circleID })?.ref else { continue }
            let (latitude, longitude) = Self.offset(home, north: north, east: east)
            try await person.client.addPlace(name: name, emoji: emoji, latitude: latitude, longitude: longitude, radius: radius, in: ref)
        }
    }

    /// Meters north and east of home: Anna walks a loop, Ben drives a bigger one, Clara stays put.
    static func route(_ index: Int, at t: TimeInterval) -> (Double, Double) {
        switch index {
        case 0:
            let a = t / 600 * 2 * .pi
            return (500 + 350 * sin(a), 450 + 350 * cos(a))
        case 1:
            let a = t / 600 * 2 * .pi
            return (-900 + 1500 * sin(a), 700 + 1500 * cos(a))
        default:
            return (-300, -1100)
        }
    }

    /// Ben and Clara share their trips; here are some from the past week.
    func addDemoTrips(near location: CLLocation?) async throws {
        let home = self.home ?? location?.coordinate ?? Self.fallbackHome
        self.home = home
        let now = Date()
        let plan: [(person: Person, daysAgo: Double, laps: Double, top: Double, brakes: Int, accels: Int)] = [
            (people[1], 0.2, 1.0, 16, 0, 0), (people[1], 1.3, 2.0, 19, 1, 0), (people[1], 3.4, 1.5, 17, 0, 0),
            (people[1], 5.1, 3.0, 22, 0, 1), (people[2], 0.9, 1.2, 25, 2, 1), (people[2], 4.2, 2.5, 38, 1, 2),
        ]
        for (i, entry) in plan.enumerated() {
            let start = now.addingTimeInterval(-entry.daysAgo * 86400)
            let duration = entry.laps * 600
            let route = stride(from: 0.0, through: duration, by: 30).map { dt in
                let (n, e) = Self.route(1, at: dt + Double(i) * 97)
                let (lat, lon) = Self.offset(home, north: n, east: e)
                return HistoryDay.Point(latitude: lat, longitude: lon, timestamp: start.addingTimeInterval(dt))
            }
            let trip = Trip(
                id: CircleCrypto.newCircleID(), deviceID: entry.person.client.deviceID, start: start,
                end: start.addingTimeInterval(duration), distance: entry.laps * 2 * .pi * 1500, topSpeed: entry.top,
                hardBrakes: entry.brakes, rapidAccelerations: entry.accels, route: route
            )
            try await entry.person.client.shareTrip(trip)
        }

        // Ben's day out: town, country road, motorway at up to 220 km/h, town again.
        var route: [HistoryDay.Point] = []
        var (north, east, time) = (0.0, 0.0, now.addingTimeInterval(-2 * 86400))
        let start = time
        var distance = 0.0
        for (kmh, minutes) in [(30.0, 6.0), (70, 6), (100, 5), (150, 6), (220, 8), (130, 6), (80, 4), (35, 6)] {
            for _ in 0 ..< Int(minutes * 2) {
                let meters = kmh / 3.6 * 30
                north += meters * 0.8
                east += meters * 0.6
                distance += meters
                time = time.addingTimeInterval(30)
                let (lat, lon) = Self.offset(home, north: north, east: east)
                route.append(HistoryDay.Point(latitude: lat, longitude: lon, timestamp: time))
            }
        }
        try await people[1].client.shareTrip(Trip(
            id: CircleCrypto.newCircleID(), deviceID: people[1].client.deviceID, start: start, end: time,
            distance: distance, topSpeed: 220 / 3.6, hardBrakes: 0, rapidAccelerations: 1, route: route
        ))
    }

    static func offset(_ home: CLLocationCoordinate2D, north: Double, east: Double) -> (Double, Double) {
        (home.latitude + north / 111_320, home.longitude + east / (111_320 * cos(home.latitude * .pi / 180)))
    }

    /// The people in each circle, by circle ID.
    func memberships() async -> [String: [Membership]] {
        var out: [String: [Membership]] = [:]
        for person in people {
            for circle in (try? await person.client.circles()) ?? [] {
                out[circle.id, default: []].append(Membership(person: person, isOwner: circle.isOwner))
            }
        }
        return out
    }

    func people(notIn circleID: String) async -> [Person] {
        let members = Set((await memberships()[circleID] ?? []).map(\.id))
        return people.filter { !members.contains($0.id) }
    }
}
#endif
