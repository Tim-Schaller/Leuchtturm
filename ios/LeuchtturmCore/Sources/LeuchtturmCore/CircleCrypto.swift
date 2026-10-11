#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Encrypted, user-visible profile of a member inside one circle.
public struct MemberCard: Codable, Sendable, Equatable {
    public var name: String
    public init(name: String) { self.name = name }
}

/// Encrypted circle metadata, written and signed by the owner's device.
public struct CircleMeta: Codable, Sendable, Equatable {
    public var name: String
    /// Device IDs the owner has admitted (the roster).
    public var members: [String]
    /// Unix seconds when a temporary circle ends; nil for a lasting one.
    public var expires: Int64?
    public init(name: String, members: [String], expires: Int64? = nil) {
        self.name = name
        self.members = members
        self.expires = expires
    }
}

/// What a joiner learns from an invite: the circle key and, authenticated
/// by the invite secret, the owner's device keys (the circle's trust anchor).
public struct InvitePayload: Sendable, Equatable {
    public let epoch: Int64
    public let expiresAt: Int64
    public let circleKeyData: Data
    public let ownerSigningKey: Data
    public let ownerAgreementKey: Data

    public var circleKey: SymmetricKey { SymmetricKey(data: circleKeyData) }
}

/// Keys derived from an invite secret.
public struct InviteKeys: Sendable {
    /// Proves knowledge of the secret to the server (server stores only its hash).
    public let authToken: Data
    /// Encrypts the circle key inside the invite. Never leaves the clients.
    let encKeyData: Data

    public var authTokenHash: Data { Data(SHA256.hash(data: authToken)) }
    var encKey: SymmetricKey { SymmetricKey(data: encKeyData) }
}

/// Cryptographic building blocks for circles. All formats are versioned;
/// see docs/ARCHITECTURE.md for the byte layouts.
public enum CircleCrypto {
    static let version: UInt8 = 1
    static let suite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly

    /// A member card that has not been uploaded yet (joining in progress).
    public static let emptyCard = Data([0x00])

    public static func newCircleKey() -> SymmetricKey { SymmetricKey(size: .bits256) }
    public static func newCircleID() -> String { Base64URL.encode(randomBytes(16)) }

    // MARK: Circle key wrapping (HPKE auth mode, X25519 / HKDF-SHA256 / ChaCha20-Poly1305)

