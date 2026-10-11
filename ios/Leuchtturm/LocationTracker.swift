import CoreLocation
import LeuchtturmCore
import Observation
import UIKit

/// This device's position.
///
/// In the foreground: regular updates. In the background only with
/// "Always" access, which lets iOS run updates without the blue status-bar
/// indicator. iOS pauses them while the iPhone stands still; significant
/// location changes and visits wake the app again (also after iOS
/// terminated it), and updates resume. With "When In Use" iOS would show
/// the indicator the whole time, so tracking stops in the background then.
@MainActor
@Observable
final class LocationTracker: NSObject, CLLocationManagerDelegate {
    private(set) var location: CLLocation?
    /// Location access was declined, or Location Services are off.
    private(set) var isDenied = false
    /// "Always" is allowed, so circles see you even after the app was closed.
    private(set) var isAlwaysAllowed = false

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var onUpdate: (@MainActor (CLLocation) -> Void)?
    @ObservationIgnored private var running = false
    @ObservationIgnored private var wantsBackground = false
    @ObservationIgnored private var paused = false
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .other
        manager.pausesLocationUpdatesAutomatically = true
        manager.showsBackgroundLocationIndicator = false
        refreshAuthorization()
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.willEnterForegroundNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.configure() }
            })
        }
    }

    /// Starts updates; `background` asks to keep going while the app is closed.
    func start(background: Bool, onUpdate: @escaping @MainActor (CLLocation) -> Void) {
        self.onUpdate = onUpdate
        wantsBackground = background
        running = true
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        configure()
    }

    func stop() {
        running = false
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        manager.stopMonitoringVisits()
        manager.allowsBackgroundLocationUpdates = false
    }

    /// Asks iOS for "Always". Returns false when iOS will not ask, then the
    /// Settings app is the way.
    func requestAlways() -> Bool {
        guard manager.authorizationStatus == .authorizedWhenInUse else { return false }
        manager.requestAlwaysAuthorization()
        return true
    }

    /// Call when the app becomes active: the user may have changed access in Settings.
    func refreshAuthorization() {
        let status = manager.authorizationStatus
        isAlwaysAllowed = status == .authorizedAlways
        isDenied = status == .denied || status == .restricted
    }

    private func configure() {
        refreshAuthorization()
        guard running, !isDenied, manager.authorizationStatus != .notDetermined else { return }
        let inBackground = UIApplication.shared.applicationState == .background
        let background = wantsBackground && isAlwaysAllowed
        manager.allowsBackgroundLocationUpdates = background
        if background {
            manager.startMonitoringSignificantLocationChanges()
            manager.startMonitoringVisits()
        } else {
            manager.stopMonitoringSignificantLocationChanges()
            manager.stopMonitoringVisits()
        }
        if inBackground && !background {
            // Would need the permanent indicator.
            manager.stopUpdatingLocation()
            return
        }
        manager.desiredAccuracy = inBackground ? kCLLocationAccuracyHundredMeters : kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = inBackground ? 50 : 10
        paused = false
        manager.startUpdatingLocation()
    }

    /// After a pause, the next significant change or departure wakes us: resume.
    private func resumeIfPaused() {
        guard paused, running else { return }
        paused = false
        manager.startUpdatingLocation()
    }

    // MARK: CLLocationManagerDelegate (called on the main thread, where the manager was made)

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            guard let latest = locations.last else { return }
            resumeIfPaused()
            location = latest
            onUpdate?(latest)
        }
    }

    nonisolated func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        MainActor.assumeIsolated { paused = true }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        let departed = visit.departureDate != .distantFuture
        MainActor.assumeIsolated {
            if departed { resumeIfPaused() }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated { configure() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {}
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
    init?(_ location: CLLocation, battery: Int? = nil, isCharging: Bool = false, speed: Double? = nil) {
        self.init(
            latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
            accuracy: location.horizontalAccuracy, timestamp: location.timestamp,
            battery: battery, isCharging: isCharging, speed: speed
        )
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var clLocation: CLLocation {
        CLLocation(latitude: latitude, longitude: longitude)
    }
}
