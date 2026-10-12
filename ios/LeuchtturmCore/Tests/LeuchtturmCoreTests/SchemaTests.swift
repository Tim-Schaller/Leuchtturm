import Foundation
import Testing
@testable import LeuchtturmCore

/// The schema that debug builds create in CloudKit must match what the
/// client really writes, or Production would reject records after release.
struct SchemaTests {
    @Test func clientWritesExactlyTheDeclaredSchema() async throws {
        let cloud = InMemoryCloud()
        let clock = TestClock()
        func client(_ user: String, _ name: String) throws -> LeuchtturmClient {
            try LeuchtturmClient(backend: cloud.backend(for: user), secrets: InMemorySecretStore(), displayName: name, now: { clock.now })
        }
        let alice = try client("alice", "Alice")
        let bob = try client("bob", "Bob")
        let ref = try await alice.createCircle(name: "Familie")
        let bobRef = try await bob.join(try await alice.createInvite(for: ref))
        _ = try await alice.circle(ref)

        let here = try #require(SharedLocation(latitude: 53.55, longitude: 9.99, accuracy: 10, timestamp: clock.now))
        let day = HistoryDay(deviceID: alice.deviceID, day: HistoryDay.dayKey(for: clock.now), points: [.init(latitude: 53.55, longitude: 9.99, timestamp: clock.now)])
        try await alice.shareLocation(here, history: HistoryUpdate(today: day, keepDays: 7))
        _ = try await alice.send(.checkIn, in: ref)
        _ = try await alice.addPlace(name: "Zuhause", emoji: "🏠", latitude: 53.55, longitude: 9.99, radius: 150, in: ref)
        try await alice.shareTrip(Trip(
            id: UUID().uuidString, deviceID: alice.deviceID, start: clock.now, end: clock.now + 600, distance: 5000, topSpeed: 20,
            hardBrakes: 0, rapidAccelerations: 0, route: []
        ))
        try await alice.setProfile(Profile(color: "#2F8F5B", photo: Data([1, 2, 3]), banner: Data([4, 5, 6])))
        _ = try await bob.sendMessage("Hallo", image: Data([7, 8, 9]), in: bobRef)
        try await alice.setAdmin(bob.deviceID, true, in: ref)
        try await alice.offerOwnership(to: bob.deviceID, in: ref)
        _ = try await bob.takeOver(bobRef)

        let declared = CloudSchema.entries(CloudSchema.zoneRecords)
        let written = cloud.writtenFields()
        #expect(written.subtracting(declared).isEmpty, "written but not declared: \(written.subtracting(declared).sorted())")
        #expect(declared.subtracting(written).isEmpty, "declared but never written: \(declared.subtracting(written).sorted())")
    }

    @Test func samplesCoverEveryField() {
        let all = CloudSchema.zoneRecords.merging(CloudSchema.privateRecords) { a, _ in a }.merging(CloudSchema.publicRecords) { a, _ in a }
        let samples = CloudSchema.samples(all)
        #expect(samples.count == all.count)
        for sample in samples {
            #expect(Set(sample.fields.keys) == Set(all[sample.type]?.keys ?? [:].keys))
        }
    }
}
