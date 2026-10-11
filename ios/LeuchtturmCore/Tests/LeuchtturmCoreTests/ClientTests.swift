import Foundation
import Synchronization
import Testing
@testable import LeuchtturmCore

/// A clock the tests can move forward.
final class TestClock: Sendable {
    private let time = Mutex(Date())
    var now: Date { time.withLock { $0 } }
    func advance(by seconds: TimeInterval) { time.withLock { $0 += seconds } }
}

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

    func location(_ lat: Double, _ lon: Double, at date: Date = Date()) throws -> SharedLocation {
        try #require(SharedLocation(latitude: lat, longitude: lon, accuracy: 15, timestamp: date))
    }

    @Test func locationsAreSharedEncryptedAndWithdrawn() async throws {
        let alice = try client("alice", "Alice")
        let bob = try client("bob", "Bob")
        let carol = try client("carol", "Carol")
        let ref = try await alice.createCircle(name: "Familie")
        let link = try await alice.createInvite(for: ref)
        let bobRef = try await bob.join(link)
        _ = try await carol.join(link)
        _ = try await alice.circle(ref)

        let hamburg = try #require(SharedLocation(latitude: 53.5511, longitude: 9.9937, accuracy: 15, timestamp: Date(), battery: 42, isCharging: true))
        #expect(SharedLocation(latitude: 1, longitude: 1, accuracy: 1, timestamp: Date(), battery: 101) == nil)
        try await bob.shareLocation(hamburg)
        try await carol.shareLocation(try location(48.1372, 11.5756))
        let aliceView = try await alice.circle(ref)
        #expect(aliceView.members.first { $0.name == "Bob" }?.location == hamburg)
        #expect(aliceView.members.first { $0.name == "Alice" }?.location == nil)

        // Apple sees no coordinates.
        for record in cloud.rawRecords(circleID: ref.circleID) where record.type == "Location" {
            for case let .bytes(bytes) in record.fields.values {
                #expect(bytes.range(of: Data("53.55".utf8)) == nil)
            }
        }

        // Stopping, leaving and being removed all take the location away.
        func hasLocation(_ c: LeuchtturmClient) -> Bool {
            cloud.rawRecords(circleID: ref.circleID).contains { $0.name == "loc-\(c.deviceID)" }
        }
        try await bob.stopSharingLocation()
        #expect(!hasLocation(bob))
        #expect(try await alice.circle(ref).members.first { $0.name == "Bob" }?.location == nil)
        try await bob.shareLocation(hamburg)
        try await bob.leave(bobRef)
        #expect(!hasLocation(bob))
        #expect(hasLocation(carol))
        try await alice.remove(userID: "carol", from: ref)
        #expect(!hasLocation(carol))
    }

    @Test func membersCannotFakeOrRewindLocations() async throws {
        let start = Date()
        let alice = try client("alice", "Alice")
        let bob = try client("bob", "Bob")
        let carol = try client("carol", "Carol")
        let ref = try await alice.createCircle(name: "Familie")
        let link = try await alice.createInvite(for: ref)
        let bobRef = try await bob.join(link)
        _ = try await carol.join(link)
        _ = try await alice.circle(ref)
        let bobBackend = cloud.backend(for: "bob")
        func carolOnAlicesMap() async throws -> SharedLocation? {
            try await alice.circle(ref).members.first { $0.name == "Carol" }?.location
        }

        let earlier = try location(52.52, 13.405, at: start)
        let now = try location(52.53, 13.41, at: start.addingTimeInterval(60))
        try await carol.shareLocation(earlier)
        let oldRecord = try #require(cloud.rawRecords(circleID: ref.circleID).first { $0.name == "loc-\(carol.deviceID)" })
        try await carol.shareLocation(now)
        #expect(try await carolOnAlicesMap() == now)

        // Bob replays Carol's older, validly signed record: ignored.
        try await bobBackend.modify(bobRef, save: [oldRecord], delete: [], removeParticipants: [])
        #expect(try await carolOnAlicesMap() == now)

        // Bob writes a position for Carol with the circle key, signed by himself: ignored.
        let key = try #require(bob.loadKey(circleID: ref.circleID, epoch: 1))
        let fake = try location(0, 0)
        let blob = try CircleCrypto.sealLocation(fake, key: key, epoch: 1, circleID: ref.circleID, deviceID: carol.deviceID)
        let sig = try bob.identity.sign(CircleCrypto.locationRecordStatement(circleID: ref.circleID, deviceID: carol.deviceID, blob: blob))
        try await bobBackend.modify(bobRef, save: [StoredRecord(type: "Location", name: "loc-\(carol.deviceID)", fields: [
            "blob": .bytes(blob), "sig": .bytes(sig),
        ])], delete: [], removeParticipants: [])
        #expect(try await carolOnAlicesMap() == now)

        // A newcomer who is not confirmed yet shares nothing with the circle.
        let dave = try client("dave", "Dave")
        _ = try await dave.join(link)
        try await dave.shareLocation(fake)
        let daveOnBobsList = try await bob.circle(bobRef).members.first { $0.name == "Dave" }
        #expect(daveOnBobsList?.isPending == true)
        #expect(daveOnBobsList?.location == nil)
    }

    @Test func notesAreEncryptedSignedAndOnlyFromMembers() async throws {
        let alice = try client("alice", "Alice")
        let bob = try client("bob", "Bob")
        let carol = try client("carol", "Carol")
        let ref = try await alice.createCircle(name: "Familie")
        let link = try await alice.createInvite(for: ref)
        let bobRef = try await bob.join(link)
        let carolRef = try await carol.join(link)
        _ = try await alice.circle(ref)

        let heart = try await bob.send(.reaction, text: "❤️", to: alice.deviceID, in: bobRef)
        #expect(try await alice.circle(ref).notes == [heart])
        let checkIn = try await carol.send(.checkIn, location: try location(53.55, 9.99), in: carolRef)
        let notes = try await alice.circle(ref).notes
        #expect(notes.map(\.id) == [checkIn.id, heart.id] || notes.map(\.id) == [heart.id, checkIn.id])
        #expect(notes.first { $0.kind == .checkIn }?.location?.latitude == 53.55)

        // Apple sees neither the emoji nor the place.
        for record in cloud.rawRecords(circleID: ref.circleID) where record.type == "Note" {
            for case let .bytes(bytes) in record.fields.values {
                #expect(bytes.range(of: Data("❤️".utf8)) == nil)
                #expect(bytes.range(of: Data("53.55".utf8)) == nil)
            }
        }

        // Bob writes a note "from" Carol, signed by himself: ignored.
        let key = try #require(bob.loadKey(circleID: ref.circleID, epoch: 1))
        let fake = CircleNote(
            id: CircleCrypto.newCircleID(), senderID: carol.deviceID, recipientID: nil, kind: .text, text: "Ich schulde Bob 100 €",
            location: nil, timestamp: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        )
        let blob = try CircleCrypto.sealNote(fake, key: key, epoch: 1, circleID: ref.circleID)
        let sig = try bob.identity.sign(CircleCrypto.noteRecordStatement(circleID: ref.circleID, noteID: fake.id, senderID: carol.deviceID, blob: blob))
        try await cloud.backend(for: "bob").modify(bobRef, save: [StoredRecord(type: "Note", name: "note-\(fake.id)", fields: [
            "from": .string(carol.deviceID), "blob": .bytes(blob), "sig": .bytes(sig),
        ])], delete: [], removeParticipants: [])
        #expect(!(try await alice.circle(ref).notes.contains { $0.id == fake.id }))

        // A newcomer the owner has not confirmed yet cannot post.
        let dave = try client("dave", "Dave")
        let daveRef = try await dave.join(link)
        let early = try await dave.send(.text, text: "Hallo", in: daveRef)
        #expect(!(try await bob.circle(bobRef).notes.contains { $0.id == early.id }))

        await #expect(throws: ClientError.invalidNote) {
            try await bob.send(.text, text: String(repeating: "x", count: CircleNote.maxTextLength + 1), in: bobRef)
        }
    }

    @Test func oldNotesFadeAndAreCleanedUp() async throws {
        let clock = TestClock()
        let alice = try client("alice", "Alice", now: { clock.now })
        let bob = try client("bob", "Bob", now: { clock.now })
        let ref = try await alice.createCircle(name: "Familie")
        let bobRef = try await bob.join(try await alice.createInvite(for: ref))
        _ = try await alice.circle(ref)

        try await bob.send(.reaction, text: "👋", in: bobRef)
        clock.advance(by: 8 * 24 * 3600)
        #expect(try await alice.circle(ref).notes.isEmpty)
        let fresh = try await bob.send(.reaction, text: "👍", in: bobRef)
        let names = cloud.rawRecords(circleID: ref.circleID).filter { $0.type == "Note" }.map(\.name)
        #expect(names == ["note-\(fresh.id)"])
    }

    @Test func placesAreSharedSignedAndSurviveKeyRotation() async throws {
        let alice = try client("alice", "Alice")
        let bob = try client("bob", "Bob")
        let carol = try client("carol", "Carol")
        let ref = try await alice.createCircle(name: "Familie")
        let link = try await alice.createInvite(for: ref)
        let bobRef = try await bob.join(link)
        _ = try await carol.join(link)
        _ = try await alice.circle(ref)

        let home = try await alice.addPlace(name: "Zuhause", emoji: "🏠", latitude: 53.55, longitude: 9.99, radius: 150, in: ref)
        #expect(try await bob.circle(bobRef).places == [home])
        for record in cloud.rawRecords(circleID: ref.circleID) where record.type == "Place" {
            for case let .bytes(bytes) in record.fields.values {
                #expect(bytes.range(of: Data("Zuhause".utf8)) == nil)
            }
        }
        await #expect(throws: ClientError.invalidPlace) {
            try await bob.addPlace(name: "", emoji: "🏠", latitude: 0, longitude: 0, radius: 150, in: bobRef)
        }

        // Bob forges a place "by Alice": ignored.
        let key = try #require(bob.loadKey(circleID: ref.circleID, epoch: 1))
        let fake = try #require(CirclePlace(id: CircleCrypto.newCircleID(), creatorID: alice.deviceID, name: "Falle", emoji: "⚠️", latitude: 1, longitude: 1, radius: 100))
        let blob = try CircleCrypto.sealPlace(fake, key: key, epoch: 1, circleID: ref.circleID)
        let sig = try bob.identity.sign(CircleCrypto.placeRecordStatement(circleID: ref.circleID, placeID: fake.id, creatorID: alice.deviceID, blob: blob))
        try await cloud.backend(for: "bob").modify(bobRef, save: [StoredRecord(type: "Place", name: "place-\(fake.id)", fields: [
            "from": .string(alice.deviceID), "blob": .bytes(blob), "sig": .bytes(sig),
        ])], delete: [], removeParticipants: [])
        #expect(try await carol.circle(bobRef).places == [home])

        // After removing Carol the key rotates; Alice re-encrypts her place
        // and a newcomer with only the new key can read it.
        try await alice.remove(userID: "carol", from: ref)
        _ = try await alice.circle(ref)
        let dave = try client("dave", "Dave")
        let daveRef = try await dave.join(try await alice.createInvite(for: ref))
        _ = try await alice.circle(ref)
        #expect(try await dave.circle(daveRef).places.map(\.name) == ["Zuhause"])

        try await bob.deletePlace(home.id, in: bobRef)
        #expect(try await alice.circle(ref).places.isEmpty)
    }

    @Test func historyIsOptInSignedAndExpires() async throws {
        let clock = TestClock()
        let alice = try client("alice", "Alice", now: { clock.now })
        let bob = try client("bob", "Bob", now: { clock.now })
        let ref = try await alice.createCircle(name: "Familie")
        let bobRef = try await bob.join(try await alice.createInvite(for: ref))
        _ = try await alice.circle(ref)
        func day(_ offset: Double, _ points: Int) -> HistoryDay {
            let date = clock.now.addingTimeInterval(offset * 86400)
            return HistoryDay(deviceID: bob.deviceID, day: HistoryDay.dayKey(for: date), points: (0 ..< points).map {
                HistoryDay.Point(latitude: 53.5 + Double($0) / 1000, longitude: 9.9, timestamp: date.addingTimeInterval(Double($0) * 60))
            })
        }
        let here = try location(53.5, 9.9)

        // Without history only the location is shared.
        try await bob.shareLocation(here)
        #expect(try await alice.history(of: bob.deviceID, in: ref).isEmpty)

        let today = day(0, 3)
        try await bob.shareLocation(here, history: HistoryUpdate(today: today, keepDays: 7))
        #expect(try await alice.history(of: bob.deviceID, in: ref) == [today])
        for record in cloud.rawRecords(circleID: ref.circleID) where record.type == "History" {
            for case let .bytes(bytes) in record.fields.values { #expect(bytes.range(of: Data("53.5".utf8)) == nil) }
        }

        // Eight days later, with 7 days kept, the old day is gone.
        clock.advance(by: 8 * 86400)
        let later = day(0, 2)
        try await bob.shareLocation(here, history: HistoryUpdate(today: later, keepDays: 7))
        #expect(try await alice.history(of: bob.deviceID, in: ref).map(\.day) == [later.day])

        // Alice forges a day for Bob: ignored.
        let key = try #require(alice.loadKey(circleID: ref.circleID, epoch: 1))
        let fake = HistoryDay(deviceID: bob.deviceID, day: "2026-01-01", points: [HistoryDay.Point(latitude: 1, longitude: 1, timestamp: clock.now)])
        let blob = try CircleCrypto.sealHistory(fake, key: key, epoch: 1, circleID: ref.circleID)
        let sig = try alice.identity.sign(CircleCrypto.historyRecordStatement(circleID: ref.circleID, deviceID: bob.deviceID, day: fake.day, blob: blob))
        try await cloud.backend(for: "alice").modify(ref, save: [StoredRecord(type: "History", name: "hist-\(bob.deviceID)-2026-01-01", fields: [
            "from": .string(bob.deviceID), "day": .string("2026-01-01"), "blob": .bytes(blob), "sig": .bytes(sig),
        ])], delete: [], removeParticipants: [])
        #expect(try await alice.history(of: bob.deviceID, in: ref).map(\.day) == [later.day])

        // Turning history off deletes it; leaving deletes it too.
        try await bob.deleteHistory()
        #expect(cloud.rawRecords(circleID: ref.circleID).filter { $0.type == "History" && $0.string("from") == bob.deviceID }.isEmpty)
        try await bob.shareLocation(here, history: HistoryUpdate(today: later, keepDays: 1))
        try await bob.leave(bobRef)
        #expect(!cloud.rawRecords(circleID: ref.circleID).contains { $0.type == "History" && $0.string("from") == bob.deviceID })
    }

    @Test func tripsAreSignedAndExpire() async throws {
        let clock = TestClock()
        let alice = try client("alice", "Alice", now: { clock.now })
        let bob = try client("bob", "Bob", now: { clock.now })
        let ref = try await alice.createCircle(name: "Familie")
        let bobRef = try await bob.join(try await alice.createInvite(for: ref))
        _ = try await alice.circle(ref)
        func trip(_ id: String, endingAgo: TimeInterval) -> Trip {
            Trip(id: id, deviceID: bob.deviceID, start: clock.now - endingAgo - 900, end: clock.now - endingAgo, distance: 12000,
                 topSpeed: 25, hardBrakes: 1, rapidAccelerations: 0, route: [HistoryDay.Point(latitude: 53.5, longitude: 9.9, timestamp: clock.now)])
        }
        let week = clock.now - 7 * 86400

        try await bob.shareTrip(trip("t1", endingAgo: 3600))
        #expect(try await alice.trips(in: ref, since: week).map(\.id) == ["t1"])
        #expect(try await alice.trips(in: ref, since: week).first?.score == 92)

        // 31 days later the old trip goes when a new one is shared.
        clock.advance(by: 31 * 86400)
        try await bob.shareTrip(trip("t2", endingAgo: 60))
        #expect(cloud.rawRecords(circleID: ref.circleID).filter { $0.type == "Trip" }.map(\.name) == ["trip-t2"])

        // Alice forges a trip "by Bob": ignored.
        let key = try #require(alice.loadKey(circleID: ref.circleID, epoch: 1))
        let fake = trip("t3", endingAgo: 10)
        let blob = try CircleCrypto.sealTrip(fake, key: key, epoch: 1, circleID: ref.circleID)
        let sig = try alice.identity.sign(CircleCrypto.tripRecordStatement(circleID: ref.circleID, tripID: "t3", deviceID: bob.deviceID, blob: blob))
        try await cloud.backend(for: "alice").modify(ref, save: [StoredRecord(type: "Trip", name: "trip-t3", fields: [
            "from": .string(bob.deviceID), "blob": .bytes(blob), "sig": .bytes(sig),
        ])], delete: [], removeParticipants: [])
        #expect(try await alice.trips(in: ref, since: clock.now - 86400).map(\.id) == ["t2"])

        try await bob.deleteTrips()
        #expect(try await alice.trips(in: ref, since: .distantPast).isEmpty)
        try await bob.leave(bobRef)
    }

    @Test func temporaryCirclesEndByThemselves() async throws {
        let clock = TestClock()
        let alice = try client("alice", "Alice", now: { clock.now })
        let bob = try client("bob", "Bob", now: { clock.now })
        let end = clock.now.addingTimeInterval(86400)
        let ref = try await alice.createCircle(name: "Festival", expiresAt: end)
        let bobRef = try await bob.join(try await alice.createInvite(for: ref))
        try await alice.rename(ref, to: "Festival 2027")
        #expect(try await bob.circle(bobRef).expiresAt == Date(timeIntervalSince1970: end.timeIntervalSince1970.rounded(.down)))
        #expect(try await bob.circles().map(\.name) == ["Festival 2027"])

        clock.advance(by: 86401)
        #expect(try await bob.circles().isEmpty)
        #expect(try await alice.circles().isEmpty)
        #expect(cloud.rawRecords(circleID: ref.circleID).isEmpty)
    }

    @Test func namesAreValidated() async throws {
        let alice = try client("alice", "Alice")
        await #expect(throws: ClientError.invalidName) { try await alice.createCircle(name: "   ") }
        await #expect(throws: ClientError.invalidName) { try await alice.createCircle(name: String(repeating: "x", count: 41)) }
    }
}
