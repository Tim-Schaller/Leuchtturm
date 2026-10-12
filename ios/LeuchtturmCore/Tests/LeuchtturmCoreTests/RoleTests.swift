import Foundation
import Testing
@testable import LeuchtturmCore

/// Admins, owner requests and taking a circle over, including attempts by
/// members to grab or redirect it.
struct RoleTests {
    let cloud = InMemoryCloud()
    let clock = TestClock()

    func client(_ user: String, _ name: String) throws -> LeuchtturmClient {
        try LeuchtturmClient(backend: cloud.backend(for: user), secrets: InMemorySecretStore(), displayName: name, now: { [clock] in clock.now })
    }

    func names(_ details: CircleDetails) -> Set<String> { Set(details.members.compactMap(\.name)) }

    /// Alice owns "Familie"; Bob, Carol and Dave are confirmed members.
    func family() async throws -> (alice: LeuchtturmClient, bob: LeuchtturmClient, carol: LeuchtturmClient, dave: LeuchtturmClient, ref: CircleRef, refs: [String: CircleRef]) {
        let alice = try client("alice", "Alice")
        let bob = try client("bob", "Bob")
        let carol = try client("carol", "Carol")
        let dave = try client("dave", "Dave")
        let ref = try await alice.createCircle(name: "Familie")
        let link = try await alice.createInvite(for: ref)
        var refs: [String: CircleRef] = [:]
        for (name, c) in [("bob", bob), ("carol", carol), ("dave", dave)] { refs[name] = try await c.join(link) }
        _ = try await alice.circle(ref)
        return (alice, bob, carol, dave, ref, refs)
    }

    @Test func adminsAskTheOwnersDeviceToRemoveAndRename() async throws {
        let (alice, bob, carol, dave, ref, refs) = try await family()
        await #expect(throws: ClientError.notOwner) { try await bob.setAdmin(carol.deviceID, true, in: refs["bob"]!) }
        try await alice.setAdmin(bob.deviceID, true, in: ref)
        #expect(try await carol.circle(refs["carol"]!).members.first { $0.name == "Bob" }?.isAdmin == true)

        await #expect(throws: ClientError.notAdmin) { try await carol.requestRemoval(of: dave.deviceID, in: refs["carol"]!) }
        await #expect(throws: ClientError.unknownMember) { try await bob.requestRemoval(of: alice.deviceID, in: refs["bob"]!) }
        // Carol sends a removal "request" anyway: ignored, she is no admin.
        try await carol.send(.removeRequest, text: bob.deviceID, to: alice.deviceID, in: refs["carol"]!)
        try await bob.requestRemoval(of: dave.deviceID, in: refs["bob"]!)
        try await bob.requestRename(refs["bob"]!, to: "Familie Schaller")

        let view = try await alice.circle(ref)
        #expect(view.name == "Familie Schaller")
        #expect(names(view) == ["Alice", "Bob", "Carol"])
        #expect(view.epoch == 2)
        #expect(!view.notes.contains { $0.kind == .removeRequest || $0.kind == .renameRequest })
        #expect(try await dave.circles().isEmpty)
    }

