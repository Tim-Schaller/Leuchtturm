import Foundation
import WatchConnectivity

/// Sends the snapshot to Apple Watch and carries out SOS and check-in
/// requests from it. The watch has no keys; the iPhone does the work.
@MainActor
final class WatchLink: NSObject, WCSessionDelegate {
    static let shared = WatchLink()

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func send(_ snapshot: WidgetSnapshot) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated, WCSession.default.isPaired,
              WCSession.default.isWatchAppInstalled, var data = try? JSONEncoder().encode(snapshot)
        else { return }
        // The context must stay small; without photos the watch shows initials.
        if data.count > 50_000 {
            var small = snapshot
            for index in small.people.indices { small.people[index].photo = nil }
            guard let smaller = try? JSONEncoder().encode(small) else { return }
            data = smaller
        }
        try? WCSession.default.updateApplicationContext(["snapshot": data])
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {}
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let action = message["action"] as? String ?? ""
        let reply = UncheckedReply(handler: replyHandler)
        Task { @MainActor in
            guard let model = AppModel.current else { reply.handler(["ok": false]); return }
            switch action {
            case "sos": reply.handler(["ok": await model.sendSOS()])
            case "checkIn":
                if let ref = (model.leuchttuerme.first ?? model.circles.first)?.ref { reply.handler(["ok": await model.send(.checkIn, in: ref)]) } else { reply.handler(["ok": false]) }
            default: reply.handler(["ok": false])
            }
        }
    }
}

/// The reply handler crosses to the main actor once.
private struct UncheckedReply: @unchecked Sendable {
    let handler: ([String: Any]) -> Void
}
