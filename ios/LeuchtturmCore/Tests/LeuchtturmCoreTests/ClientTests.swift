import Foundation
import Testing
@testable import LeuchtturmCore

/// End-to-end flows against the in-memory CloudKit stand-in. The stand-in
/// allows everything CloudKit allows (any participant can overwrite any
/// record), so these tests also show what a malicious member can and
/// cannot do.
struct ClientTests {
    let cloud = InMemoryCloud()

    func client(_ user: String, _ name: String, now: @escaping @Sendable () -> Date = { Date() }) throws -> LeuchtturmClient {
        try LeuchtturmClient(backend: cloud.backend(for: user), secrets: InMemorySecretStore(), displayName: name, now: now)
    }

    func names(_ details: CircleDetails) -> Set<String> {
        Set(details.members.compactMap(\.name))
    }

    @Test func fullLifecycle() async throws {
        let alice = try client("alice", "Alice")
        let bob = try client("bob", "Bob")
        let carol = try client("carol", "Carol")

        let ref = try await alice.createCircle(name: "Familie")
        var aliceView = try await alice.circle(ref)
        #expect(aliceView.name == "Familie" && aliceView.isOwner && aliceView.epoch == 1)
        #expect(aliceView.members.map(\.name) == ["Alice"])

        // One link, two people (iCloud cannot enforce use limits).
        let link = try await alice.createInvite(for: ref)
        let parsed = try #require(InviteLink(string: link.url.absoluteString))
        let bobRef = try await bob.join(parsed)
        _ = try await carol.join(parsed)
        #expect(bobRef.circleID == ref.circleID && !bobRef.isOwned)

        // Before the owner confirms, members with a valid invite show as pending.
        let bobView = try await bob.circle(bobRef)
        #expect(bobView.name == "Familie" && !bobView.isOwner && bobView.hasKey)
        #expect(names(bobView) == ["Alice", "Bob", "Carol"])
        #expect(bobView.members.first { $0.name == "Carol" }?.isPending == true)

        // The owner's device confirms them into the signed roster.
        aliceView = try await alice.circle(ref)
        #expect(names(aliceView) == ["Alice", "Bob", "Carol"])
        #expect(aliceView.members.allSatisfy { !$0.isPending })
        #expect(aliceView.unverifiedUserIDs.isEmpty)

        // Apple (the backend) never sees names.
        let raw = cloud.rawRecords(circleID: ref.circleID)
        for record in raw {
            for value in record.fields.values {
                let bytes: Data
                switch value {
                case let .bytes(d): bytes = d
                case let .string(s): bytes = Data(s.utf8)
                case .int: continue
                }
                for word in ["Familie", "Alice", "Bob", "Carol"] {
                    #expect(bytes.range(of: Data(word.utf8)) == nil, "plaintext \(word) in \(record.type)")
                }
            }
        }

        // Only the owner manages the circle.
        await #expect(throws: ClientError.notOwner) { try await bob.remove(userID: "carol", from: bobRef) }
        await #expect(throws: ClientError.notOwner) { try await bob.rename(bobRef, to: "Hijack") }
        await #expect(throws: ClientError.ownerMustDelete) { try await alice.leave(ref) }

        // Removing Bob rotates the key.
        try await alice.remove(userID: "bob", from: ref)
        aliceView = try await alice.circle(ref)
        #expect(aliceView.epoch == 2)
        #expect(names(aliceView) == ["Alice", "Carol"])

        // Carol gets the new key from Alice's wrap.
        let carolView = try await carol.circle(bobRef)
        #expect(carolView.epoch == 2 && carolView.hasKey && carolView.name == "Familie")
        #expect(names(carolView) == ["Alice", "Carol"])

        // Bob is out, and the old invite died with the rotation.
        #expect(try await bob.circles().isEmpty)
        await #expect(throws: BackendError.notFound) { try await bob.circle(bobRef) }
        let dave = try client("dave", "Dave")
        await #expect(throws: ClientError.inviteInvalid) { try await dave.join(parsed) }
        #expect(try await dave.circles().isEmpty)

        // A new invite works, and the newcomer reads current names.
        let link2 = try await carol.createInvite(for: bobRef)
        let daveRef = try await dave.join(link2)
        #expect(names(try await dave.circle(daveRef)) == ["Alice", "Carol", "Dave"])

        // Rename and display-name changes propagate.
        try await alice.rename(ref, to: "Familie Schaller")
        try await carol.setDisplayName("Caro")
        #expect(try await dave.circles().map(\.name) == ["Familie Schaller"])
        let daveView = try await dave.circle(daveRef)
        #expect(names(daveView) == ["Alice", "Caro", "Dave"])

        // Safety codes are the same on every device.
        #expect(daveView.members.first { $0.name == "Alice" }?.safetyCode == alice.safetyCode)

        // Carol leaves; the owner's device cleans up.
        try await carol.leave(bobRef)
        #expect(names(try await alice.circle(ref)) == ["Alice", "Dave"])

        // Deleting the circle removes it for everyone.
        try await alice.deleteCircle(ref)
        #expect(try await dave.circles().isEmpty)
        #expect(try await alice.circles().isEmpty)
    }

