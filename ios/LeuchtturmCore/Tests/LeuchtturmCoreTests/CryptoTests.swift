#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import Testing
@testable import LeuchtturmCore

struct EncodingTests {
    @Test func base64URLRoundTrip() {
        for n in 0 ..< 40 {
            let data = Data((0 ..< n).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 250) })
            let s = Base64URL.encode(data)
            #expect(!s.contains("=") && !s.contains("+") && !s.contains("/"))
            #expect(Base64URL.decode(s) == data)
        }
    }

    @Test func base64URLRejectsStandardAlphabetAndPadding() {
        #expect(Base64URL.decode("ab+c") == nil)
        #expect(Base64URL.decode("ab/c") == nil)
        #expect(Base64URL.decode("YQ==") == nil)
        #expect(Base64URL.decode("a") == nil)
    }

    @Test func contextIsUnambiguous() {
        #expect(Wire.context("x", "ab", "c") != Wire.context("x", "a", "bc"))
    }

    @Test func byteReaderThrowsOnShortInput() {
        var r = ByteReader(Data([1, 2]))
        #expect(throws: ProtocolError.malformed) { try r.read(3) }
    }
}

struct CircleCryptoTests {
    let alice = DeviceIdentity.generate()
    let bob = DeviceIdentity.generate()
    let mallory = DeviceIdentity.generate()
    let circleID = CircleCrypto.newCircleID()

    func wrapForBob(_ key: SymmetricKey, epoch: Int64 = 3) throws -> Data {
        try CircleCrypto.wrap(
            circleKey: key, circleID: circleID, epoch: epoch,
            recipientDeviceID: bob.deviceID, recipientAgreementKey: bob.agreementPublicKey, sender: alice
        )
    }

    func lookup(_ id: String) -> Data? {
        [alice.deviceID: alice.agreementPublicKey, mallory.deviceID: mallory.agreementPublicKey][id]
    }

    @Test func wrapUnwrapRoundTrip() throws {
        let key = CircleCrypto.newCircleKey()
        let blob = try wrapForBob(key)
        #expect(blob.count == 1 + 16 + 32 + 32 + 16)
        let (got, sender) = try CircleCrypto.unwrap(blob, circleID: circleID, epoch: 3, recipient: bob, senderAgreementKey: lookup)
        #expect(got == key)
        #expect(sender == alice.deviceID)
    }

