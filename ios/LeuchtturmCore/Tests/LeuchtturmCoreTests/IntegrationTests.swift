import Foundation
import Testing
@testable import LeuchtturmCore

/// End-to-end tests against a real leuchtturmd. Skipped unless
/// LEUCHTTURM_TEST_SERVER is set, e.g.:
///
///     (cd server && LEUCHTTURM_ADDR=127.0.0.1:8080 go run ./cmd/leuchtturmd) &
///     LEUCHTTURM_TEST_SERVER=http://127.0.0.1:8080 swift test
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LEUCHTTURM_TEST_SERVER"] != nil), .serialized)
struct IntegrationTests {
    let server = URL(string: ProcessInfo.processInfo.environment["LEUCHTTURM_TEST_SERVER"] ?? "http://127.0.0.1:8080")!

    func makeClient(_ name: String) async throws -> LeuchtturmClient {
        let client = try LeuchtturmClient(serverURL: server, secrets: InMemorySecretStore(), displayName: name)
        try await client.register()
        return client
    }

    @Test func fullCircleLifecycle() async throws {
        let alice = try await makeClient("Alice")
        let bob = try await makeClient("Bob")
        let carol = try await makeClient("Carol")

        let circleID = try await alice.createCircle(name: "Familie")
        var aliceView = try await alice.circle(circleID)
        #expect(aliceView.name == "Familie" && aliceView.isOwner && aliceView.epoch == 1)
        #expect(aliceView.members.map(\.name) == ["Alice"])

        // Invite for two people, shared as a link.
        let link = try await alice.createInvite(circleID: circleID, maxUses: 2)
        let parsed = try #require(InviteLink(string: link.url.absoluteString))
        #expect(try await bob.join(parsed) == circleID)
        #expect(try await carol.join(parsed) == circleID)

        // Everyone can decrypt names; nobody else could.
        let bobView = try await bob.circle(circleID)
        #expect(bobView.name == "Familie")
        #expect(Set(bobView.members.compactMap(\.name)) == ["Alice", "Bob", "Carol"])
        #expect(!bobView.isOwner)

        // Link is used up.
        let dave = try await makeClient("Dave")
        await #expect(throws: APIError.self) { try await dave.join(parsed) }

        // Members cannot remove others or rename.
        await #expect(throws: ClientError.notOwner) { try await bob.remove(memberID: carol.deviceID, from: circleID) }
        await #expect(throws: ClientError.notOwner) { try await bob.rename(circleID: circleID, to: "Hijack") }

        // Alice removes Bob: key rotates to epoch 2.
        try await alice.remove(memberID: bob.deviceID, from: circleID)
        aliceView = try await alice.circle(circleID)
        #expect(aliceView.epoch == 2)
        #expect(Set(aliceView.members.compactMap(\.name)) == ["Alice", "Carol"])

        // Carol picks up the new key from Alice's wrap and still reads everything.
        let carolView = try await carol.circle(circleID)
        #expect(carolView.epoch == 2 && carolView.name == "Familie")
        #expect(Set(carolView.members.compactMap(\.name)) == ["Alice", "Carol"])

        // Bob is out.
        #expect(try await bob.circles().isEmpty)
        await #expect(throws: APIError.self) { try await bob.circle(circleID) }

        // A new member after the rotation sees current names only after
        // members re-encrypted their cards (Carol and Alice already did).
        let link2 = try await alice.createInvite(circleID: circleID)
        _ = try await dave.join(link2)
        let daveView = try await dave.circle(circleID)
        #expect(daveView.name == "Familie")
        #expect(Set(daveView.members.compactMap(\.name)) == ["Alice", "Carol", "Dave"])

        // Rename and display name changes propagate.
        try await alice.rename(circleID: circleID, to: "Familie Schaller")
        try await carol.setDisplayName("Caro")
        let list = try await dave.circles()
        #expect(list.map(\.name) == ["Familie Schaller"])
        #expect(Set(try await dave.circle(circleID).members.compactMap(\.name)) == ["Alice", "Caro", "Dave"])

        // Safety codes match across devices.
        let fromDave = try await dave.circle(circleID).members.first { $0.id == alice.deviceID }
        #expect(fromDave?.safetyCode == alice.safetyCode)

        // Leaving and deleting.
        try await carol.leave(circleID: circleID)
        #expect(try await carol.circles().isEmpty)
        try await dave.deleteDevice()
        let final = try await alice.circle(circleID)
        #expect(final.members.map(\.name) == ["Alice"])
    }

    @Test func inviteFromOtherServerIsRejected() async throws {
        let alice = try await makeClient("Alice")
        let foreign = InviteLink(server: URL(string: "https://other.example")!, inviteID: CircleCrypto.newCircleID(), secret: randomBytes(32))
        await #expect(throws: ClientError.differentServer) { try await alice.join(foreign) }
    }

    @Test func wrongInviteSecretFails() async throws {
        let alice = try await makeClient("Alice")
        let bob = try await makeClient("Bob")
        let circleID = try await alice.createCircle(name: "Test")
        let link = try await alice.createInvite(circleID: circleID)
        let tampered = InviteLink(server: link.server, inviteID: link.inviteID, secret: randomBytes(32))
        await #expect(throws: APIError.self) { try await bob.join(tampered) }
        // The real link still works afterwards.
        #expect(try await bob.join(link) == circleID)
    }
}
