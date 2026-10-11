import Foundation
import Testing
@testable import LeuchtturmCore

/// Known-answer tests against docs/test-vectors/crypto-v1.json, generated
/// independently with Go's standard library.
struct VectorTests {
    struct File: Decodable {
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
            .appendingPathComponent("docs/test-vectors/crypto-v1.json")
        return try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
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