    @Test func unwrapFailsForWrongContext() throws {
        let blob = try wrapForBob(CircleCrypto.newCircleKey())
        #expect(throws: (any Error).self) {
            try CircleCrypto.unwrap(blob, circleID: circleID, epoch: 4, recipient: bob, senderAgreementKey: lookup)
        }
        #expect(throws: (any Error).self) {
            try CircleCrypto.unwrap(blob, circleID: CircleCrypto.newCircleID(), epoch: 3, recipient: bob, senderAgreementKey: lookup)
        }
        #expect(throws: (any Error).self) {
            try CircleCrypto.unwrap(blob, circleID: circleID, epoch: 3, recipient: mallory, senderAgreementKey: lookup)
        }
    }

    @Test func unwrapRejectsUnknownOrForgedSender() throws {
        let blob = try wrapForBob(CircleCrypto.newCircleKey())
        #expect(throws: ProtocolError.untrustedSender) {
            try CircleCrypto.unwrap(blob, circleID: circleID, epoch: 3, recipient: bob) { _ in nil }
        }
        // Claiming Mallory as sender fails authentication (HPKE auth mode).
        var forged = blob
        forged.replaceSubrange(1 ..< 17, with: DeviceID.raw(mallory.deviceID)!)
        #expect(throws: (any Error).self) {
            try CircleCrypto.unwrap(forged, circleID: circleID, epoch: 3, recipient: bob, senderAgreementKey: lookup)
        }
    }

    @Test func unwrapRejectsTampering() throws {
        var blob = try wrapForBob(CircleCrypto.newCircleKey())
        blob[blob.count - 1] ^= 1
        #expect(throws: (any Error).self) {
            try CircleCrypto.unwrap(blob, circleID: circleID, epoch: 3, recipient: bob, senderAgreementKey: lookup)
        }
        #expect(throws: ProtocolError.unsupportedVersion(9)) {
            try CircleCrypto.unwrap(Data([9]) + blob.dropFirst(), circleID: circleID, epoch: 3, recipient: bob, senderAgreementKey: lookup)
        }
    }

    func payload(_ key: SymmetricKey, expires: Int64 = 2_000_000_000) -> InvitePayload {
        InvitePayload(
            epoch: 5, expiresAt: expires, circleKeyData: key.rawData,
            ownerSigningKey: alice.signingPublicKey, ownerAgreementKey: alice.agreementPublicKey
        )
    }

    @Test func invitePayloadRoundTrip() throws {
        let keys = CircleCrypto.inviteKeys(secret: randomBytes(32))
        let key = CircleCrypto.newCircleKey()
        let inviteID = CircleCrypto.newCircleID()
        let sealed = try CircleCrypto.sealInvitePayload(payload(key), circleID: circleID, inviteID: inviteID, keys: keys)
        let opened = try CircleCrypto.openInvitePayload(sealed, circleID: circleID, inviteID: inviteID, keys: keys)
        #expect(opened == payload(key))
        #expect(opened.circleKey == key)

        #expect(throws: (any Error).self) {
            try CircleCrypto.openInvitePayload(sealed, circleID: CircleCrypto.newCircleID(), inviteID: inviteID, keys: keys)
        }
        #expect(throws: (any Error).self) {
            try CircleCrypto.openInvitePayload(sealed, circleID: circleID, inviteID: CircleCrypto.newCircleID(), keys: keys)
        }
        let other = CircleCrypto.inviteKeys(secret: randomBytes(32))
        #expect(throws: (any Error).self) {
            try CircleCrypto.openInvitePayload(sealed, circleID: circleID, inviteID: inviteID, keys: other)
        }
    }

    @Test func inviteTokenAndAdmissionProof() throws {
        let key = CircleCrypto.newCircleKey()
        let inviteID = CircleCrypto.newCircleID()
        let keys = CircleCrypto.inviteKeys(secret: randomBytes(32))
        let blob = try CircleCrypto.sealInviteToken(keys.authToken, key: key, epoch: 1, circleID: circleID, inviteID: inviteID)
        let token = try #require(try CircleCrypto.openInviteToken(blob, circleID: circleID, inviteID: inviteID) { _ in key })
        #expect(token == keys.authToken)

        let proof = CircleCrypto.admissionProof(
            authToken: token, circleID: circleID, deviceID: bob.deviceID,
            signingKey: bob.signingPublicKey, agreementKey: bob.agreementPublicKey
        )
        #expect(CircleCrypto.verifyAdmissionProof(
            proof, authToken: token, circleID: circleID, deviceID: bob.deviceID,
            signingKey: bob.signingPublicKey, agreementKey: bob.agreementPublicKey
        ))
        // A proof cannot be moved to another device or circle.
        #expect(!CircleCrypto.verifyAdmissionProof(
            proof, authToken: token, circleID: circleID, deviceID: mallory.deviceID,
            signingKey: mallory.signingPublicKey, agreementKey: mallory.agreementPublicKey
        ))
        #expect(!CircleCrypto.verifyAdmissionProof(
            proof, authToken: token, circleID: CircleCrypto.newCircleID(), deviceID: bob.deviceID,
            signingKey: bob.signingPublicKey, agreementKey: bob.agreementPublicKey
        ))
    }

    @Test func recordStatementsAreSigned() throws {
        let statement = CircleCrypto.circleRecordStatement(circleID: circleID, epoch: 2, meta: Data([1, 2, 3]))
        let sig = try alice.sign(statement)
        #expect(CircleCrypto.verifySignature(sig, publicKey: alice.signingPublicKey, message: statement))
        #expect(!CircleCrypto.verifySignature(sig, publicKey: bob.signingPublicKey, message: statement))
        let otherEpoch = CircleCrypto.circleRecordStatement(circleID: circleID, epoch: 3, meta: Data([1, 2, 3]))
        #expect(!CircleCrypto.verifySignature(sig, publicKey: alice.signingPublicKey, message: otherEpoch))

        // Length prefixes keep fields from sliding into each other.
        let a = CircleCrypto.memberRecordStatement(circleID: circleID, deviceID: "d", inviteID: "", signingKey: Data([1]), agreementKey: Data([2, 3]), card: Data(), proof: Data())
        let b = CircleCrypto.memberRecordStatement(circleID: circleID, deviceID: "d", inviteID: "", signingKey: Data([1, 2]), agreementKey: Data([3]), card: Data(), proof: Data())
        #expect(a != b)
    }

    @Test func memberCardRoundTripAndBinding() throws {
        let key = CircleCrypto.newCircleKey()
        let blob = try CircleCrypto.sealMemberCard(MemberCard(name: "Tim"), key: key, epoch: 2, circleID: circleID, deviceID: alice.deviceID)
        #expect(CircleCrypto.contentEpoch(blob) == 2)

        let opened = try CircleCrypto.openMemberCard(blob, circleID: circleID, deviceID: alice.deviceID) { $0 == 2 ? key : nil }
        #expect(opened?.card.name == "Tim" && opened?.epoch == 2)

        // Unknown epoch key: nil, not an error.
        #expect(try CircleCrypto.openMemberCard(blob, circleID: circleID, deviceID: alice.deviceID) { _ in nil } == nil)
        // The server cannot move Alice's card to Bob.
        #expect(throws: (any Error).self) {
            try CircleCrypto.openMemberCard(blob, circleID: circleID, deviceID: bob.deviceID) { _ in key }
        }
        // Rewriting the epoch header is detected.
        var relabeled = blob
        relabeled[8] = 3
        #expect(throws: (any Error).self) {
            try CircleCrypto.openMemberCard(relabeled, circleID: circleID, deviceID: alice.deviceID) { _ in key }
        }
        // The placeholder card used while joining.
        #expect(try CircleCrypto.openMemberCard(CircleCrypto.emptyCard, circleID: circleID, deviceID: alice.deviceID) { _ in key } == nil)
    }

    @Test func paddingHidesNameLength() throws {
        let key = CircleCrypto.newCircleKey()
        let short = try CircleCrypto.sealCircleMeta(CircleMeta(name: "Ai", members: []), key: key, epoch: 1, circleID: circleID)
        let long = try CircleCrypto.sealCircleMeta(CircleMeta(name: "Familie Schaller", members: []), key: key, epoch: 1, circleID: circleID)
        #expect(short.count == long.count)
        let opened = try CircleCrypto.openCircleMeta(long, circleID: circleID) { _ in key }
        #expect(opened?.meta.name == "Familie Schaller")
    }

    @Test func padRoundTrip() throws {
        for n in [0, 1, 61, 62, 63, 64, 200] {
            let data = Data(repeating: 7, count: n)
            let padded = try CircleCrypto.pad(data)
            #expect(padded.count % CircleCrypto.padBlock == 0)
            #expect(try CircleCrypto.unpad(padded) == data)
        }
    }

    @Test func safetyCodeFormat() {
        let code = DeviceID.safetyCode(signingPublicKey: alice.signingPublicKey, agreementPublicKey: alice.agreementPublicKey)
        #expect(code.count == 14)
        #expect(code.split(separator: " ").count == 3)
    }

    @Test func identityPersistsInStore() throws {
        let store = InMemorySecretStore()
        let a = try DeviceIdentity.loadOrCreate(in: store)
        let b = try DeviceIdentity.loadOrCreate(in: store)
        #expect(a == b)
        #expect(throws: ProtocolError.invalidKey) {
            try DeviceIdentity(signingKeyRaw: Data([1, 2, 3]), agreementKeyRaw: a.agreementKeyRaw)
        }
    }
}