    @Test func anAdminTakesOverWhenTheOwnerIsGoneAndEveryoneFollows() async throws {
        let (alice, bob, carol, _, ref, refs) = try await family()
        try await alice.addPlace(name: "Zuhause", emoji: "🏠", latitude: 53.55, longitude: 9.99, radius: 150, in: ref)
        try await alice.setAdmin(bob.deviceID, true, in: ref)
        try await alice.shareLocation(try #require(SharedLocation(latitude: 53.55, longitude: 9.99, accuracy: 10, timestamp: clock.now)))

        // While the owner is around, nobody takes over; members never can.
        await #expect(throws: ClientError.takeoverNotAllowed) { try await bob.takeOver(refs["bob"]!) }
        await #expect(throws: ClientError.takeoverNotAllowed) { try await carol.takeOver(refs["carol"]!) }

        clock.advance(by: 4 * 86400)
        #expect(try await bob.circle(refs["bob"]!).canTakeOver)
        let newRef = try await bob.takeOver(refs["bob"]!)

        let carolsCircles = try await carol.circles()
        #expect(carolsCircles.map(\.id) == [newRef.circleID])
        let carolsView = try await carol.circle(carolsCircles[0].ref)
        #expect(carolsView.name == "Familie" && carolsView.hasKey)
        #expect(carolsView.members.first { $0.isOwner }?.name == "Bob")
        #expect(carolsView.places.map(\.name) == ["Zuhause"])

        // Alice comes back: she follows as an admin, her old circle goes later.
        let alicesCircles = try await alice.circles()
        #expect(alicesCircles.map(\.id) == [newRef.circleID])
        let alicesView = try await alice.circle(alicesCircles[0].ref)
        #expect(alicesView.isAdmin && !alicesView.isOwner)
        #expect(names(alicesView) == ["Alice", "Bob", "Carol"])
        clock.advance(by: 4 * 86400)
        _ = try await alice.circles()
        #expect(cloud.rawRecords(circleID: ref.circleID).isEmpty)
    }

    @Test func theOwnerHandsOverAndForgedMovesAreIgnored() async throws {
        let (alice, bob, carol, dave, ref, refs) = try await family()
        try await alice.offerOwnership(to: carol.deviceID, in: ref)
        try await alice.shareLocation(try #require(SharedLocation(latitude: 53.55, longitude: 9.99, accuracy: 10, timestamp: clock.now)))
        #expect(try await carol.circle(refs["carol"]!).canTakeOver)

        // Bob, a plain member, tries to lure everyone into his own circle.
        let trap = try await bob.createCircle(name: "Falle")
        let trapURL = try await cloud.backend(for: "bob").inviteURL(for: trap)
        let key = try #require(bob.loadKey(circleID: ref.circleID, epoch: 1))
        func forge(signer: String, keysOf owner: LeuchtturmClient, signedBy signing: LeuchtturmClient) throws -> StoredRecord {
            let notice = MoveNotice(
                newCircleID: trap.circleID, shareURL: trapURL, ownerSigningKey: owner.identity.signingPublicKey,
                ownerAgreementKey: owner.identity.agreementPublicKey, timestamp: clock.now
            )
            let blob = try CircleCrypto.sealMove(notice, key: key, epoch: 1, circleID: ref.circleID, signer: signer)
            let sig = try signing.identity.sign(CircleCrypto.moveRecordStatement(circleID: ref.circleID, signer: signer, blob: blob))
            return StoredRecord(type: "Move", name: "move-\(signer)", fields: ["from": .string(signer), "blob": .bytes(blob), "sig": .bytes(sig)])
        }
        let bobBackend = cloud.backend(for: "bob")
        // As himself (no admin), and in Carol's name (her keys, his signature).
        try await bobBackend.modify(refs["bob"]!, save: [try forge(signer: bob.deviceID, keysOf: bob, signedBy: bob)], delete: [], removeParticipants: [])
        #expect(try await dave.circles().map(\.id) == [ref.circleID])
        try await bobBackend.modify(refs["bob"]!, save: [try forge(signer: carol.deviceID, keysOf: bob, signedBy: bob)], delete: [], removeParticipants: [])
        #expect(try await dave.circles().map(\.id) == [ref.circleID])

        // Carol takes it over for real (her own notice replaces the forgery).
        let newRef = try await carol.takeOver(refs["carol"]!)
        #expect(try await dave.circles().map(\.id) == [newRef.circleID])
        let davesView = try await dave.circle(newRef.withOwner(false, owner: "carol"))
        #expect(davesView.members.first { $0.isOwner }?.name == "Carol")
        #expect(try await alice.circles().map(\.id) == [newRef.circleID])
    }
}

private extension CircleRef {
    func withOwner(_ owned: Bool, owner: String) -> CircleRef {
        CircleRef(circleID: circleID, ownerUserID: owner, isOwned: owned)
    }
}

struct ProfileTests {
    let cloud = InMemoryCloud()

    @Test func profilesAreEncryptedSignedAndFollowKeyRotation() async throws {
        let alice = try LeuchtturmClient(backend: cloud.backend(for: "alice"), secrets: InMemorySecretStore(), displayName: "Alice")
        let bob = try LeuchtturmClient(backend: cloud.backend(for: "bob"), secrets: InMemorySecretStore(), displayName: "Bob")
        let carol = try LeuchtturmClient(backend: cloud.backend(for: "carol"), secrets: InMemorySecretStore(), displayName: "Carol")
        let ref = try await alice.createCircle(name: "Familie")
        let link = try await alice.createInvite(for: ref)
        let bobRef = try await bob.join(link)
        _ = try await carol.join(link)
        _ = try await alice.circle(ref)

        let photo = Data(repeating: 0xAB, count: 90_000)
        let profile = Profile(color: "#2F8F5B", emoji: "🦊", photo: photo, bannerStyle: "meadow",
                              statusEmoji: "🏋️", statusText: "beim Sport", statusUntil: Date().addingTimeInterval(3600))
        try await bob.setProfile(profile)
        let seen = try #require(try await alice.circle(ref).members.first { $0.name == "Bob" }?.profile)
        #expect(seen == profile)
        #expect(seen.status(at: Date())?.text == "beim Sport")
        #expect(seen.status(at: Date().addingTimeInterval(7200)) == nil)
        for record in cloud.rawRecords(circleID: ref.circleID) where record.type == "Profile" {
            for case let .bytes(bytes) in record.fields.values { #expect(bytes.range(of: Data("beim Sport".utf8)) == nil) }
        }
        await #expect(throws: ClientError.invalidProfile) {
            try await bob.setProfile(Profile(photo: Data(count: Profile.maxPhotoBytes + 1)))
        }

        // Carol overwrites Bob's profile with her own signature: ignored.
        var forged = try #require(cloud.rawRecords(circleID: ref.circleID).first { $0.name == "profile-\(bob.deviceID)" })
        forged.fields["sig"] = .bytes(try carol.identity.sign(Data("x".utf8)))
        try await cloud.backend(for: "carol").modify(bobRef, save: [forged], delete: [], removeParticipants: [])
        #expect(try await alice.circle(ref).members.first { $0.name == "Bob" }?.profile == nil)
        try await bob.setProfile(profile)

        // After a rotation Bob re-encrypts; a newcomer can read it.
        try await alice.remove(userID: "carol", from: ref)
        _ = try await bob.circle(bobRef)
        let dave = try LeuchtturmClient(backend: cloud.backend(for: "dave"), secrets: InMemorySecretStore(), displayName: "Dave")
        let daveRef = try await dave.join(try await alice.createInvite(for: ref))
        _ = try await alice.circle(ref)
        #expect(try await dave.circle(daveRef).members.first { $0.name == "Bob" }?.profile?.emoji == "🦊")

        try await bob.leave(bobRef)
        #expect(!cloud.rawRecords(circleID: ref.circleID).contains { $0.type == "Profile" && $0.name.hasSuffix(bob.deviceID) })
    }
}

