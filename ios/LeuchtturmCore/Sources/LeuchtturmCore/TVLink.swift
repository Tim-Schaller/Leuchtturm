#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// An Apple TV that shows the family map. The TV makes its own key and a
/// pairing secret and shows both as a QR code:
///
///     leuchtturm://tv?v=1&id=<tv id>&k=<X25519 public key>&s=<secret>
///
/// The iPhone scans it and from then on leaves an encrypted snapshot for
/// the TV in the user's private iCloud database. The TV holds no circle
/// keys and cannot write anything.
public struct TVPairing: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    /// The TV's X25519 public key.
    public let agreementKey: Data
    /// Proves that a snapshot comes from a device that scanned the code.
    public let secret: Data

    public init(id: String, agreementKey: Data, secret: Data) {
        self.id = id
        self.agreementKey = agreementKey
        self.secret = secret
    }

    public var url: URL {
        var c = URLComponents()
        c.scheme = InviteLink.scheme
        c.host = "tv"
        c.queryItems = [
            URLQueryItem(name: "v", value: "1"),
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "k", value: Base64URL.encode(agreementKey)),
            URLQueryItem(name: "s", value: Base64URL.encode(secret)),
        ]
        return c.url!
    }

    public init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == InviteLink.scheme, components.host == "tv"
        else { return nil }
        var items: [String: String] = [:]
        for item in components.queryItems ?? [] {
            if let value = item.value { items[item.name] = value }
        }
        guard items["v"] == "1", let id = items["id"], DeviceID.raw(id) != nil,
              let k = items["k"], let key = Base64URL.decode(k), key.count == 32,
              (try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: key)) != nil,
              let s = items["s"], let secret = Base64URL.decode(s), secret.count == 32
        else { return nil }
        self.init(id: id, agreementKey: key, secret: secret)
    }

    /// The iCloud record name of this TV's snapshot.
    public var recordName: String { "tv-" + id }
}

/// The TV's side: its private key and the pairing it shows.
public struct TVIdentity: Sendable {
    public let agreementKeyRaw: Data
    public let pairing: TVPairing

    static let account = "tv.identity.v1"

    public static func generate() -> TVIdentity {
        let key = Curve25519.KeyAgreement.PrivateKey()
        return TVIdentity(
            agreementKeyRaw: key.rawRepresentation,
            pairing: TVPairing(id: Base64URL.encode(randomBytes(16)), agreementKey: key.publicKey.rawRepresentation, secret: randomBytes(32))
        )
    }

    init(agreementKeyRaw: Data, pairing: TVPairing) {
        self.agreementKeyRaw = agreementKeyRaw
        self.pairing = pairing
    }

    /// The stored identity, or a new one. `reset` starts over (new code).
    public static func loadOrCreate(in store: any SecretStore, reset: Bool = false) throws -> TVIdentity {
        if !reset, let data = try store.load(account), data.count == 32 + 16 + 32,
           let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data.prefix(32)) {
            let id = Base64URL.encode(data.dropFirst(32).prefix(16))
            return TVIdentity(
                agreementKeyRaw: key.rawRepresentation,
                pairing: TVPairing(id: id, agreementKey: key.publicKey.rawRepresentation, secret: Data(data.suffix(32)))
            )
        }
        let identity = generate()
        try store.save(identity.agreementKeyRaw + DeviceID.raw(identity.pairing.id)! + identity.pairing.secret, for: account)
        return identity
    }
}

extension CircleCrypto {
    /// Seals a snapshot for a paired TV (HPKE PSK mode with the pairing
    /// secret). Layout: `0x01 | enc (32) | ciphertext`; the plaintext is
    /// padded to a multiple of 4 KiB so the size says little about it.
    public static func sealForTV(_ snapshot: Data, to tv: TVPairing) throws -> Data {
        let recipient: Curve25519.KeyAgreement.PublicKey
        do {
            recipient = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: tv.agreementKey)
        } catch {
            throw ProtocolError.invalidKey
        }
        var hpke = try HPKE.Sender(
            recipientKey: recipient, ciphersuite: suite, info: tvInfo(tv.id),
            presharedKey: SymmetricKey(data: tv.secret), presharedKeyIdentifier: Data(tv.id.utf8)
        )
        guard snapshot.count <= 4_000_000 else { throw ProtocolError.malformed }
        var plain = Wire.bigEndian(UInt64(snapshot.count)) + snapshot
        plain.append(Data(count: (4096 - plain.count % 4096) % 4096))
        var out = Data([version])
        out.append(hpke.encapsulatedKey)
        out.append(try hpke.seal(plain))
        return out
    }

    /// Opens a snapshot on the TV. Throws for anything not sealed by a
    /// device that knows the pairing secret.
    public static func openOnTV(_ blob: Data, identity: TVIdentity) throws -> Data {
        var reader = ByteReader(blob)
        let v = try reader.readByte()
        guard v == version else { throw ProtocolError.unsupportedVersion(v) }
        let encapsulated = try reader.read(32)
        let tv = identity.pairing
        var hpke = try HPKE.Recipient(
            privateKey: Curve25519.KeyAgreement.PrivateKey(rawRepresentation: identity.agreementKeyRaw), ciphersuite: suite,
            info: tvInfo(tv.id), encapsulatedKey: encapsulated,
            presharedKey: SymmetricKey(data: tv.secret), presharedKeyIdentifier: Data(tv.id.utf8)
        )
        let plain = try hpke.open(reader.rest())
        var inner = ByteReader(plain)
        let length = try inner.readUInt64()
        guard length <= UInt64(plain.count - 8) else { throw ProtocolError.malformed }
        return try inner.read(Int(length))
    }

    static func tvInfo(_ id: String) -> Data {
        Wire.context("leuchtturm/v1/tv-snapshot", id)
    }
}
