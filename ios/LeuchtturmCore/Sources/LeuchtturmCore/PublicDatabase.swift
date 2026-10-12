#if canImport(CloudKit)
import CloudKit
#endif
import Foundation
import Synchronization

/// The public iCloud database: anyone can read, only the creator of a
/// record can change or delete it. Used for friend codes and requests.
public protocol PublicDatabase: Sendable {
    func save(_ record: StoredRecord) async throws
    func fetch(_ name: String) async throws -> StoredRecord?
    /// Records of `type` whose string `field` equals `value` (needs a
    /// queryable index in CloudKit).
    func query(type: String, field: String, equals value: String) async throws -> [StoredRecord]
    func delete(_ name: String) async throws
}

/// In-memory stand-in for tests and the simulation, with creator-only writes.
public final class InMemoryPublicStore: Sendable {
    private let records = Mutex<[String: StoredRecord]>([:])

    public init() {}

    public func database(for userID: String) -> some PublicDatabase { Handle(store: self, userID: userID) }

    struct Handle: PublicDatabase {
        let store: InMemoryPublicStore
        let userID: String

        func save(_ record: StoredRecord) async throws {
            try store.records.withLock { all in
                if let existing = all[record.name], existing.creatorUserID != userID { throw BackendError.permissionDenied }
                var saved = record
                saved.creatorUserID = userID
                saved.lastModifiedByUserID = userID
                all[record.name] = saved
            }
        }

        func fetch(_ name: String) async throws -> StoredRecord? {
            store.records.withLock { $0[name] }
        }

        func query(type: String, field: String, equals value: String) async throws -> [StoredRecord] {
            store.records.withLock { all in
                all.values.filter { $0.type == type && $0.string(field) == value }.sorted { $0.name < $1.name }
            }
        }

        func delete(_ name: String) async throws {
            try store.records.withLock { all in
                guard let existing = all[name] else { return }
                guard existing.creatorUserID == userID else { throw BackendError.permissionDenied }
                all[name] = nil
            }
        }
    }
}

#if canImport(CloudKit)
/// The container's public database in CloudKit (default zone).
public struct CloudKitPublicDatabase: PublicDatabase {
    let container: CKContainer

    public init(containerIdentifier: String) {
        container = CKContainer(identifier: containerIdentifier)
    }

    public func save(_ record: StoredRecord) async throws {
        let ck = CKRecord(recordType: record.type, recordID: CKRecord.ID(recordName: record.name))
        for (key, value) in record.fields {
            switch value {
            case let .bytes(data): ck[key] = data as NSData
            case let .int(number): ck[key] = NSNumber(value: number)
            case let .string(text): ck[key] = text as NSString
            }
        }
        let result = try await container.publicCloudDatabase.modifyRecords(saving: [ck], deleting: [], savePolicy: .allKeys)
        for (_, saved) in result.saveResults { _ = try saved.get() }
    }

    public func fetch(_ name: String) async throws -> StoredRecord? {
        do {
            return Self.stored(try await container.publicCloudDatabase.record(for: CKRecord.ID(recordName: name)))
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    public func query(type: String, field: String, equals value: String) async throws -> [StoredRecord] {
        let query = CKQuery(recordType: type, predicate: NSPredicate(format: "%K == %@", field, value))
        do {
            let (results, _) = try await container.publicCloudDatabase.records(matching: query, resultsLimit: 100)
            return results.compactMap { try? $0.1.get() }.map(Self.stored)
        } catch let error as CKError where error.code == .unknownItem {
            // The record type does not exist yet (nobody has written one).
            return []
        }
    }

    public func delete(_ name: String) async throws {
        do {
            _ = try await container.publicCloudDatabase.deleteRecord(withID: CKRecord.ID(recordName: name))
        } catch let error as CKError where error.code == .unknownItem {}
    }

    static func stored(_ record: CKRecord) -> StoredRecord {
        var fields: [String: FieldValue] = [:]
        for key in record.allKeys() {
            let value = record[key]
            if let data = value as? Data { fields[key] = .bytes(data) }
            else if let text = value as? String { fields[key] = .string(text) }
            else if let number = value as? NSNumber { fields[key] = .int(number.int64Value) }
        }
        return StoredRecord(type: record.recordType, name: record.recordID.recordName, fields: fields,
                            creatorUserID: record.creatorUserRecordID?.recordName)
    }
}
#endif
