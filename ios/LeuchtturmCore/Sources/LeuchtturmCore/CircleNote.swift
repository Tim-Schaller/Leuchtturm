#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// A short message in a circle: an emoji reaction, a quick note, a
/// check-in or a good-morning. Encrypted under the circle key and signed by
/// the sending device.
public struct CircleNote: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        case reaction
        case text
        case checkIn
        case morning
    }

    public let id: String
    /// Device ID of the sender.
    public let senderID: String
    /// Device ID of the person it is for; nil for the whole circle.
    public let recipientID: String?
    public let kind: Kind
    /// Emoji or short text; empty for check-ins and good-mornings.
    public let text: String
    /// Where a check-in happened.
    public let location: SharedLocation?
    public let timestamp: Date

    public static let maxTextLength = 120
    /// Older notes are ignored by readers and deleted by their sender.
    public static let lifetime: TimeInterval = 7 * 24 * 3600
}

/// Plaintext inside a note blob.
private struct NotePayload: Codable {
    let k: CircleNote.Kind
    let x: String
    let to: String?
    let t: Int64
    var loc: CheckInPayload?
}

/// A check-in position inside a note.
private struct CheckInPayload: Codable {
    let lat: Double
    let lon: Double
    let acc: Double
}

extension CircleCrypto {
    static func sealNote(_ note: CircleNote, key: SymmetricKey, epoch: Int64, circleID: String) throws -> Data {
        let payload = NotePayload(
            k: note.kind, x: note.text, to: note.recipientID, t: Int64(note.timestamp.timeIntervalSince1970),
            loc: note.location.map { CheckInPayload(lat: $0.latitude, lon: $0.longitude, acc: $0.accuracy) }
        )
        return try sealContent(JSONEncoder().encode(payload), key: key, epoch: epoch, context: noteContext(circleID: circleID, noteID: note.id))
    }

    /// Returns nil when no key is known for the blob's epoch.
    static func openNote(
        _ blob: Data, id: String, senderID: String, circleID: String, keyForEpoch: (Int64) -> SymmetricKey?
    ) throws -> CircleNote? {
        guard let (plain, _) = try openContent(blob, context: noteContext(circleID: circleID, noteID: id), keyForEpoch: keyForEpoch)
        else { return nil }
        let p = try JSONDecoder().decode(NotePayload.self, from: plain)
        let timestamp = Date(timeIntervalSince1970: TimeInterval(p.t))
        guard p.x.count <= CircleNote.maxTextLength, p.t > 0 else { throw ProtocolError.malformed }
        var location: SharedLocation?
        if let loc = p.loc {
            guard let checked = SharedLocation(latitude: loc.lat, longitude: loc.lon, accuracy: loc.acc, timestamp: timestamp)
            else { throw ProtocolError.malformed }
            location = checked
        }
        return CircleNote(
            id: id, senderID: senderID, recipientID: p.to, kind: p.k, text: p.x, location: location, timestamp: timestamp
        )
    }

    /// Bytes the sending device signs for a note record.
    static func noteRecordStatement(circleID: String, noteID: String, senderID: String, blob: Data) -> Data {
        Wire.context("leuchtturm/v1/note-record", circleID, noteID, senderID) + blob
    }

    static func noteContext(circleID: String, noteID: String) -> Data {
        Wire.context("leuchtturm/v1/note", circleID, noteID)
    }
}
