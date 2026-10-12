import CloudKit
import Foundation
import LeuchtturmCore

/// An Apple TV this device leaves snapshots for.
struct PairedTV: Codable, Identifiable, Sendable {
    var pairing: TVPairing
    var added: Date
    var id: String { pairing.id }
}

/// The family map on Apple TV: an encrypted copy of the snapshot goes to
/// the user's own private iCloud database, one record per paired TV. Only
/// the TV can open it (its key and the secret from its QR code); it needs
/// the same iCloud account to find it and gets no circle keys.
extension AppModel {
    static let tvRecordType = "TVSnapshot"
    private static let tvAccount = "tv.pairings.v1"

    func loadPairedTVs() -> [PairedTV] {
        guard let data = try? secrets.load(Self.tvAccount) else { return [] }
        return (try? JSONDecoder().decode([PairedTV].self, from: data)) ?? []
    }

    private func savePairedTVs() {
        if let data = try? JSONEncoder().encode(pairedTVs) { try? secrets.save(data, for: Self.tvAccount) }
    }

    func pairTV(_ pairing: TVPairing) {
        pendingTV = nil
        pairedTVs.removeAll { $0.id == pairing.id }
        pairedTVs.append(PairedTV(pairing: pairing, added: Date()))
        savePairedTVs()
        if let lastTVSnapshot { publishToTVs(lastTVSnapshot, force: true) } else { Task { await refresh() } }
    }

    func unpairTV(_ id: String) async {
        guard let tv = pairedTVs.first(where: { $0.id == id }) else { return }
        pairedTVs.removeAll { $0.id == id }
        savePairedTVs()
        guard !isSimulation else { return }
        _ = try? await CKContainer(identifier: AppInfo.cloudKitContainer).privateCloudDatabase
            .deleteRecord(withID: CKRecord.ID(recordName: tv.pairing.recordName))
    }

    /// At most every two minutes, so the TV stays fresh without costing battery.
    func publishToTVs(_ snapshot: WidgetSnapshot, force: Bool = false) {
        lastTVSnapshot = snapshot
        guard !pairedTVs.isEmpty, !isSimulation, force || Date().timeIntervalSince(lastTVPublish) > 120,
              let data = try? JSONEncoder().encode(snapshot)
        else { return }
        lastTVPublish = Date()
        let records = pairedTVs.compactMap { tv -> CKRecord? in
            guard let blob = try? CircleCrypto.sealForTV(data, to: tv.pairing) else { return nil }
            let record = CKRecord(recordType: Self.tvRecordType, recordID: CKRecord.ID(recordName: tv.pairing.recordName))
            record["blob"] = blob as NSData
            return record
        }
        Task {
            _ = try? await CKContainer(identifier: AppInfo.cloudKitContainer).privateCloudDatabase
                .modifyRecords(saving: records, deleting: [], savePolicy: .allKeys)
        }
    }
}
