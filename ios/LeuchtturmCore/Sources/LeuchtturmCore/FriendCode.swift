#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// A friend code like "K7QM-2XRB-9FDA" (12 characters, 60 bits). Whoever
/// has it can find the owner's card in the public iCloud database and send
/// a friend request. The code itself never goes to iCloud: the record name
/// and the card key are derived from it.
public struct FriendCode: Sendable, Hashable, CustomStringConvertible {
    /// 12 characters from `alphabet`, without dashes.
    public let value: String

    /// Crockford base32: no I, L, O, U.
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    public static func generate() -> FriendCode {
        let bytes = randomBytes(8)
        var bits = bytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        var chars: [Character] = []
        for _ in 0 ..< 12 {
            chars.append(alphabet[Int(bits & 31)])
            bits >>= 5
        }
        return FriendCode(value: String(chars))
    }

    private init(value: String) { self.value = value }

    /// Accepts typed or pasted codes: any case, dashes and spaces, O for 0,
    /// I and L for 1, or a `leuchtturm://friend?c=…` link.
    public init?(_ text: String) {
        var raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let components = URLComponents(string: raw), components.scheme == InviteLink.scheme, components.host == "friend",
           let c = components.queryItems?.first(where: { $0.name == "c" })?.value {
            raw = c
        }
        let cleaned = raw.uppercased().compactMap { ch -> Character? in
            switch ch {
            case "-", " ", "\u{2011}", "\u{2013}": nil
            case "O": "0"
            case "I", "L": "1"
            default: ch
            }
        }
        guard cleaned.count == 12, cleaned.allSatisfy(Self.alphabet.contains) else { return nil }
        self.value = String(cleaned)
    }

    /// "K7QM-2XRB-9FDA"
    public var description: String {
        let c = Array(value)
        return [c[0 ..< 4], c[4 ..< 8], c[8 ..< 12]].map { String($0) }.joined(separator: "-")
    }

    public var url: URL {
        var c = URLComponents()
        c.scheme = InviteLink.scheme
        c.host = "friend"
        c.queryItems = [URLQueryItem(name: "c", value: description)]
        return c.url!
    }

    /// Name of the card record in the public database.
    public var recordName: String {
        "fc-" + Base64URL.encode(derive("leuchtturm/v1/friend-code/id", 16))
    }

    var cardKey: SymmetricKey { SymmetricKey(data: derive("leuchtturm/v1/friend-code/key", 32)) }

    private func derive(_ info: String, _ count: Int) -> Data {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(value.utf8)), info: Data(info.utf8), outputByteCount: count)
            .withUnsafeBytes { Data($0) }
    }
}

/// What the friend code reveals: who it belongs to and where to send requests.
public struct FriendCard: Sendable, Equatable, Codable {
    /// Random ID; requests are addressed to it.
    public let mailbox: String
    public let name: String
    /// The owner's device keys (X25519 for the request, Ed25519 for the safety code).
    public let agreementKey: Data
    public let signingKey: Data

    public init(mailbox: String, name: String, agreementKey: Data, signingKey: Data) {
        self.mailbox = mailbox
        self.name = name
        self.agreementKey = agreementKey
        self.signingKey = signingKey
    }

    public var safetyCode: String { DeviceID.safetyCode(signingPublicKey: signingKey, agreementPublicKey: agreementKey) }

    var isValid: Bool {
        DeviceID.raw(mailbox) != nil && !name.isEmpty && name.count <= 60 && agreementKey.count == 32 && signingKey.count == 32
    }
}

/// A friend request: the sender started a friendship (a circle of two) and
/// sends the invite, encrypted to the recipient's device key.
public struct FriendRequest: Sendable, Equatable, Codable {
    public let name: String
    public let invite: URL
    public let agreementKey: Data
    public let signingKey: Data
    public let timestamp: Date

    public init(name: String, invite: URL, agreementKey: Data, signingKey: Data, timestamp: Date) {
        self.name = name
        self.invite = invite
        self.agreementKey = agreementKey
        self.signingKey = signingKey
        self.timestamp = Date(timeIntervalSince1970: timestamp.timeIntervalSince1970.rounded(.down))
    }

    public var safetyCode: String { DeviceID.safetyCode(signingPublicKey: signingKey, agreementPublicKey: agreementKey) }

    /// Requests older than this are ignored (and deleted by their sender);
    /// as long as the invite inside lasts.
    public static let lifetime: TimeInterval = 7 * 86400

    var isValid: Bool {
        !name.isEmpty && name.count <= 60 && agreementKey.count == 32 && signingKey.count == 32 && InviteLink(url: invite) != nil
    }
}

extension CircleCrypto {
    /// ChaCha20-Poly1305 under the code-derived key, AAD = record name.
    public static func sealFriendCard(_ card: FriendCard, code: FriendCode) throws -> Data {
        guard card.isValid else { throw ProtocolError.malformed }
        var json = try JSONEncoder().encode(card)
        json.append(Data(repeating: 0x20, count: (256 - json.count % 256) % 256))
        return try ChaChaPoly.seal(json, using: code.cardKey, authenticating: Data(code.recordName.utf8)).combined
    }

    public static func openFriendCard(_ blob: Data, code: FriendCode) throws -> FriendCard {
        let plain = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: blob), using: code.cardKey, authenticating: Data(code.recordName.utf8))
        let card = try JSONDecoder().decode(FriendCard.self, from: plain)
        guard card.isValid else { throw ProtocolError.malformed }
        return card
    }

    /// HPKE base mode to the recipient's key. Layout: `0x01 | enc (32) | ciphertext`.
    public static func sealFriendRequest(_ request: FriendRequest, to card: FriendCard) throws -> Data {
        guard request.isValid else { throw ProtocolError.malformed }
        let key = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: card.agreementKey)
        var hpke = try HPKE.Sender(recipientKey: key, ciphersuite: suite, info: friendRequestInfo(card.mailbox))
        var json = try JSONEncoder().encode(request)
        json.append(Data(repeating: 0x20, count: (512 - json.count % 512) % 512))
        var out = Data([version])
        out.append(hpke.encapsulatedKey)
        out.append(try hpke.seal(json))
        return out
    }

    public static func openFriendRequest(_ blob: Data, mailbox: String, recipient: DeviceIdentity) throws -> FriendRequest {
        var reader = ByteReader(blob)
        let v = try reader.readByte()
        guard v == version else { throw ProtocolError.unsupportedVersion(v) }
        let encapsulated = try reader.read(32)
        var hpke = try HPKE.Recipient(
            privateKey: recipient.agreementKey, ciphersuite: suite, info: friendRequestInfo(mailbox), encapsulatedKey: encapsulated
        )
        let request = try JSONDecoder().decode(FriendRequest.self, from: try hpke.open(reader.rest()))
        guard request.isValid else { throw ProtocolError.malformed }
        return request
    }

    static func friendRequestInfo(_ mailbox: String) -> Data {
        Wire.context("leuchtturm/v1/friend-request", mailbox)
    }
}
