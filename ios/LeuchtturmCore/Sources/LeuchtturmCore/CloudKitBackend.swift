#if canImport(CloudKit)
import CloudKit
import Foundation
import Synchronization

/// CloudKit implementation: each circle is a custom record zone in the
/// owner's private database, shared with the members through a zone-wide
/// `CKShare` with a public link. Members see it in their shared database.
///
/// Apple stores only what `LeuchtturmClient` hands over: ciphertext, public
/// keys and signatures. Apple does see which iCloud accounts share a zone.
public final class CloudKitBackend: CircleBackend, @unchecked Sendable {
    /// Shown by iOS for the share. Deliberately generic: Apple can read it.
    public static let shareTitle = "Leuchtturm"

    private let container: CKContainer
    private let cachedUserID = Mutex<String?>(nil)

    public init(containerIdentifier: String) {
        container = CKContainer(identifier: containerIdentifier)
    }

    // MARK: CircleBackend

    public func currentUserID() async throws -> String {
        if let id = cachedUserID.withLock({ $0 }) { return id }
        return try await mapped {
            let status = try await container.accountStatus()
            guard status == .available else { throw BackendError.noAccount }
            let id = try await container.userRecordID().recordName
            cachedUserID.withLock { $0 = id }
            return id
        }
    }

    public func createCircle(id: String, records: [StoredRecord]) async throws -> CircleRef {
        let me = try await currentUserID()
        return try await mapped {
            let db = container.privateCloudDatabase
            let zone = CKRecordZone(zoneName: id)
            let zoneResult = try await db.modifyRecordZones(saving: [zone], deleting: [])
            for (_, result) in zoneResult.saveResults { _ = try result.get() }

            let share = CKShare(recordZoneID: zone.zoneID)
            share[CKShare.SystemFieldKey.title] = Self.shareTitle as NSString
            share.publicPermission = .readWrite
            let ckRecords = records.map { makeRecord($0, zoneID: zone.zoneID) }
            try await save(db, ckRecords + [share], deleting: [])
            return CircleRef(circleID: id, ownerUserID: me, isOwned: true)
        }
    }

    public func listCircles() async throws -> [CircleRef] {
        let me = try await currentUserID()
        return try await mapped {
            let owned = try await container.privateCloudDatabase.allRecordZones()
                .filter { DeviceID.raw($0.zoneID.zoneName) != nil }
                .map { CircleRef(circleID: $0.zoneID.zoneName, ownerUserID: me, isOwned: true) }
            let shared = try await container.sharedCloudDatabase.allRecordZones()
                .filter { DeviceID.raw($0.zoneID.zoneName) != nil }
                .map { CircleRef(circleID: $0.zoneID.zoneName, ownerUserID: $0.zoneID.ownerName, isOwned: false) }
            return owned + shared
        }
    }

    public func snapshot(of circle: CircleRef) async throws -> CircleSnapshot {
        let me = try await currentUserID()
        return try await mapped {
            let db = database(circle)
            let zoneID = zoneID(circle)
            var records: [StoredRecord] = []
            var token: CKServerChangeToken?
            var moreComing = true
            while moreComing {
                let changes = try await db.recordZoneChanges(inZoneWith: zoneID, since: token)
                for (_, result) in changes.modificationResultsByID {
                    let record = try result.get().record
                    if record is CKShare { continue }
                    records.append(stored(record, me: me))
                }
                token = changes.changeToken
                moreComing = changes.moreComing
            }
            let share = try await db.record(for: shareID(zoneID)) as? CKShare
            let participants = (share?.participants ?? []).compactMap { p -> Participant? in
                if p.role == .owner {
                    return Participant(userID: circle.ownerUserID, isOwner: true, accepted: true)
                }
                guard let raw = p.userIdentity.userRecordID?.recordName else { return nil }
                return Participant(userID: normalize(raw, me: me), isOwner: false, accepted: p.acceptanceStatus == .accepted)
            }
            return CircleSnapshot(ref: circle, records: records, participants: participants)
        }
    }

    public func modify(_ circle: CircleRef, save records: [StoredRecord], delete: [String], removeParticipants: [String]) async throws {
        let me = try await currentUserID()
        try await mapped {
            let db = database(circle)
            let zoneID = zoneID(circle)
            var toSave = records.map { makeRecord($0, zoneID: zoneID) }
            if !removeParticipants.isEmpty {
                guard circle.isOwned, let share = try await db.record(for: shareID(zoneID)) as? CKShare else {
                    throw BackendError.permissionDenied
                }
                for p in share.participants where p.role != .owner {
                    if let raw = p.userIdentity.userRecordID?.recordName, removeParticipants.contains(normalize(raw, me: me)) {
                        share.removeParticipant(p)
                    }
                }
                toSave.append(share)
            }
            let ids = delete.map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
            try await save(db, toSave, deleting: ids)
        }
    }

    public func inviteURL(for circle: CircleRef) async throws -> URL {
        try await mapped {
            let db = database(circle)
            guard let share = try await db.record(for: shareID(zoneID(circle))) as? CKShare else {
                throw BackendError.notFound
            }
            if circle.isOwned, share.publicPermission != .readWrite {
                share.publicPermission = .readWrite
                try await save(db, [share], deleting: [])
            }
            guard let url = share.url else { throw BackendError.notFound }
            return url
        }
    }

