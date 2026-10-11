#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import Testing
@testable import LeuchtturmCore

/// Cross-checks against docs/test-vectors/auth-v1.json, which the Go server
/// tests verify too. If these pass on both sides, client and server agree on
/// request signing, device IDs and invite key derivation.
struct VectorTests {
    struct File: Decodable {
        struct Request: Decodable {
            let seed_hex: String
            let public_key: String
            let method: String
            let request_uri: String
            let ts: Int64
            let nonce: String
            let body: String
            let canonical: String
            let authorization: String
        }
        struct DeviceIDVector: Decodable {
            let signing_key: String
            let device_id: String
        }
        struct Invite: Decodable {
            let secret: String
            let auth_token: String
            let auth_token_hash: String
            let enc_key: String
        }
        let request: Request
        let device_id: DeviceIDVector
        let invite: Invite
    }

    static func load() throws -> File {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // LeuchtturmCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // LeuchtturmCore
            .deletingLastPathComponent() // ios
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("docs/test-vectors/auth-v1.json")
        return try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
    }

    static func hexBytes(_ hex: String) -> Data {
        var out = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            out.append(UInt8(hex[index ..< next], radix: 16)!)
            index = next
        }
        return out
    }

    @Test func publicKeyFromSeed() throws {
        let v = try Self.load().request
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Self.hexBytes(v.seed_hex))
        #expect(Base64URL.encode(key.publicKey.rawRepresentation) == v.public_key)
    }

    @Test func canonicalString() throws {
        let v = try Self.load().request
        let canonical = RequestSigner.canonical(
            method: v.method, requestURI: v.request_uri, timestamp: v.ts, nonce: v.nonce, body: Data(v.body.utf8)
        )
        #expect(String(decoding: canonical, as: UTF8.self) == v.canonical)
    }

    @Test func goSignatureVerifiesInSwift() throws {
        let v = try Self.load().request
        let key = RequestSigner.verify(authorization: v.authorization, method: v.method, requestURI: v.request_uri, body: Data(v.body.utf8))
        #expect(key.map(Base64URL.encode) == v.public_key)
        // Any change to the request must break the signature.
        #expect(RequestSigner.verify(authorization: v.authorization, method: "GET", requestURI: v.request_uri, body: Data(v.body.utf8)) == nil)
        #expect(RequestSigner.verify(authorization: v.authorization, method: v.method, requestURI: v.request_uri, body: Data()) == nil)
    }

    @Test func swiftSignatureVerifies() throws {
        let v = try Self.load().request
        let seed = Self.hexBytes(v.seed_hex)
        let identity = try DeviceIdentity(signingKeyRaw: seed, agreementKeyRaw: Curve25519.KeyAgreement.PrivateKey().rawRepresentation)
        let header = try RequestSigner.authorization(
            identity: identity, method: v.method, requestURI: v.request_uri,
            timestamp: v.ts, nonce: Base64URL.decode(v.nonce)!, body: Data(v.body.utf8)
        )
        // CryptoKit signatures are randomized, so compare everything but sig.
        #expect(header.hasPrefix(v.authorization.components(separatedBy: ",sig=")[0] + ",sig="))
        #expect(RequestSigner.verify(authorization: header, method: v.method, requestURI: v.request_uri, body: Data(v.body.utf8)) != nil)
    }

    @Test func deviceID() throws {
        let v = try Self.load().device_id
        #expect(DeviceID.derive(signingPublicKey: Base64URL.decode(v.signing_key)!) == v.device_id)
    }

    @Test func inviteKeyDerivation() throws {
        let v = try Self.load().invite
        let keys = CircleCrypto.inviteKeys(secret: Base64URL.decode(v.secret)!)
        #expect(Base64URL.encode(keys.authToken) == v.auth_token)
        #expect(Base64URL.encode(keys.authTokenHash) == v.auth_token_hash)
        #expect(Base64URL.encode(keys.encKeyData) == v.enc_key)
    }
}
