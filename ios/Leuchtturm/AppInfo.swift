import Foundation

enum AppInfo {
    static let name = "Leuchtturm"
}

/// Parses the server address typed during setup.
enum ServerAddress {
    /// Accepts "host", "host:port" or a full URL. HTTPS is required except for
    /// local development addresses (localhost, *.local, private IPv4 ranges).
    static func parse(_ input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.query == nil, components.fragment == nil,
              components.user == nil, components.password == nil
        else { return nil }
        switch scheme {
        case "https":
            break
        case "http":
            guard isLocal(host) else { return nil }
        default:
            return nil
        }
        return components.url
    }

    static func isLocal(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".local") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0 ... 255).contains($0) }) else { return false }
        switch (parts[0], parts[1]) {
        case (10, _), (127, _), (192, 168): return true
        case (172, 16 ... 31): return true
        default: return false
        }
    }
}
