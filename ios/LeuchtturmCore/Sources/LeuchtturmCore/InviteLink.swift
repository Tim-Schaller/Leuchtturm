import Foundation

/// An invite as shared via link or QR code:
///
///     leuchtturm://join?v=1&server=<url>&id=<invite id>&k=<secret>
///
/// The secret never reaches the server; only a hash of a key derived from
/// it does. Anyone holding the link can join until it expires or is used up,
/// so it should only be shared through a private channel.
public struct InviteLink: Sendable, Equatable, Identifiable {
    public static let scheme = "leuchtturm"

    public var id: String { inviteID }

    public let server: URL
    public let inviteID: String
    public let secret: Data

    public init(server: URL, inviteID: String, secret: Data) {
        self.server = server
        self.inviteID = inviteID
        self.secret = secret
    }

    public var url: URL {
        var c = URLComponents()
        c.scheme = Self.scheme
        c.host = "join"
        c.queryItems = [
            URLQueryItem(name: "v", value: "1"),
            URLQueryItem(name: "server", value: server.absoluteString),
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
        guard items["v"] == "1",
              let serverString = items["server"], let server = URL(string: serverString),
              server.scheme == "https" || server.scheme == "http", server.host != nil,
              let id = items["id"], DeviceID.raw(id) != nil,
              let k = items["k"], let secret = Base64URL.decode(k), secret.count == 32
        else { return nil }
        self.init(server: server, inviteID: id, secret: secret)
    }

    public init?(url: URL) {
        self.init(string: url.absoluteString)
    }
}
