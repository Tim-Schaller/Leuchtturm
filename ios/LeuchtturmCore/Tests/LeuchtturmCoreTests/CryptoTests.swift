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

    @Test func invitePayloadRoundTrip() throws {
        let keys = CircleCrypto.inviteKeys(secret: randomBytes(32))
        let key = CircleCrypto.newCircleKey()
        let sealed = try CircleCrypto.sealInvitePayload(circleKey: key, epoch: 5, circleID: circleID, keys: keys)
        let (got, epoch) = try CircleCrypto.openInvitePayload(sealed, circleID: circleID, keys: keys)
        #expect(got == key && epoch == 5)

        #expect(throws: (any Error).self) {
            try CircleCrypto.openInvitePayload(sealed, circleID: CircleCrypto.newCircleID(), keys: keys)
        }
        let other = CircleCrypto.inviteKeys(secret: randomBytes(32))
        #expect(throws: (any Error).self) { try CircleCrypto.openInvitePayload(sealed, circleID: circleID, keys: other) }
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
        let short = try CircleCrypto.sealCircleMeta(CircleMeta(name: "Ai"), key: key, epoch: 1, circleID: circleID)
        let long = try CircleCrypto.sealCircleMeta(CircleMeta(name: "Familie Schaller"), key: key, epoch: 1, circleID: circleID)
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
    @Test func roundTrip() throws {
        let link = InviteLink(server: URL(string: "https://lt.example.org")!, inviteID: CircleCrypto.newCircleID(), secret: randomBytes(32))
        let parsed = InviteLink(string: link.url.absoluteString)
        #expect(parsed == link)
        #expect(InviteLink(string: "  \(link.url.absoluteString)\n") == link)
    }

    @Test func rejectsGarbage() {
        #expect(InviteLink(string: "https://example.org") == nil)
        #expect(InviteLink(string: "leuchtturm://join?v=1&server=https://a.b&id=short&k=AA") == nil)
        #expect(InviteLink(string: "leuchtturm://join?v=2") == nil)
        let id = CircleCrypto.newCircleID()
        let k = Base64URL.encode(randomBytes(32))
        #expect(InviteLink(string: "leuchtturm://join?v=1&server=ftp://a.b&id=\(id)&k=\(k)") == nil)
        #expect(InviteLink(string: "leuchtturm://join?v=1&server=https://a.b&id=\(id)&k=\(k)") != nil)
    }
}
