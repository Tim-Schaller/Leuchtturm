import Foundation

/// A circle as stored in the backend: one CloudKit record zone, owned by the
/// circle's creator and shared with the members.
public struct CircleRef: Sendable, Hashable, Codable {
    /// 16 random bytes, base64url. Also the zone name.
    public let circleID: String
    /// Backend user ID of the zone owner.
    public let ownerUserID: String
    /// True if the current user owns the zone.
    public let isOwned: Bool

    public init(circleID: String, ownerUserID: String, isOwned: Bool) {
        self.circleID = circleID
        self.ownerUserID = ownerUserID
        self.isOwned = isOwned
    }
}

public enum FieldValue: Sendable, Equatable {
    case bytes(Data)
    case int(Int64)
    case string(String)
}

/// A backend record. `creatorUserID` and `lastModifiedByUserID` are set by
/// the backend (CloudKit system fields) and cannot be forged by clients.
public struct StoredRecord: Sendable, Equatable {
    public var type: String
    public var name: String
    public var fields: [String: FieldValue]
    public var creatorUserID: String?
    public var lastModifiedByUserID: String?

    public init(type: String, name: String, fields: [String: FieldValue], creatorUserID: String? = nil, lastModifiedByUserID: String? = nil) {
        self.type = type
        self.name = name
        self.fields = fields
        self.creatorUserID = creatorUserID
        self.lastModifiedByUserID = lastModifiedByUserID
    }

    func bytes(_ key: String) -> Data { if case let .bytes(d) = fields[key] { d } else { Data() } }
    func int(_ key: String) -> Int64? { if case let .int(i) = fields[key] { i } else { nil } }
    func string(_ key: String) -> String { if case let .string(s) = fields[key] { s } else { "" } }
}

/// A user who has access to a circle's zone.
public struct Participant: Sendable, Equatable {
    public let userID: String
    public let isOwner: Bool
    public let accepted: Bool

    public init(userID: String, isOwner: Bool, accepted: Bool) {
        self.userID = userID
        self.isOwner = isOwner
        self.accepted = accepted
    }
}

public struct CircleSnapshot: Sendable {
    public let ref: CircleRef
    public let records: [StoredRecord]
    public let participants: [Participant]

    public init(ref: CircleRef, records: [StoredRecord], participants: [Participant]) {
        self.ref = ref
        self.records = records
        self.participants = participants
    }
}

public enum BackendError: Error, Sendable, Equatable {
    /// No iCloud account, or iCloud is restricted on this device.
    case noAccount
    case notFound
    case permissionDenied
    case network
    case quotaExceeded
    case other(String)
}

/// Storage and sharing. Implemented by CloudKit in the app and by an
/// in-memory simulation in tests. Everything passed in is already encrypted
/// or signed by `LeuchtturmClient`; the backend never sees plaintext.
///
/// Access model (mirrors CloudKit zone sharing): the owner and every
/// participant can read and write every record of the circle. Only the owner
/// can remove participants. Anyone holding the invite URL can become a
/// participant, so membership is decided cryptographically on top.
public protocol CircleBackend: Sendable {
    func currentUserID() async throws -> String
    func createCircle(id: String, records: [StoredRecord]) async throws -> CircleRef
    func listCircles() async throws -> [CircleRef]
    func snapshot(of circle: CircleRef) async throws -> CircleSnapshot
    /// Saves and deletes atomically. Saving overwrites existing records.
    func modify(_ circle: CircleRef, save: [StoredRecord], delete: [String], removeParticipants: [String]) async throws
    func inviteURL(for circle: CircleRef) async throws -> URL
    func accept(inviteURL: URL) async throws -> CircleRef
    /// Leaves a circle the current user does not own.
    func leave(_ circle: CircleRef) async throws
    /// Deletes a circle the current user owns, for everyone.
    func deleteCircle(_ circle: CircleRef) async throws
}
