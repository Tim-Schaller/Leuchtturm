#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// How a member looks: picture, banner, pin and a short status. The same
/// profile goes to all of the member's circles, encrypted under each
/// circle's key and signed by the member's device.
public struct Profile: Sendable, Hashable {
    /// Pin and avatar colour, "#RRGGBB".
    public var color: String?
    /// Shown on the pin instead of initials (one emoji).
    public var emoji: String?
    /// Square JPEG, at most `maxPhotoBytes`.
    public var photo: Data?
    /// Wide JPEG for the top of the member's page, at most `maxBannerBytes`.
    public var banner: Data?
    /// Banner gradient when there is no banner picture, e.g. "meadow".
    public var bannerStyle: String?
    public var statusEmoji: String?
    public var statusText: String?
    /// The status disappears at this time.
    public var statusUntil: Date?

    public static let maxPhotoBytes = 120_000
    public static let maxBannerBytes = 300_000
    public static let maxStatusLength = 40

    public init(
        color: String? = nil, emoji: String? = nil, photo: Data? = nil, banner: Data? = nil, bannerStyle: String? = nil,
        statusEmoji: String? = nil, statusText: String? = nil, statusUntil: Date? = nil
    ) {
        self.color = color
        self.emoji = emoji
        self.photo = photo
        self.banner = banner
        self.bannerStyle = bannerStyle
        self.statusEmoji = statusEmoji
        self.statusText = statusText
        self.statusUntil = statusUntil.map { Date(timeIntervalSince1970: $0.timeIntervalSince1970.rounded(.down)) }
    }

    /// The status, if it has not run out at `now`.
    public func status(at now: Date) -> (emoji: String?, text: String?)? {
        guard statusEmoji != nil || statusText != nil else { return nil }
        if let statusUntil, statusUntil <= now { return nil }
        return (statusEmoji, statusText)
    }

    /// False for oversized pictures, bad colours or long texts.
    public var isValid: Bool {
        let hex = color.map { $0.count == 7 && $0.hasPrefix("#") && $0.dropFirst().allSatisfy(\.isHexDigit) } ?? true
        return hex
            && (photo?.count ?? 0) <= Self.maxPhotoBytes
            && (banner?.count ?? 0) <= Self.maxBannerBytes
            && (emoji?.count ?? 1) == 1 && (statusEmoji?.count ?? 1) == 1
            && (statusText?.count ?? 0) <= Self.maxStatusLength
            && (bannerStyle?.count ?? 0) <= 20
    }
}

private struct ProfilePayload: Codable {
    var c: String?
    var e: String?
    var bs: String?
    var se: String?
    var st: String?
    var su: Int64?
}

/// The encrypted parts of a profile record.
struct SealedProfile {
    /// Small fields, padded like names.
    var blob: Data
    /// Pictures, encrypted on their own (not padded); empty if none.
    var photo: Data
    var banner: Data
}

extension CircleCrypto {
    static func sealProfile(_ profile: Profile, key: SymmetricKey, epoch: Int64, circleID: String, deviceID: String) throws -> SealedProfile {
        let payload = ProfilePayload(
            c: profile.color, e: profile.emoji, bs: profile.bannerStyle, se: profile.statusEmoji, st: profile.statusText,
            su: profile.statusUntil.map { Int64($0.timeIntervalSince1970) }
        )
        let context = profileContext(circleID: circleID, deviceID: deviceID)
        return SealedProfile(
            blob: try sealContent(JSONEncoder().encode(payload), key: key, epoch: epoch, context: context),
            photo: try profile.photo.map { try sealPicture($0, key: key, epoch: epoch, context: context + Data("photo".utf8)) } ?? Data(),
            banner: try profile.banner.map { try sealPicture($0, key: key, epoch: epoch, context: context + Data("banner".utf8)) } ?? Data()
        )
    }

    static func openProfile(
        _ sealed: SealedProfile, circleID: String, deviceID: String, keyForEpoch: (Int64) -> SymmetricKey?
    ) throws -> Profile? {
        let context = profileContext(circleID: circleID, deviceID: deviceID)
        guard let (plain, _) = try openContent(sealed.blob, context: context, keyForEpoch: keyForEpoch) else { return nil }
        let p = try JSONDecoder().decode(ProfilePayload.self, from: plain)
        let profile = Profile(
            color: p.c, emoji: p.e,
            photo: sealed.photo.isEmpty ? nil : try openPicture(sealed.photo, context: context + Data("photo".utf8), keyForEpoch: keyForEpoch),
            banner: sealed.banner.isEmpty ? nil : try openPicture(sealed.banner, context: context + Data("banner".utf8), keyForEpoch: keyForEpoch),
            bannerStyle: p.bs, statusEmoji: p.se, statusText: p.st,
            statusUntil: p.su.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
        guard profile.isValid else { throw ProtocolError.malformed }
        return profile
    }

    /// Layout: `0x01 | epoch (u64) | ChaCha20-Poly1305 combined`, no padding.
    static func sealPicture(_ data: Data, key: SymmetricKey, epoch: Int64, context: Data) throws -> Data {
        var header = Data([version])
        header.append(Wire.bigEndian(UInt64(epoch)))
        return header + (try ChaChaPoly.seal(data, using: key, authenticating: context + header).combined)
    }

    static func openPicture(_ blob: Data, context: Data, keyForEpoch: (Int64) -> SymmetricKey?) throws -> Data? {
        var reader = ByteReader(blob)
        guard try reader.readByte() == version else { throw ProtocolError.malformed }
        let rawEpoch = try reader.readUInt64()
        guard rawEpoch > 0, rawEpoch <= UInt64(Int64.max), let key = keyForEpoch(Int64(rawEpoch)) else { return nil }
        var header = Data([version])
        header.append(Wire.bigEndian(rawEpoch))
        return try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: reader.rest()), using: key, authenticating: context + header)
    }

    static func profileRecordStatement(circleID: String, deviceID: String, sealed: SealedProfile) -> Data {
        var out = Wire.context("leuchtturm/v1/profile-record", circleID, deviceID)
        for part in [sealed.blob, sealed.photo, sealed.banner] {
            out.append(Wire.bigEndian(UInt64(part.count)))
            out.append(part)
        }
        return out
    }

    static func profileContext(circleID: String, deviceID: String) -> Data {
        Wire.context("leuchtturm/v1/profile", circleID, deviceID)
    }
}