    /// Wraps a circle key for one member. Layout: `0x01 | sender id (16) | enc (32) | ciphertext`.
    /// HPKE auth mode proves to the recipient which member wrapped the key.
    public static func wrap(
        circleKey: SymmetricKey, circleID: String, epoch: Int64,
        recipientDeviceID: String, recipientAgreementKey: Data, sender: DeviceIdentity
    ) throws -> Data {
        guard let senderRaw = DeviceID.raw(sender.deviceID) else { throw ProtocolError.malformed }
        let recipientKey: Curve25519.KeyAgreement.PublicKey
        do {
            recipientKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientAgreementKey)
        } catch {
            throw ProtocolError.invalidKey
        }
        var hpke = try HPKE.Sender(
            recipientKey: recipientKey, ciphersuite: suite,
            info: wrapInfo(circleID: circleID, epoch: epoch, recipient: recipientDeviceID),
            authenticatedBy: sender.agreementKey
        )
        let ciphertext = try hpke.seal(circleKey.rawData, authenticating: wrapAAD(sender: sender.deviceID))
        var out = Data([version])
        out.append(senderRaw)
        out.append(hpke.encapsulatedKey)
        out.append(ciphertext)
        return out
    }

    /// Unwraps a circle key. `senderAgreementKey` returns the agreement key of
    /// a current circle member, or nil if the sender is not trusted.
    public static func unwrap(
        _ blob: Data, circleID: String, epoch: Int64, recipient: DeviceIdentity,
        senderAgreementKey: (String) -> Data?
    ) throws -> (key: SymmetricKey, senderDeviceID: String) {
        var reader = ByteReader(blob)
        let v = try reader.readByte()
        guard v == version else { throw ProtocolError.unsupportedVersion(v) }
        let senderID = Base64URL.encode(try reader.read(16))
        let encapsulated = try reader.read(32)
        let ciphertext = reader.rest()
        guard let senderRaw = senderAgreementKey(senderID),
              let senderKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: senderRaw)
        else { throw ProtocolError.untrustedSender }
        var hpke = try HPKE.Recipient(
            privateKey: recipient.agreementKey, ciphersuite: suite,
            info: wrapInfo(circleID: circleID, epoch: epoch, recipient: recipient.deviceID),
            encapsulatedKey: encapsulated, authenticatedBy: senderKey
        )
        let keyData = try hpke.open(ciphertext, authenticating: wrapAAD(sender: senderID))
        guard keyData.count == 32 else { throw ProtocolError.malformed }
        return (SymmetricKey(data: keyData), senderID)
    }

    static func wrapInfo(circleID: String, epoch: Int64, recipient: String) -> Data {
        Wire.context("leuchtturm/v1/circle-key", circleID, String(epoch), recipient)
    }

    static func wrapAAD(sender: String) -> Data {
        Wire.context("leuchtturm/v1/circle-key-sender", sender)
    }

    // MARK: Invites

    /// Derives the invite auth token and encryption key from the invite secret
    /// (HKDF-SHA256, no salt). Matches docs/test-vectors/auth-v1.json.
    public static func inviteKeys(secret: Data) -> InviteKeys {
        let ikm = SymmetricKey(data: secret)
        let auth = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, info: Data("leuchtturm/v1/invite/auth".utf8), outputByteCount: 32)
        let enc = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, info: Data("leuchtturm/v1/invite/enc".utf8), outputByteCount: 32)
        return InviteKeys(authToken: auth.rawData, encKeyData: enc.rawData)
    }

    static let invitePayloadVersion: UInt8 = 2

    /// Seals `0x02 | epoch | expiresAt | circle key (32) | owner signing key (32)
    /// | owner agreement key (32)` with ChaCha20-Poly1305 under the invite
    /// encryption key, bound to circle and invite ID.
    public static func sealInvitePayload(_ payload: InvitePayload, circleID: String, inviteID: String, keys: InviteKeys) throws -> Data {
        guard payload.epoch > 0, payload.expiresAt > 0, payload.circleKeyData.count == 32,
              payload.ownerSigningKey.count == 32, payload.ownerAgreementKey.count == 32
        else { throw ProtocolError.malformed }
        var plain = Data([invitePayloadVersion])
        plain.append(Wire.bigEndian(UInt64(payload.epoch)))
        plain.append(Wire.bigEndian(UInt64(payload.expiresAt)))
        plain.append(payload.circleKeyData)
        plain.append(payload.ownerSigningKey)
        plain.append(payload.ownerAgreementKey)
        return try ChaChaPoly.seal(plain, using: keys.encKey, authenticating: inviteAAD(circleID, inviteID)).combined
    }

    public static func openInvitePayload(_ sealed: Data, circleID: String, inviteID: String, keys: InviteKeys) throws -> InvitePayload {
        let box = try ChaChaPoly.SealedBox(combined: sealed)
        let plain = try ChaChaPoly.open(box, using: keys.encKey, authenticating: inviteAAD(circleID, inviteID))
        var reader = ByteReader(plain)
        let v = try reader.readByte()
        guard v == invitePayloadVersion else { throw ProtocolError.unsupportedVersion(v) }
        let epoch = try reader.readUInt64()
        let expires = try reader.readUInt64()
        let payload = InvitePayload(
            epoch: Int64(clamping: epoch), expiresAt: Int64(clamping: expires),
            circleKeyData: try reader.read(32), ownerSigningKey: try reader.read(32), ownerAgreementKey: try reader.read(32)
        )
        guard reader.remaining == 0, payload.epoch > 0 else { throw ProtocolError.malformed }
        return payload
    }

    static func inviteAAD(_ circleID: String, _ inviteID: String) -> Data {
        Wire.context("leuchtturm/v1/invite", circleID, inviteID)
    }

    /// The invite auth token, encrypted under the circle key so every member
    /// (but not Apple) can check admission proofs made with it.
    public static func sealInviteToken(_ token: Data, key: SymmetricKey, epoch: Int64, circleID: String, inviteID: String) throws -> Data {
        try sealContent(token, key: key, epoch: epoch, context: Wire.context("leuchtturm/v1/invite-token", circleID, inviteID))
    }

    public static func openInviteToken(_ blob: Data, circleID: String, inviteID: String, keyForEpoch: (Int64) -> SymmetricKey?) throws -> Data? {
        try openContent(blob, context: Wire.context("leuchtturm/v1/invite-token", circleID, inviteID), keyForEpoch: keyForEpoch)?.0
    }

    // MARK: Admission

    /// Proof that a device knew an invite secret: HMAC-SHA256 under the invite
    /// auth token over the device's identity. Lets members tell invited
    /// devices apart from anyone who merely obtained the iCloud share link.
    public static func admissionProof(authToken: Data, circleID: String, deviceID: String, signingKey: Data, agreementKey: Data) -> Data {
        let message = Wire.context("leuchtturm/v1/admission", circleID, deviceID) + signingKey + agreementKey
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: authToken)))
    }

    public static func verifyAdmissionProof(_ proof: Data, authToken: Data, circleID: String, deviceID: String, signingKey: Data, agreementKey: Data) -> Bool {
        let message = Wire.context("leuchtturm/v1/admission", circleID, deviceID) + signingKey + agreementKey
        return HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: message, using: SymmetricKey(data: authToken))
    }

    // MARK: Signed records

    /// Bytes the owner's device signs for the circle record.
    public static func circleRecordStatement(circleID: String, epoch: Int64, meta: Data) -> Data {
        Wire.context("leuchtturm/v1/circle-record", circleID) + Wire.bigEndian(UInt64(epoch)) + meta
    }

    /// Bytes a device signs for its own member record. Binding the device ID
    /// (= hash of the signing key) makes member records self-authenticating:
    /// nobody else can write a valid record for that device.
    public static func memberRecordStatement(
        circleID: String, deviceID: String, inviteID: String,
        signingKey: Data, agreementKey: Data, card: Data, proof: Data
    ) -> Data {
        var out = Wire.context("leuchtturm/v1/member-record", circleID, deviceID, inviteID)
        for part in [signingKey, agreementKey, card, proof] {
            out.append(Wire.bigEndian(UInt64(part.count)))
            out.append(part)
        }
        return out
    }

    public static func verifySignature(_ signature: Data, publicKey: Data, message: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
        return key.isValidSignature(signature, for: message)
    }

    // MARK: Member cards and circle metadata (encrypted under the circle key)

    public static func sealMemberCard(_ card: MemberCard, key: SymmetricKey, epoch: Int64, circleID: String, deviceID: String) throws -> Data {
        try sealContent(JSONEncoder().encode(card), key: key, epoch: epoch, context: cardContext(circleID: circleID, deviceID: deviceID))
    }

    /// Returns nil for an empty card or when no key is known for its epoch.
    public static func openMemberCard(
        _ blob: Data, circleID: String, deviceID: String, keyForEpoch: (Int64) -> SymmetricKey?
    ) throws -> (card: MemberCard, epoch: Int64)? {
        guard blob != emptyCard else { return nil }
        guard let (plain, epoch) = try openContent(blob, context: cardContext(circleID: circleID, deviceID: deviceID), keyForEpoch: keyForEpoch)
        else { return nil }
        return (try JSONDecoder().decode(MemberCard.self, from: plain), epoch)
    }

    public static func sealCircleMeta(_ meta: CircleMeta, key: SymmetricKey, epoch: Int64, circleID: String) throws -> Data {
        try sealContent(JSONEncoder().encode(meta), key: key, epoch: epoch, context: metaContext(circleID: circleID))
    }

    public static func openCircleMeta(
        _ blob: Data, circleID: String, keyForEpoch: (Int64) -> SymmetricKey?
    ) throws -> (meta: CircleMeta, epoch: Int64)? {
        guard let (plain, epoch) = try openContent(blob, context: metaContext(circleID: circleID), keyForEpoch: keyForEpoch)
        else { return nil }
        return (try JSONDecoder().decode(CircleMeta.self, from: plain), epoch)
    }

    /// Epoch a content blob was encrypted under, readable without a key.
    public static func contentEpoch(_ blob: Data) -> Int64? {
        var reader = ByteReader(blob)
        guard (try? reader.readByte()) == version, let e = try? reader.readUInt64(), e > 0, e <= UInt64(Int64.max)
        else { return nil }
        return Int64(e)
    }

    static func cardContext(circleID: String, deviceID: String) -> Data {
        Wire.context("leuchtturm/v1/member-card", circleID, deviceID)
    }

    static func metaContext(circleID: String) -> Data {
        Wire.context("leuchtturm/v1/circle-meta", circleID)
    }

    /// Layout: `0x01 | epoch (u64 BE) | ChaCha20-Poly1305(nonce | ct | tag)`.
    /// The header is authenticated; the plaintext is padded to 64-byte blocks
    /// so the server cannot infer name lengths.
    static func sealContent(_ plaintext: Data, key: SymmetricKey, epoch: Int64, context: Data) throws -> Data {
        guard epoch > 0 else { throw ProtocolError.malformed }
        var header = Data([version])
        header.append(Wire.bigEndian(UInt64(epoch)))
        let box = try ChaChaPoly.seal(try pad(plaintext), using: key, authenticating: context + header)
        return header + box.combined
    }

    static func openContent(_ blob: Data, context: Data, keyForEpoch: (Int64) -> SymmetricKey?) throws -> (Data, Int64)? {
        var reader = ByteReader(blob)
        let v = try reader.readByte()
        guard v == version else { throw ProtocolError.unsupportedVersion(v) }
        let rawEpoch = try reader.readUInt64()
        guard rawEpoch > 0, rawEpoch <= UInt64(Int64.max) else { throw ProtocolError.malformed }
        let epoch = Int64(rawEpoch)
        guard let key = keyForEpoch(epoch) else { return nil }
        var header = Data([version])
        header.append(Wire.bigEndian(rawEpoch))
        let box = try ChaChaPoly.SealedBox(combined: reader.rest())
        let padded = try ChaChaPoly.open(box, using: key, authenticating: context + header)
        return (try unpad(padded), epoch)
    }

    static let padBlock = 64

    static func pad(_ data: Data) throws -> Data {
        guard data.count <= Int(UInt16.max) - 2 else { throw ProtocolError.malformed }
        var out = Data([UInt8(truncatingIfNeeded: data.count >> 8), UInt8(truncatingIfNeeded: data.count)])
        out.append(data)
        let target = ((out.count + padBlock - 1) / padBlock) * padBlock
        out.append(Data(count: target - out.count))
        return out
    }

    static func unpad(_ data: Data) throws -> Data {
        var reader = ByteReader(data)
        let length = Int(try reader.readByte()) << 8 | Int(try reader.readByte())
        return try reader.read(length)
    }
}