    @Test func shareLinkWithoutSecretGivesNoMembership() async throws {
        let alice = try client("alice", "Alice")
        let bob = try client("bob", "Bob")
        let ref = try await alice.createCircle(name: "Freunde")
        let link = try await alice.createInvite(for: ref)
        _ = try await bob.join(link)

        // Eve only has the iCloud link (e.g. intercepted share URL).
        let eveBackend = cloud.backend(for: "eve")
        let eveRef = try await eveBackend.accept(inviteURL: link.shareURL)
        let eveIdentity = DeviceIdentity.generate()
        let statement = CircleCrypto.memberRecordStatement(
            circleID: ref.circleID, deviceID: eveIdentity.deviceID, inviteID: link.inviteID,
            signingKey: eveIdentity.signingPublicKey, agreementKey: eveIdentity.agreementPublicKey,
            card: Data([1]), proof: Data(repeating: 0, count: 32)
        )
        try await eveBackend.modify(eveRef, save: [StoredRecord(type: "Member", name: eveIdentity.deviceID, fields: [
            "skey": .bytes(eveIdentity.signingPublicKey), "akey": .bytes(eveIdentity.agreementPublicKey),
            "card": .bytes(Data([1])), "invite": .string(link.inviteID),
            "proof": .bytes(Data(repeating: 0, count: 32)), "sig": .bytes(try eveIdentity.sign(statement)),
        ])], delete: [], removeParticipants: [])

        // Eve is not a member for anyone, and the owner sees her as unverified.
        let aliceView = try await alice.circle(ref)
        #expect(!aliceView.members.contains { $0.id == eveIdentity.deviceID })
        #expect(aliceView.unverifiedUserIDs == ["eve"])
        #expect(!(try await bob.circle(eveRef)).members.contains { $0.id == eveIdentity.deviceID })

        // The owner removes her; she loses iCloud access.
        try await alice.remove(userID: "eve", from: ref)
        await #expect(throws: BackendError.notFound) { try await eveBackend.snapshot(of: eveRef) }
        #expect(names(try await bob.circle(eveRef)) == ["Alice", "Bob"])
    }

    @Test func wrongSecretIsRejectedAndUndone() async throws {
        let alice = try client("alice", "Alice")
        let bob = try client("bob", "Bob")
        let ref = try await alice.createCircle(name: "Test")
        let link = try await alice.createInvite(for: ref)
        let tampered = InviteLink(shareURL: link.shareURL, inviteID: link.inviteID, secret: randomBytes(32))
        await #expect(throws: ClientError.inviteInvalid) { try await bob.join(tampered) }
        #expect(try await bob.circles().isEmpty)
        // The real link still works afterwards.
        #expect(try await bob.join(link).circleID == ref.circleID)
    }

    @Test func expiredInviteIsRejected() async throws {
        let start = Date()
        let alice = try client("alice", "Alice", now: { start })
        let bob = try client("bob", "Bob", now: { start.addingTimeInterval(120) })
        let ref = try await alice.createCircle(name: "Test")
        let link = try await alice.createInvite(for: ref, validFor: 60)
        await #expect(throws: ClientError.inviteExpired) { try await bob.join(link) }
        #expect(try await bob.circles().isEmpty)
        await #expect(throws: ClientError.invalidDuration) { try await alice.createInvite(for: ref, validFor: 10) }
    }

    @Test func memberCannotForgeOthersOrTheCircle() async throws {
        let alice = try client("alice", "Alice")
        let bob = try client("bob", "Bob")
        let carol = try client("carol", "Carol")
        let ref = try await alice.createCircle(name: "Familie")
        let link = try await alice.createInvite(for: ref)
        let bobRef = try await bob.join(link)
        _ = try await carol.join(link)
        _ = try await alice.circle(ref)

        // Bob overwrites Carol's member record with his own keys and a new name.
        let carolID = carol.deviceID
        let bobBackend = cloud.backend(for: "bob")
        var forged = try #require(cloud.rawRecords(circleID: ref.circleID).first { $0.name == carolID })
        forged.fields["skey"] = .bytes(bob.identity.signingPublicKey)
        forged.fields["akey"] = .bytes(bob.identity.agreementPublicKey)
        try await bobBackend.modify(bobRef, save: [forged], delete: [], removeParticipants: [])

        // Nobody accepts the forged record (device ID no longer matches the key).
        let aliceView = try await alice.circle(ref)
        #expect(!aliceView.members.contains { $0.id == carolID })
        // Carol's next sync restores her own record.
        _ = try await carol.circle(bobRef)
        #expect(names(try await alice.circle(ref)) == ["Alice", "Bob", "Carol"])

        // Bob replaces the circle record with one he signed: detected, not accepted.
        var circle = try #require(cloud.rawRecords(circleID: ref.circleID).first { $0.type == "Circle" })
        let meta = Data([9, 9, 9])
        circle.fields["meta"] = .bytes(meta)
        circle.fields["sig"] = .bytes(try bob.identity.sign(CircleCrypto.circleRecordStatement(circleID: ref.circleID, epoch: 1, meta: meta)))
        try await bobBackend.modify(bobRef, save: [circle], delete: [], removeParticipants: [])
        await #expect(throws: ClientError.tampered) { try await carol.circle(bobRef) }
        await #expect(throws: ClientError.tampered) { try await alice.circle(ref) }
    }

    @Test func reinstalledDeviceHasNoTrustAnchor() async throws {
        let alice = try client("alice", "Alice")
        let bob = try client("bob", "Bob")
        let ref = try await alice.createCircle(name: "Test")
        let bobRef = try await bob.join(try await alice.createInvite(for: ref))
        // Same iCloud user, fresh app install: no pinned owner key, no circle key.
        let bobAgain = try client("bob", "Bob")
        await #expect(throws: ClientError.untrustedCircle) { try await bobAgain.circle(bobRef) }
        #expect(try await bobAgain.circles().map(\.name) == [nil])
    }

    @Test func namesAreValidated() async throws {
        let alice = try client("alice", "Alice")
        await #expect(throws: ClientError.invalidName) { try await alice.createCircle(name: "   ") }
        await #expect(throws: ClientError.invalidName) { try await alice.createCircle(name: String(repeating: "x", count: 41)) }
    }
}