    public func accept(inviteURL: URL) async throws -> CircleRef {
        let me = try await currentUserID()
        return try await mapped {
            let metadata = try await container.shareMetadata(for: inviteURL)
            let zoneID = metadata.share.recordID.zoneID
            let ownerRaw = metadata.ownerIdentity.userRecordID?.recordName ?? zoneID.ownerName
            if normalize(ownerRaw, me: me) == me || zoneID.ownerName == CKCurrentUserDefaultName {
                return CircleRef(circleID: zoneID.zoneName, ownerUserID: me, isOwned: true)
            }
            if metadata.participantStatus != .accepted {
                _ = try await container.accept(metadata)
            }
            return CircleRef(circleID: zoneID.zoneName, ownerUserID: zoneID.ownerName, isOwned: false)
        }
    }

    public func leave(_ circle: CircleRef) async throws {
        guard !circle.isOwned else { throw BackendError.permissionDenied }
        try await mapped {
            // A participant leaves by deleting the share from their shared database.
            _ = try await container.sharedCloudDatabase.deleteRecord(withID: shareID(zoneID(circle)))
        }
    }

    public func deleteCircle(_ circle: CircleRef) async throws {
        guard circle.isOwned else { throw BackendError.permissionDenied }
        try await mapped {
            let result = try await container.privateCloudDatabase.modifyRecordZones(saving: [], deleting: [zoneID(circle)])
            for (_, r) in result.deleteResults { try r.get() }
        }
    }

    /// One silent database subscription each for owned and joined circles.
    /// Saving an existing subscription ID again replaces it.
    public func subscribeToChanges() async throws {
        _ = try await currentUserID()
        try await mapped {
            for (db, id) in [(container.privateCloudDatabase, "leuchtturm-private"), (container.sharedCloudDatabase, "leuchtturm-shared")] {
                let subscription = CKDatabaseSubscription(subscriptionID: id)
                let info = CKSubscription.NotificationInfo()
                info.shouldSendContentAvailable = true
                subscription.notificationInfo = info
                let result = try await db.modifySubscriptions(saving: [subscription], deleting: [])
                for (_, r) in result.saveResults { _ = try r.get() }
            }
        }
    }

    // MARK: Helpers

    private func database(_ circle: CircleRef) -> CKDatabase {
        circle.isOwned ? container.privateCloudDatabase : container.sharedCloudDatabase
    }

    private func zoneID(_ circle: CircleRef) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: circle.circleID, ownerName: circle.isOwned ? CKCurrentUserDefaultName : circle.ownerUserID)
    }

    private func shareID(_ zoneID: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
    }

    /// CloudKit reports the current user as a placeholder name.
    private func normalize(_ raw: String, me: String) -> String {
        raw == CKCurrentUserDefaultName ? me : raw
    }

    private func save(_ db: CKDatabase, _ records: [CKRecord], deleting: [CKRecord.ID]) async throws {
        let result = try await db.modifyRecords(saving: records, deleting: deleting, savePolicy: .allKeys, atomically: true)
        for (_, r) in result.saveResults { _ = try r.get() }
        for (_, r) in result.deleteResults { try r.get() }
    }

    private func makeRecord(_ r: StoredRecord, zoneID: CKRecordZone.ID) -> CKRecord {
        let record = CKRecord(recordType: r.type, recordID: CKRecord.ID(recordName: r.name, zoneID: zoneID))
        for (key, value) in r.fields {
            switch value {
            case let .bytes(data): record[key] = data as NSData
            case let .int(number): record[key] = NSNumber(value: number)
            case let .string(text): record[key] = text as NSString
            }
        }
        return record
    }

    private func stored(_ record: CKRecord, me: String) -> StoredRecord {
        var fields: [String: FieldValue] = [:]
        for key in record.allKeys() {
            let value = record[key]
            if let data = value as? Data {
                fields[key] = .bytes(data)
            } else if let text = value as? String {
                fields[key] = .string(text)
            } else if let number = value as? NSNumber {
                fields[key] = .int(number.int64Value)
            }
        }
        return StoredRecord(
            type: record.recordType,
            name: record.recordID.recordName,
            fields: fields,
            creatorUserID: record.creatorUserRecordID.map { normalize($0.recordName, me: me) },
            lastModifiedByUserID: record.lastModifiedUserRecordID.map { normalize($0.recordName, me: me) }
        )
    }

    /// Translates CloudKit errors into `BackendError`.
    private func mapped<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch let error as BackendError {
            throw error
        } catch let error as CKError {
            switch error.code {
            case .notAuthenticated, .accountTemporarilyUnavailable: throw BackendError.noAccount
            case .unknownItem, .zoneNotFound, .userDeletedZone: throw BackendError.notFound
            case .permissionFailure, .participantMayNeedVerification: throw BackendError.permissionDenied
            case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy:
                throw BackendError.network
            case .quotaExceeded: throw BackendError.quotaExceeded
            case .partialFailure:
                if let first = error.partialErrorsByItemID?.values.first as? CKError {
                    throw BackendError.other("\(first.code.rawValue): \(first.localizedDescription)")
                }
                throw BackendError.other(error.localizedDescription)
            default: throw BackendError.other("\(error.code.rawValue): \(error.localizedDescription)")
            }
        }
    }
}
#endif
