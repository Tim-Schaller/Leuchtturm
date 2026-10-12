import Foundation
import Testing
@testable import LeuchtturmCore

/// Pairing an Apple TV and the snapshots the iPhone leaves for it.
struct TVTests {
    @Test func pairingLinkRoundTrips() throws {
        let identity = TVIdentity.generate()
        let parsed = try #require(TVPairing(url: identity.pairing.url))
        #expect(parsed == identity.pairing)
        #expect(identity.pairing.url.absoluteString.hasPrefix("leuchtturm://tv?v=1&"))
        #expect(TVPairing(url: URL(string: "leuchtturm://tv?v=1&id=x&k=y&s=z")!) == nil)
        #expect(TVPairing(url: URL(string: "https://example.com/tv")!) == nil)
    }

    @Test func identityIsStoredAndCanBeReset() throws {
        let store = InMemorySecretStore()
        let first = try TVIdentity.loadOrCreate(in: store)
        let again = try TVIdentity.loadOrCreate(in: store)
        #expect(again.pairing == first.pairing)
        #expect(again.agreementKeyRaw == first.agreementKeyRaw)
        let fresh = try TVIdentity.loadOrCreate(in: store, reset: true)
        #expect(fresh.pairing != first.pairing)
        #expect(try TVIdentity.loadOrCreate(in: store).pairing == fresh.pairing)
    }

    @Test func snapshotOpensOnlyOnThePairedTV() throws {
        let tv = TVIdentity.generate()
        let snapshot = Data(#"{"people":[]}"#.utf8)
        let blob = try CircleCrypto.sealForTV(snapshot, to: tv.pairing)
        #expect(try CircleCrypto.openOnTV(blob, identity: tv) == snapshot)
        #expect((blob.count - 1 - 32 - 16) % 4096 == 0)

        // Another TV cannot read it.
        #expect(throws: (any Error).self) { try CircleCrypto.openOnTV(blob, identity: TVIdentity.generate()) }
        // Flipped bytes are rejected.
        var tampered = blob
        tampered[tampered.count - 1] ^= 1
        #expect(throws: (any Error).self) { try CircleCrypto.openOnTV(tampered, identity: tv) }
    }

    /// Someone who can write the iCloud database (Apple, in the threat model)
    /// knows the TV's public key but not the secret from the QR code.
    @Test func snapshotWithoutTheSecretIsRejected() throws {
        let tv = TVIdentity.generate()
        let forged = TVPairing(id: tv.pairing.id, agreementKey: tv.pairing.agreementKey, secret: Data(repeating: 7, count: 32))
        let blob = try CircleCrypto.sealForTV(Data("fake".utf8), to: forged)
        #expect(throws: (any Error).self) { try CircleCrypto.openOnTV(blob, identity: tv) }
    }
}
