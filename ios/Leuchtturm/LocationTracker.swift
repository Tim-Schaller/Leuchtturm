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
    /// Finished stays (with "Always" access), for place suggestions.
    @ObservationIgnored var onVisit: (@MainActor (Visit) -> Void)?
    @ObservationIgnored private var running = false
    @ObservationIgnored private var wantsBackground = false
    @ObservationIgnored private var paused = false
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    /// Wakes the app at the edges of the circles' places (iOS allows 20).
    @ObservationIgnored private var monitor: CLMonitor?
    @ObservationIgnored private var monitored: Set<String> = []
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    /// Newest places to watch while an update is running; one update at a time,
    /// because a second CLMonitor with the same name blocks the app.
    @ObservationIgnored private var pendingPlaces: [CirclePlace]?
    @ObservationIgnored private var updatingMonitor = false

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

    /// Region monitoring for places, only with "Always" access. An event
    /// just resumes location updates; arrivals are judged by `PlaceTracker`.
    func monitor(places: [CirclePlace]) async {
        guard isAlwaysAllowed else { return }
        pendingPlaces = places
        // A running update picks up the newest list when it is done.
        guard !updatingMonitor else { return }
        updatingMonitor = true
        defer { updatingMonitor = false }
        if monitor == nil {
            let monitor = await CLMonitor("places")
            self.monitor = monitor
            // Conditions survive relaunches; start from what iOS still watches.
            monitored = Set(await monitor.identifiers)
            monitorTask = Task { [weak self] in
                do {
                    for try await _ in await monitor.events {
                        self?.resumeIfPaused()
                    }
                } catch {}
            }
        }
        guard let monitor else { return }
        while let places = pendingPlaces {
            pendingPlaces = nil
            let wanted = Dictionary(places.prefix(20).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for id in monitored.subtracting(wanted.keys) { await monitor.remove(id) }
            for (id, place) in wanted where !monitored.contains(id) {
                let condition = CLMonitor.CircularGeographicCondition(center: place.coordinate, radius: Double(place.radius))
                await monitor.add(condition, identifier: id)
            }
            monitored = Set(wanted.keys)
        }
    }

    func stop() {
        running = false
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        manager.stopMonitoringVisits()
        manager.allowsBackgroundLocationUpdates = false
    }

    /// One fresh position right now, e.g. when someone asked "Wo bist du?".
    func requestFresh() {
        resumeIfPaused()
        manager.requestLocation()
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
        let stay = departed && visit.arrivalDate != .distantPast
            ? Visit(latitude: visit.coordinate.latitude, longitude: visit.coordinate.longitude, arrival: visit.arrivalDate, departure: visit.departureDate)
            : nil
        MainActor.assumeIsolated {
            if departed { resumeIfPaused() }
            if let stay { onVisit?(stay) }
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
