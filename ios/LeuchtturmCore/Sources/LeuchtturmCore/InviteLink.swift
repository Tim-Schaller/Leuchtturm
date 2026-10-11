import Foundation

/// An invite as shared via link or QR code:
///
///     leuchtturm://join?v=2&share=<iCloud share URL>&id=<invite id>&k=<secret>
///
/// The share URL gives access to the circle's (encrypted) iCloud zone; the
/// secret decrypts the circle key and proves the invite to other members.
/// The secret never reaches Apple. Anyone holding the full link can join
/// until it expires, so share it only through a private channel.
public struct InviteLink: Sendable, Equatable, Identifiable {
    public static let scheme = "leuchtturm"

    public var id: String { inviteID }

    public let shareURL: URL
    public let inviteID: String
    public let secret: Data

    public init(shareURL: URL, inviteID: String, secret: Data) {
        self.shareURL = shareURL
        self.inviteID = inviteID
        self.secret = secret
    }

    public var url: URL {
        var c = URLComponents()
        c.scheme = Self.scheme
        c.host = "join"
        c.queryItems = [
            URLQueryItem(name: "v", value: "2"),
            URLQueryItem(name: "share", value: shareURL.absoluteString),
            URLQueryItem(name: "id", value: inviteID),
            URLQueryItem(name: "k", value: Base64URL.encode(secret)),
        ]
        return c.url!
    }

    /// Parses a link or pasted text. Returns nil for anything malformed.
    public init?(string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme == Self.scheme, components.host == "join"
        else { return nil }
        var items: [String: String] = [:]
        for item in components.queryItems ?? [] {
            if let value = item.value { items[item.name] = value }
        }
        guard items["v"] == "2",
              let shareString = items["share"], let share = URL(string: shareString),
              share.scheme == "https", share.host != nil,
              let id = items["id"], DeviceID.raw(id) != nil,
              let k = items["k"], let secret = Base64URL.decode(k), secret.count == 32
        else { return nil }
        self.init(shareURL: share, inviteID: id, secret: secret)
    }

    public init?(url: URL) {
        self.init(string: url.absoluteString)
    }
}
