import CoreLocation
import LeuchtturmCore
import Observation

/// This device's position. In background mode it keeps running when the
/// app is closed: iOS pauses updates while the iPhone stands still and,
/// with "Always" access, relaunches the app when it moves again.
@MainActor
@Observable
final class LocationTracker {
    private(set) var location: CLLocation?
    /// Location access was declined, or Location Services are off.
    private(set) var isDenied = false
    /// "Always" is allowed, so circles see you even after the app was closed.
    private(set) var isAlwaysAllowed = false

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var session: CLServiceSession?
    @ObservationIgnored private var backgroundSession: CLBackgroundActivitySession?
    @ObservationIgnored private var inBackgroundMode = false
    @ObservationIgnored private var onUpdate: (@MainActor (CLLocation) -> Void)?
    @ObservationIgnored private let manager = CLLocationManager()

    /// Starts updates, or switches between foreground and background mode.
    func start(background: Bool, onUpdate: @escaping @MainActor (CLLocation) -> Void) {
        self.onUpdate = onUpdate
        if session == nil || background != inBackgroundMode {
            session?.invalidate()
            session = CLServiceSession(authorization: background ? .always : .whenInUse)
            backgroundSession?.invalidate()
            backgroundSession = background ? CLBackgroundActivitySession() : nil
            inBackgroundMode = background
        }
        refreshAuthorization()
        guard task == nil else { return }
        task = Task { [weak self] in
            do {
                for try await update in CLLocationUpdate.liveUpdates() {
                    guard let self else { return }
                    isDenied = update.authorizationDenied || update.authorizationDeniedGlobally
                    if let location = update.location {
                        self.location = location
                        self.onUpdate?(location)
                    }
                }
            } catch {}
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        session?.invalidate()
        session = nil
        backgroundSession?.invalidate()
        backgroundSession = nil
        inBackgroundMode = false
    }

    /// Call when the app becomes active: the user may have changed access in Settings.
    func refreshAuthorization() {
        isAlwaysAllowed = manager.authorizationStatus == .authorizedAlways
    }
}

/// When to upload a new position: after moving, but not more often than
/// `minInterval`, and at least every `heartbeat` while updates arrive.
/// iOS pauses updates while standing still, so there is no heartbeat then.
struct SharePolicy {
    var minDistance: CLLocationDistance
    var minInterval: TimeInterval
    var heartbeat: TimeInterval

    /// App open: someone may be watching.
    static let foreground = SharePolicy(minDistance: 25, minInterval: 15, heartbeat: 120)
    /// App closed: fewer uploads, less battery.
    static let background = SharePolicy(minDistance: 100, minInterval: 60, heartbeat: 600)

    func shouldShare(_ location: CLLocation, after last: CLLocation?) -> Bool {
        guard let last else { return true }
        let elapsed = location.timestamp.timeIntervalSince(last.timestamp)
        return elapsed >= heartbeat || (elapsed >= minInterval && location.distance(from: last) >= minDistance)
    }
}

extension SharedLocation {
    init?(_ location: CLLocation, battery: Int? = nil, isCharging: Bool = false) {
        self.init(
            latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
            accuracy: location.horizontalAccuracy, timestamp: location.timestamp,
            battery: battery, isCharging: isCharging
        )
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var clLocation: CLLocation {
        CLLocation(latitude: latitude, longitude: longitude)
    }
}
