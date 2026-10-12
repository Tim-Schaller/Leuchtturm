import Foundation
import WatchConnectivity
import WatchKit

/// The watch keeps no keys. The iPhone sends the same snapshot the widgets
/// show and carries out SOS and check-in for the watch.
@MainActor
@Observable
final class WatchModel: NSObject, WCSessionDelegate {
    private(set) var snapshot: WidgetSnapshot?
    private(set) var busy = false
    /// Feedback after an action, e.g. "Eingecheckt".
    var feedback: String?

    override init() {
        super.init()
        snapshot = ProcessInfo.processInfo.arguments.contains("-demo") ? .preview : WidgetSnapshot.load()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func checkIn() async {
        await perform("checkIn", done: String(localized: "„Alles gut“ ist raus."))
    }

    func sendSOS() async {
        await perform("sos", done: String(localized: "SOS gesendet."))
    }

    private func perform(_ action: String, done: String) async {
        busy = true
        let ok = await send(action)
        busy = false
        feedback = ok ? done : String(localized: "Das hat nicht geklappt. Ist dein iPhone in der Nähe?")
        WKInterfaceDevice.current().play(ok ? .success : .failure)
    }

    private func send(_ action: String) async -> Bool {
        guard WCSession.default.activationState == .activated else { return false }
        return await withCheckedContinuation { continuation in
            WCSession.default.sendMessage(["action": action]) { reply in
                continuation.resume(returning: reply["ok"] as? Bool ?? false)
            } errorHandler: { _ in
                continuation.resume(returning: false)
            }
        }
    }

    private func apply(_ data: Data) {
        guard let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else { return }
        self.snapshot = snapshot
        snapshot.save()
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        guard let data = session.receivedApplicationContext["snapshot"] as? Data else { return }
        Task { @MainActor in self.apply(data) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext["snapshot"] as? Data else { return }
        Task { @MainActor in self.apply(data) }
    }
}
