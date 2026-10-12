import Foundation

/// Every record type and field Leuchtturm writes to iCloud. Debug builds use
/// it to create the whole CloudKit schema in one go before it is deployed
/// to Production; a test checks that the client writes nothing else.
public enum CloudSchema {
    public enum Kind: String, Sendable {
        case bytes, int, string
    }

    /// Circle zones: in the owner's private database, shared with members.
    public static let zoneRecords: [String: [String: Kind]] = [
        RecordType.circle: ["epoch": .int, "meta": .bytes, "sig": .bytes],
        RecordType.member: ["skey": .bytes, "akey": .bytes, "card": .bytes, "invite": .string, "proof": .bytes, "sig": .bytes],
        RecordType.keyWrap: ["epoch": .int, "device": .string, "blob": .bytes],
        RecordType.invite: ["epoch": .int, "sealed": .bytes, "token": .bytes, "expires": .int],
        RecordType.location: ["blob": .bytes, "sig": .bytes],
        RecordType.note: ["from": .string, "blob": .bytes, "sig": .bytes],
        RecordType.place: ["from": .string, "blob": .bytes, "sig": .bytes],
        RecordType.history: ["from": .string, "day": .string, "blob": .bytes, "sig": .bytes],
        RecordType.trip: ["from": .string, "blob": .bytes, "sig": .bytes],
        RecordType.move: ["from": .string, "blob": .bytes, "sig": .bytes],
        RecordType.profile: ["blob": .bytes, "photo": .bytes, "banner": .bytes, "sig": .bytes],
        RecordType.message: ["from": .string, "blob": .bytes, "image": .bytes, "sig": .bytes],
    ]

    /// The user's own private database, default zone: Apple TV snapshots.
    public static let privateRecords: [String: [String: Kind]] = ["TVSnapshot": ["blob": .bytes]]

    /// The public database: live links. Readable by anyone, writable by the creator.
    public static let publicRecords: [String: [String: Kind]] = ["LiveLocation": ["blob": .bytes]]

    /// One record per type with every field set, named `schema-<type>`.
    public static func samples(_ types: [String: [String: Kind]]) -> [StoredRecord] {
        types.sorted { $0.key < $1.key }.map { type, fields in
            StoredRecord(type: type, name: "schema-" + type.lowercased(), fields: fields.mapValues { kind in
                switch kind {
                case .bytes: .bytes(Data([1]))
                case .int: .int(1)
                case .string: .string("schema")
                }
            })
        }
    }

    /// "Type.field:kind" for comparisons.
    static func entries(_ types: [String: [String: Kind]]) -> Set<String> {
        Set(types.flatMap { type, fields in fields.map { "\(type).\($0.key):\($0.value.rawValue)" } })
    }
}
