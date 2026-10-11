import CoreMotion

/// Whether the motion coprocessor thinks we are in a car. Only runs while
/// trips are shared; asks for "Motion & Fitness" access on first use.
@MainActor
final class MotionMonitor {
    private let manager = CMMotionActivityManager()
    private var running = false
    /// nil while unknown (no access, no estimate yet, or not running).
    private(set) var automotive: Bool?

    func start() {
        guard !running, CMMotionActivityManager.isActivityAvailable() else { return }
        running = true
        manager.startActivityUpdates(to: .main) { [weak self] activity in
            guard let activity, activity.confidence != .low else { return }
            let inCar = activity.automotive
            MainActor.assumeIsolated { self?.automotive = inCar }
        }
    }

    func stop() {
        guard running else { return }
        manager.stopActivityUpdates()
        running = false
        automotive = nil
    }
}
