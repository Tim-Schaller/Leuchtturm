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
    /// People who currently share only an approximate area.
    var inFog: Set<String> = []
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
        let location = kind == .checkIn ? lastPositions[person.id] : nil
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
            ref = try await person.client.createCircle(name: "\(person.name)s Kreis")
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
            let (north, east): (Double, Double)
            switch index {
            case 0:
                let a = t / 600 * 2 * .pi
                (north, east) = (500 + 350 * sin(a), 450 + 350 * cos(a))
            case 1:
                let a = t / 240 * 2 * .pi
                (north, east) = (-900 + 1500 * sin(a), 700 + 1500 * cos(a))
            default:
                (north, east) = (-300, -1100)
            }
            let latitude = home.latitude + north / 111_320
            let longitude = home.longitude + east / (111_320 * cos(home.latitude * .pi / 180))
            // Anna's battery drains, Ben charges in the car, Clara runs low.
            let (battery, charging): (Int, Bool) = switch index {
            case 0: (max(20, 82 - Int(t / 120)), false)
            case 1: (min(100, 34 + Int(t / 60)), true)
            default: (9, false)
            }
            guard let position = SharedLocation(
                latitude: latitude, longitude: longitude, accuracy: index == 1 ? 25 : 10, timestamp: now,
                battery: battery, isCharging: charging
            ) else { continue }
            lastMoved[person.id] = now
            lastPositions[person.id] = position
            let shared = inFog.contains(person.id) ? position.inFog(radius: 1000) ?? position : position
            try? await person.client.shareLocation(shared)
        }
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
