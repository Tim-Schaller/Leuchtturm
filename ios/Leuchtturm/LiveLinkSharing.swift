import CloudKit
import Foundation
import LeuchtturmCore
import SwiftUI

/// The one-hour web link for people without the app. The position goes,
/// encrypted, into the public iCloud database as `live-<id>`; the key is
/// only in the link (after the #), which the web page reads in the browser.
extension AppModel {
    static let liveRecordType = "LiveLocation"
    private static let liveAccount = "live.link.v1"

    func restoreLiveLink() {
        liveLink = (try? secrets.load(Self.liveAccount)).flatMap { try? JSONDecoder().decode(LiveLink.self, from: $0) }
        if let liveLink, !liveLink.isActive(at: Date()) {
            Task { await endLiveLink() }
        }
    }

    /// Starts a link and publishes the current position right away.
    func startLiveLink() async -> URL? {
        let link = LiveLink.create(production: AppInfo.usesProductionCloud)
        liveLink = link
        if let data = try? JSONEncoder().encode(link) { try? secrets.save(data, for: Self.liveAccount) }
        lastLivePublish = .distantPast
        await shareLocationNow()
        // Ends itself if the app is still running then.
        Task { [weak self] in
            try? await Task.sleep(until: .now + .seconds(link.expires.timeIntervalSinceNow))
            if self?.liveLink == link { await self?.endLiveLink() }
        }
        return link.url(base: AppInfo.liveLinkPage)
    }

    func endLiveLink() async {
        guard let link = liveLink else { return }
        liveLink = nil
        try? secrets.delete(Self.liveAccount)
        guard !isSimulation else { return }
        _ = try? await CKContainer(identifier: AppInfo.cloudKitContainer).publicCloudDatabase
            .deleteRecord(withID: CKRecord.ID(recordName: link.recordName))
    }

    /// Called with every shared position (already blurred in fog), at most every 20 s.
    func publishLiveLink(_ location: SharedLocation) async {
        guard let link = liveLink else { return }
        guard link.isActive(at: Date()) else {
            await endLiveLink()
            return
        }
        guard Date().timeIntervalSince(lastLivePublish) >= 20, !isSimulation else { return }
        lastLivePublish = Date()
        let live = LiveLocation(
            name: displayName, latitude: location.latitude, longitude: location.longitude, accuracy: location.accuracy,
            timestamp: location.timestamp, battery: location.battery, expires: link.expires
        )
        guard let blob = try? CircleCrypto.sealLive(live, link: link) else { return }
        let record = CKRecord(recordType: Self.liveRecordType, recordID: CKRecord.ID(recordName: link.recordName))
        record["blob"] = blob as NSData
        _ = try? await CKContainer(identifier: AppInfo.cloudKitContainer).publicCloudDatabase
            .modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
    }
}

struct LiveLinkSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var working = false

    var body: some View {
        NavigationStack {
            Form {
                if let link = model.liveLink {
                    let url = link.url(base: AppInfo.liveLinkPage)
                    Section {
                        Label {
                            Text("Läuft bis \(link.expires.formatted(date: .omitted, time: .shortened))")
                        } icon: {
                            Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.tint)
                        }
                        ShareLink(item: url, message: Text("Hier siehst du eine Stunde lang, wo ich bin.")) {
                            Label("Link senden", systemImage: "square.and.arrow.up")
                        }
                        Button("Link beenden", systemImage: "stop.circle", role: .destructive) {
                            Task { await model.endLiveLink() }
                        }
                    } footer: {
                        Text("Wer den Link hat, sieht bis dahin deinen Standort, auch ohne die App. Beenden löscht ihn sofort.")
                    }
                } else {
                    Section {
                        Button {
                            working = true
                            Task {
                                _ = await model.startLiveLink()
                                working = false
                            }
                        } label: {
                            Label("Link für eine Stunde erstellen", systemImage: "link.badge.plus")
                        }
                        .disabled(working || !model.isSharingLocation)
                    } footer: {
                        Text(model.isSharingLocation
                            ? "Für Leute ohne die App: Sie sehen eine Stunde lang auf einer Webseite, wo du bist. Dein iPhone verschlüsselt den Standort, der Schlüssel steht nur im Link. Apple sieht, dass du einen Link teilst, aber nicht wo du bist. Im Nebel zeigt der Link nur die ungefähre Gegend."
                            : "Schalte zuerst „Standort teilen“ ein.")
                    }
                }
            }
            .navigationTitle("Live-Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
