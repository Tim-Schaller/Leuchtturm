#if DEBUG
import CloudKit
import LeuchtturmCore

/// Creates every record type and field once in the CloudKit Development
/// environment (in a temporary zone that is deleted again), so the schema
/// can be deployed to Production in the CloudKit console before TestFlight.
extension AppModel {
    func createCloudSchema() async -> Bool {
        let database = CKContainer(identifier: AppInfo.cloudKitContainer).privateCloudDatabase
        let zone = CKRecordZone(zoneName: "leuchtturm-schema")
        let types = CloudSchema.zoneRecords
            .merging(CloudSchema.privateRecords) { a, _ in a }
            .merging(CloudSchema.publicRecords) { a, _ in a }
        let records = CloudSchema.samples(types).map { sample in
            let record = CKRecord(recordType: sample.type, recordID: CKRecord.ID(recordName: sample.name, zoneID: zone.zoneID))
            for (key, value) in sample.fields {
                switch value {
                case let .bytes(data): record[key] = data as NSData
                case let .int(number): record[key] = NSNumber(value: number)
                case let .string(text): record[key] = text as NSString
                }
            }
            return record
        }
        do {
            _ = try await database.modifyRecordZones(saving: [zone], deleting: [])
            let result = try await database.modifyRecords(saving: records, deleting: [], savePolicy: .allKeys)
            for (_, saved) in result.saveResults { _ = try saved.get() }
            _ = try await database.modifyRecordZones(saving: [], deleting: [zone.zoneID])
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
#endif
