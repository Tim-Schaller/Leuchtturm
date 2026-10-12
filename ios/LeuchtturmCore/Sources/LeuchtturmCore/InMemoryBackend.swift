import Foundation
import Synchronization

/// In-memory stand-in for CloudKit zone sharing, used by tests and previews.
/// It deliberately allows what CloudKit allows (any participant may
/// overwrite any record) so tests can prove the client detects tampering.
public final class InMemoryCloud: Sendable {
    struct Zone {
        var owner: String
        var records: [String: StoredRecord] = [:]
        var participants: [String] = []
        var shareToken: String
    }

    private let zones = Mutex<[String: Zone]>([:])
    private let written = Mutex<Set<String>>([])

    public init() {}

    /// Every "Type.field:kind" saved so far, to check against `CloudSchema`.
    public func writtenFields() -> Set<String> {
        written.withLock { $0 }
    }

    func noteWritten(_ records: [StoredRecord]) {
        written.withLock { set in
            for record in records {
                for (field, value) in record.fields {
                    let kind = switch value {
                    case .bytes: "bytes"
                    case .int: "int"
                    case .string: "string"
                    }
                    set.insert("\(record.type).\(field):\(kind)")
                }
            }
        }
    }

    public func backend(for userID: String) -> InMemoryBackend {
        InMemoryBackend(cloud: self, userID: userID)
    }

    /// Raw records of a zone, for tests that inspect what "Apple" stores.
    public func rawRecords(circleID: String) -> [StoredRecord] {
        zones.withLock { Array(($0[circleID]?.records ?? [:]).values) }
    }

    func withZones<T>(_ body: (inout [String: Zone]) throws -> T) rethrows -> T {
        try zones.withLock { try body(&$0) }
    }
}

public struct InMemoryBackend: CircleBackend {
    let cloud: InMemoryCloud
    let userID: String

    public func currentUserID() async throws -> String { userID }

    public func createCircle(id: String, records: [StoredRecord]) async throws -> CircleRef {
        cloud.noteWritten(records)
        return try cloud.withZones { zones in
            guard zones[id] == nil else { throw BackendError.other("zone exists") }
            var zone = InMemoryCloud.Zone(owner: userID, shareToken: Base64URL.encode(randomBytes(16)))
            for var record in records {
                record.creatorUserID = userID
                record.lastModifiedByUserID = userID
                zone.records[record.name] = record
            }
            zones[id] = zone
            return CircleRef(circleID: id, ownerUserID: userID, isOwned: true)
        }
    }

    public func listCircles() async throws -> [CircleRef] {
        cloud.withZones { zones in
            zones.compactMap { id, zone in
                if zone.owner == userID { return CircleRef(circleID: id, ownerUserID: userID, isOwned: true) }
                if zone.participants.contains(userID) { return CircleRef(circleID: id, ownerUserID: zone.owner, isOwned: false) }
                return nil
            }.sorted { $0.circleID < $1.circleID }
        }
    }

    public func snapshot(of circle: CircleRef) async throws -> CircleSnapshot {
        try cloud.withZones { zones in
            let zone = try accessible(zones, circle.circleID)
            let participants = [Participant(userID: zone.owner, isOwner: true, accepted: true)]
                + zone.participants.map { Participant(userID: $0, isOwner: false, accepted: true) }
            return CircleSnapshot(ref: circle, records: Array(zone.records.values), participants: participants)
        }
    }

    public func modify(_ circle: CircleRef, save: [StoredRecord], delete: [String], removeParticipants: [String]) async throws {
        cloud.noteWritten(save)
        try cloud.withZones { zones in
            var zone = try accessible(zones, circle.circleID)
            if !removeParticipants.isEmpty {
                guard zone.owner == userID else { throw BackendError.permissionDenied }
                zone.participants.removeAll { removeParticipants.contains($0) }
            }
            for name in delete {
                zone.records.removeValue(forKey: name)
            }
            for var record in save {
                record.creatorUserID = zone.records[record.name]?.creatorUserID ?? userID
                record.lastModifiedByUserID = userID
                zone.records[record.name] = record
            }
            zones[circle.circleID] = zone
        }
    }

    public func inviteURL(for circle: CircleRef) async throws -> URL {
        try cloud.withZones { zones in
            let zone = try accessible(zones, circle.circleID)
            return URL(string: "https://www.icloud.com/share/\(zone.shareToken)#Leuchtturm")!
        }
    }

    public func accept(inviteURL: URL) async throws -> CircleRef {
        try cloud.withZones { zones in
            guard let token = inviteURL.pathComponents.last,
                  let (id, zone) = zones.first(where: { $0.value.shareToken == token })
            else { throw BackendError.notFound }
            if zone.owner == userID { return CircleRef(circleID: id, ownerUserID: userID, isOwned: true) }
            if !zone.participants.contains(userID) { zones[id]?.participants.append(userID) }
            return CircleRef(circleID: id, ownerUserID: zone.owner, isOwned: false)
        }
    }

    public func leave(_ circle: CircleRef) async throws {
        try cloud.withZones { zones in
            let zone = try accessible(zones, circle.circleID)
            guard zone.owner != userID else { throw BackendError.permissionDenied }
            zones[circle.circleID]?.participants.removeAll { $0 == userID }
        }
    }

    public func deleteCircle(_ circle: CircleRef) async throws {
        try cloud.withZones { zones in
            let zone = try accessible(zones, circle.circleID)
            guard zone.owner == userID else { throw BackendError.permissionDenied }
            zones.removeValue(forKey: circle.circleID)
        }
    }

    private func accessible(_ zones: [String: InMemoryCloud.Zone], _ id: String) throws -> InMemoryCloud.Zone {
        guard let zone = zones[id], zone.owner == userID || zone.participants.contains(userID) else {
            throw BackendError.notFound
        }
        return zone
    }
}
