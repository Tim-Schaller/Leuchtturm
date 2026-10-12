import CloudKit
import Foundation
import LeuchtturmCore

/// The family map on Apple TV. The TV shows a QR code with its own key;
/// an iPhone with the same iCloud account scans it and then leaves an
/// encrypted snapshot in the private iCloud database. The TV holds no
/// circle keys and only reads that one record.
@MainActor
@Observable
final class TVModel {
    enum Phase: Equatable {
        case pairing
        case noAccount
        case showing
    }

    private(set) var phase = Phase.pairing
    private(set) var snapshot: WidgetSnapshot?
    private(set) var pairing: TVPairing?
    private(set) var isDemo = false

    @ObservationIgnored private var identity: TVIdentity?
    @ObservationIgnored private let store = KeychainSecretStore(service: "de.timschaller.leuchtturm.tv")
    /// Created on first use, so the preview runs without iCloud.
    @ObservationIgnored private lazy var container = CKContainer(identifier: "iCloud.de.timschaller.leuchtturm")

    init() {
        identity = try? TVIdentity.loadOrCreate(in: store)
        pairing = identity?.pairing
        if ProcessInfo.processInfo.arguments.contains("-demo") {
            showDemo()
        } else if let cached = WidgetSnapshot.load() {
            snapshot = cached
            phase = .showing
        }
    }

    /// Looks for a new snapshot: often while the code is on screen, every
    /// minute while the map is.
    func run() async {
        #if DEBUG
        // Screenshots of the code screen without iCloud.
        if ProcessInfo.processInfo.arguments.contains("-pairing") { return }
        #endif
        while !Task.isCancelled {
            if !isDemo { await poll() }
            try? await Task.sleep(for: .seconds(phase == .showing ? 60 : 4))
        }
    }

    func showDemo() {
        isDemo = true
        snapshot = .preview
        phase = .showing
    }

    func endDemo() {
        isDemo = false
        snapshot = WidgetSnapshot.load()
        phase = snapshot == nil ? .pairing : .showing
        Task { await poll() }
    }

    /// A new key and code; the old pairing stops working.
    func newCode() {
        let old = identity?.pairing.recordName
        identity = try? TVIdentity.loadOrCreate(in: store, reset: true)
        pairing = identity?.pairing
        snapshot = nil
        isDemo = false
        if let url = WidgetSnapshot.fileURL { try? FileManager.default.removeItem(at: url) }
        phase = .pairing
        if let old {
            Task { _ = try? await container.privateCloudDatabase.deleteRecord(withID: CKRecord.ID(recordName: old)) }
        }
    }

    private func poll() async {
        guard let identity else { return }
        guard (try? await container.accountStatus()) == .available else {
            if snapshot == nil { phase = .noAccount }
            return
        }
        let record: CKRecord
        do {
            record = try await container.privateCloudDatabase.record(for: CKRecord.ID(recordName: identity.pairing.recordName))
        } catch let error as CKError where error.code == .unknownItem {
            // Not paired yet, or the iPhone disconnected this TV.
            snapshot = nil
            if let url = WidgetSnapshot.fileURL { try? FileManager.default.removeItem(at: url) }
            phase = .pairing
            return
        } catch {
            if snapshot == nil { phase = .pairing }
            return
        }
        guard !isDemo, let blob = record["blob"] as? Data,
              let data = try? CircleCrypto.openOnTV(blob, identity: identity),
              let fresh = try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
        else {
            if snapshot == nil { phase = .pairing }
            return
        }
        // An older copy (replayed by someone with database access) never wins.
        if let snapshot, snapshot.written > fresh.written { return }
        snapshot = fresh
        fresh.save()
        phase = .showing
    }
}