struct InviteLinkTests {
    let share = URL(string: "https://www.icloud.com/share/0abcDEF123#Leuchtturm")!

    @Test func roundTrip() throws {
        let link = InviteLink(shareURL: share, inviteID: CircleCrypto.newCircleID(), secret: randomBytes(32))
        let parsed = InviteLink(string: link.url.absoluteString)
        #expect(parsed == link)
        #expect(InviteLink(string: "  \(link.url.absoluteString)\n") == link)
        var tagged = link
        tagged.environment = "d"
        #expect(InviteLink(url: tagged.url)?.environment == "d")
        #expect(InviteLink(string: link.url.absoluteString + "&e=x")?.environment == nil)
    }

    @Test func rejectsGarbage() {
        let id = CircleCrypto.newCircleID()
        let k = Base64URL.encode(randomBytes(32))
        let s = share.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        #expect(InviteLink(string: "https://example.org") == nil)
        #expect(InviteLink(string: "leuchtturm://join?v=2&share=\(s)&id=short&k=\(k)") == nil)
        #expect(InviteLink(string: "leuchtturm://join?v=1&share=\(s)&id=\(id)&k=\(k)") == nil)
        #expect(InviteLink(string: "leuchtturm://join?v=2&share=http%3A%2F%2Fa.b&id=\(id)&k=\(k)") == nil)
        #expect(InviteLink(string: "leuchtturm://join?v=2&share=\(s)&id=\(id)&k=\(k)") != nil)
    }
}

