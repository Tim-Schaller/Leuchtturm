import Foundation
import LeuchtturmCore

/// Stays reported by iOS, kept only on this device (30 days) for place
/// suggestions. Protected like the keychain items.
@MainActor
final class VisitStore {
    private(set) var visits: [Visit] = []
    private let fileURL: URL?

    /// Not persistent in the simulation.
    init(persistent: Bool) {
        fileURL = persistent ? URL.applicationSupportDirectory.appending(path: "visits.json") : nil
        if let fileURL, let data = try? Data(contentsOf: fileURL) {
            visits = (try? JSONDecoder().decode([Visit].self, from: data)) ?? []
        }
    }

    func add(_ visit: Visit) {
        let cutoff = Date().addingTimeInterval(-30 * 86400)
        visits = Array((visits.filter { $0.departure > cutoff } + [visit]).suffix(500))
        save()
    }

    func clear() {
        visits = []
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    private func save() {
        guard let fileURL, let data = try? JSONEncoder().encode(visits) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
