#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// The device's long-term identity: an Ed25519 signing key (authenticates
/// requests and is the device ID) and an X25519 agreement key (receives
/// wrapped circle keys).
///
/// Keys are kept as raw bytes so the type is trivially `Sendable`.
public struct DeviceIdentity: Sendable, Equatable {
    public let signingKeyRaw: Data
    public let agreementKeyRaw: Data

    public init(signingKeyRaw: Data, agreementKeyRaw: Data) throws {
        do {
            _ = try Curve25519.Signing.PrivateKey(rawRepresentation: signingKeyRaw)
            _ = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: agreementKeyRaw)
        } catch {
            throw ProtocolError.invalidKey
        }
        self.signingKeyRaw = signingKeyRaw
        self.agreementKeyRaw = agreementKeyRaw
    }

    public static func generate() -> DeviceIdentity {
        // Freshly generated keys are always valid.
        try! DeviceIdentity(
            signingKeyRaw: Curve25519.Signing.PrivateKey().rawRepresentation,
            agreementKeyRaw: Curve25519.KeyAgreement.PrivateKey().rawRepresentation
        )
    }

    // Validated in init, so reconstruction cannot fail.
    var signingKey: Curve25519.Signing.PrivateKey {
        try! Curve25519.Signing.PrivateKey(rawRepresentation: signingKeyRaw)
    }

    var agreementKey: Curve25519.KeyAgreement.PrivateKey {
        try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: agreementKeyRaw)
    }

    public var signingPublicKey: Data { signingKey.publicKey.rawRepresentation }
    public var agreementPublicKey: Data { agreementKey.publicKey.rawRepresentation }
    public var deviceID: String { DeviceID.derive(signingPublicKey: signingPublicKey) }

    public func sign(_ message: Data) throws -> Data {
        try signingKey.signature(for: message)
    }
}

public enum DeviceID {
    /// First 16 bytes of SHA-256(signing public key), base64url. Matches the server.
    public static func derive(signingPublicKey: Data) -> String {
        Base64URL.encode(Data(SHA256.hash(data: signingPublicKey)).prefix(16))
    }

    /// Decodes a device or circle ID to its 16 raw bytes.
    public static func raw(_ id: String) -> Data? {
        guard let bytes = Base64URL.decode(id), bytes.count == 16 else { return nil }
        return bytes
    }

    /// Short code people can compare in person to detect a server that
    /// swapped keys ("safety number"). 12 hex digits in groups of four.
    public static func safetyCode(signingPublicKey: Data, agreementPublicKey: Data) -> String {
        let digest = SHA256.hash(data: Wire.context("leuchtturm/v1/safety") + signingPublicKey + agreementPublicKey)
        let hex = Wire.hex(digest.prefix(6))
        return stride(from: 0, to: hex.count, by: 4).map { i in
            let start = hex.index(hex.startIndex, offsetBy: i)
            return String(hex[start ..< hex.index(start, offsetBy: 4)])
        }.joined(separator: " ")
    }
}

extension DeviceIdentity {
    static let signingAccount = "device.signing.v1"
    static let agreementAccount = "device.agreement.v1"

    /// Loads the identity from the secret store, creating one on first use.
    public static func loadOrCreate(in store: any SecretStore) throws -> DeviceIdentity {
        if let s = try store.load(signingAccount), let a = try store.load(agreementAccount) {
            return try DeviceIdentity(signingKeyRaw: s, agreementKeyRaw: a)
        }
        let identity = DeviceIdentity.generate()
        try store.save(identity.signingKeyRaw, for: signingAccount)
        try store.save(identity.agreementKeyRaw, for: agreementAccount)
        return identity
    }
}

/// Random bytes from the system CSPRNG.
func randomBytes(_ count: Int) -> Data {
    precondition(count > 0 && count % 8 == 0)
    return SymmetricKey(size: SymmetricKeySize(bitCount: count * 8)).withUnsafeBytes { Data($0) }
}

extension SymmetricKey {
    var rawData: Data { withUnsafeBytes { Data($0) } }
}