struct LocationTests {
    @Test func fogHidesThePosition() throws {
        let home = try #require(SharedLocation(latitude: 53.55120, longitude: 9.99370, accuracy: 10, timestamp: Date(), battery: 50))
        let nextDoor = try #require(SharedLocation(latitude: 53.55160, longitude: 9.99410, accuracy: 10, timestamp: Date()))
        let a = try #require(home.inFog(radius: 2000))
        let b = try #require(nextDoor.inFog(radius: 2000))
        // Same cell, same reported point: nothing to average.
        #expect(a.latitude == b.latitude && a.longitude == b.longitude)
        #expect(a.fogRadius == 2000 && a.accuracy >= 2000 && a.battery == 50)
        // Within the cell, but not the real position.
        #expect(abs(a.latitude - home.latitude) < 0.04 && a.latitude != home.latitude)
        #expect(home.inFog(radius: 10) == nil)

        let key = CircleCrypto.newCircleKey()
        let blob = try CircleCrypto.sealLocation(a, key: key, epoch: 1, circleID: "c", deviceID: "d")
        let opened = try #require(try CircleCrypto.openLocation(blob, circleID: "c", deviceID: "d", keyForEpoch: { _ in key }))
        #expect(opened.location == a)
    }
}

struct PlaceTrackerTests {
    let school = CirclePlace(id: "school", creatorID: "x", name: "Schule", emoji: "🏫", latitude: 53.55, longitude: 9.99, radius: 150)!

    /// A position `meters` north of the school.
    func step(_ tracker: inout PlaceTracker, _ meters: Double, accuracy: Double = 10, speed: Double? = nil) -> [PlaceTracker.Event] {
        tracker.update(latitude: 53.55 + meters / 111_320, longitude: 9.99, accuracy: accuracy, speed: speed, places: [school])
    }

    @Test func drivingThroughIsNoArrival() {
        var tracker = PlaceTracker()
        #expect(step(&tracker, 1000, speed: 16).isEmpty)
        #expect(step(&tracker, 50, speed: 16).isEmpty) // 57 km/h past the school
        #expect(step(&tracker, -400, speed: 16).isEmpty) // and no departure either
        #expect(step(&tracker, 30, speed: 2).isEmpty == false) // walking in is an arrival
    }

    @Test func arrivalAndDepartureWithMargin() {
        var tracker = PlaceTracker()
        #expect(step(&tracker, 1000).isEmpty)
        #expect(step(&tracker, 100) == [.arrived(school)])
        #expect(step(&tracker, 120).isEmpty)
        #expect(step(&tracker, 180).isEmpty) // within the leaving margin
        #expect(step(&tracker, 300) == [.left(school)])
    }

    @Test func noArrivalWhenAlreadyThereOrInaccurate() {
        var tracker = PlaceTracker()
        #expect(step(&tracker, 0).isEmpty) // first look: already there
        #expect(tracker.inside == ["school"])
        var other = PlaceTracker()
        _ = step(&other, 1000)
        #expect(step(&other, 0, accuracy: 500).isEmpty) // too inaccurate to tell
    }
}

struct GPXTests {
    @Test func exportsDaysAsTrackSegments() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let days = [
            HistoryDay(deviceID: "d", day: "2027-01-16", points: [HistoryDay.Point(latitude: 53.5, longitude: 9.9, timestamp: t + 86400)]),
            HistoryDay(deviceID: "d", day: "2027-01-15", points: [
                HistoryDay.Point(latitude: 53.55, longitude: 9.99, timestamp: t), HistoryDay.Point(latitude: 53.56, longitude: 10.0, timestamp: t + 60),
            ]),
        ]
        let gpx = HistoryDay.gpx(days, name: "Tim & <Verlauf>")
        #expect(gpx.contains("<name>Tim &amp; &lt;Verlauf&gt;</name>"))
        #expect(gpx.components(separatedBy: "<trkseg>").count == 3)
        #expect(gpx.components(separatedBy: "<trkpt").count == 4)
        #expect(gpx.range(of: "lat=\"53.55\"")!.lowerBound < gpx.range(of: "lat=\"53.5\" ")!.lowerBound)
        #expect(gpx.contains("<time>2027-01-15T"))
    }
}

