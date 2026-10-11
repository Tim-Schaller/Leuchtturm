import Foundation

/// Unpadded base64url, as used everywhere in the Leuchtturm protocol.
public enum Base64URL {
    public static func encode(_ data: some DataProtocol) -> String {
        Data(data).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Decodes unpadded base64url. Returns nil for padded or standard base64.
    public static func decode(_ string: String) -> Data? {
        if string.contains(where: { $0 == "+" || $0 == "/" || $0 == "=" }) { return nil }
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        switch s.utf8.count % 4 {
        case 0: break
        case 2: s += "=="
        case 3: s += "="
        default: return nil
        }
        return Data(base64Encoded: s)
    }
}

/// Bytes that travel as a base64url JSON string.
public struct B64Data: Codable, Hashable, Sendable {
    public var bytes: Data

    public init(_ bytes: Data) { self.bytes = bytes }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let bytes = Base64URL.decode(string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "invalid base64url")
        }
        self.bytes = bytes
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Base64URL.encode(bytes))
    }
}

/// Errors raised while parsing or decrypting protocol data.
public enum ProtocolError: Error, Sendable, Equatable {
    case malformed
    case unsupportedVersion(UInt8)
    case invalidKey
    case untrustedSender
    case epochMismatch
}

/// Helpers for the binary wire formats.
enum Wire {
    /// Unambiguous context string: label followed by length-prefixed parts.
    static func context(_ label: String, _ parts: String...) -> Data {
        var out = Data(label.utf8)
        for part in parts {
            let bytes = Data(part.utf8)
            precondition(bytes.count <= Int(UInt16.max), "context part too long")
            out.append(UInt8(truncatingIfNeeded: bytes.count >> 8))
            out.append(UInt8(truncatingIfNeeded: bytes.count))
            out.append(bytes)
        }
        return out
    }

    static func bigEndian(_ value: UInt64) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    static func hex(_ bytes: some Sequence<UInt8>) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out: [UInt8] = []
        for b in bytes {
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }
}

/// Sequential reader over a byte buffer. Throws `ProtocolError.malformed`
/// instead of trapping on short input.
struct ByteReader {
    private let bytes: [UInt8]
    private(set) var offset = 0

    init(_ data: Data) { bytes = Array(data) }

    var remaining: Int { bytes.count - offset }

    mutating func read(_ count: Int) throws -> Data {
        guard count >= 0, remaining >= count else { throw ProtocolError.malformed }
        defer { offset += count }
        return Data(bytes[offset ..< offset + count])
    }

    mutating func readByte() throws -> UInt8 {
        guard remaining >= 1 else { throw ProtocolError.malformed }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func readUInt64() throws -> UInt64 {
        try read(8).reduce(0) { ($0 << 8) | UInt64($1) }
    }

    mutating func rest() -> Data {
        defer { offset = bytes.count }
        return Data(bytes[offset...])
    }
}
