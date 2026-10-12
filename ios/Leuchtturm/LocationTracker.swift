import CoreLocation
import LeuchtturmCore
import Observation
import UIKit

/// This device's position.
///
/// In the foreground: regular updates. In the background only with
/// "Always" access, which lets iOS run updates without the blue status-bar
/// indicator. iOS pauses them while the iPhone stands still; leaving a
/// 100 m fence around that spot, significant location changes and visits
/// wake the app again (also after iOS terminated it), and updates resume.
/// While moving fast (driving) it measures with GPS precision every 10 m.
/// With "When In Use" iOS would show the indicator the whole time, so
/// tracking stops in the background then.
@MainActor
@Observable
final class LocationTracker: NSObject, CLLocationManagerDelegate {
    private(set) var location: CLLocation?
    /// Location access was declined, or Location Services are off.
    private(set) var isDenied = false
    /// "Always" is allowed, so circles see you even after the app was closed.
    private(set) var isAlwaysAllowed = false

    @ObservationIgnored private let manager = CLLocationManager()
    /// Every new position in order (iOS may deliver several at once).
    @ObservationIgnored private var onUpdate: (@MainActor ([CLLocation]) -> Void)?
    /// Last time the device moved like a car; precise updates until a while after.
    @ObservationIgnored private var lastFast: Date?
    @ObservationIgnored private var fastMode = false
    /// Waiting for one fresh position (`freshLocation`).
    @ObservationIgnored private var waiting: [CheckedContinuation<CLLocation?, Never>] = []
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
    func start(background: Bool, onUpdate: @escaping @MainActor ([CLLocation]) -> Void) {
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
        guard let monitor = await placeMonitor() else { return }
        while let places = pendingPlaces {
            pendingPlaces = nil
            // One of iOS's 20 conditions is the fence around a stop.
            let wanted = Dictionary(places.prefix(19).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for id in monitored.subtracting(wanted.keys) { await monitor.remove(id) }
            for (id, place) in wanted where !monitored.contains(id) {
                let condition = CLMonitor.CircularGeographicCondition(center: place.coordinate, radius: Double(place.radius))
                await monitor.add(condition, identifier: id)
            }
            monitored = Set(wanted.keys)
        }
    }

    /// The one monitor (a second with the same name blocks the app).
    private func placeMonitor() async -> CLMonitor? {
        if let monitor { return monitor }
        guard isAlwaysAllowed else { return nil }
        let monitor = await CLMonitor("places")
        guard self.monitor == nil else { return self.monitor }
        self.monitor = monitor
        // Conditions survive relaunches; start from what iOS still watches.
        monitored = Set(await monitor.identifiers).subtracting([Self.fence])
        monitorTask = Task { [weak self] in
            do {
                for try await event in await monitor.events {
                    self?.monitorEvent(event.identifier, inside: event.state == .satisfied)
                }
            } catch {}
        }
        return monitor
    }

    private static let fence = "stop-fence"

    /// Leaving the fence around a stop, or any place event: measure again.
    private func monitorEvent(_ identifier: String, inside: Bool) {
        if identifier == Self.fence && inside { return }
        resumeIfPaused()
    }

    /// iOS paused updates because the iPhone stands still: wake up as soon as
    /// it leaves the spot, not only after a significant change (often 500 m+).
    private func fenceIn() async {
        guard let here = location, let monitor = await placeMonitor() else { return }
        await monitor.add(CLMonitor.CircularGeographicCondition(center: here.coordinate, radius: 100), identifier: Self.fence)
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

    /// Waits for the next position (at most `timeout`), e.g. in a background refresh.
    func freshLocation(timeout: Duration = .seconds(10)) async -> CLLocation? {
        requestFresh()
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.deliverWaiting(nil)
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { waiting.append($0) }
    }

    private func deliverWaiting(_ location: CLLocation?) {
        let continuations = waiting
        waiting = []
        for continuation in continuations { continuation.resume(returning: location ?? self.location) }
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
        if fastMode {
            // Driving: GPS precision and a point every 10 m, for smooth routes.
            manager.activityType = .automotiveNavigation
            manager.desiredAccuracy = kCLLocationAccuracyBest
            manager.distanceFilter = 10
        } else {
            manager.activityType = .other
            manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            manager.distanceFilter = inBackground ? 25 : 10
        }
        resume()
    }

    /// After a pause, leaving the fence, a significant change or a departure wakes us: resume.
    private func resumeIfPaused() {
        guard paused, running else { return }
        resume()
    }

    private func resume() {
        paused = false
        manager.startUpdatingLocation()
        if let monitor { Task { await monitor.remove(Self.fence) } }
    }

    /// Faster than about 22 km/h means precise updates, until two minutes after.
    private func updateFastMode(_ latest: CLLocation) {
        if latest.speed >= 6 { lastFast = latest.timestamp }
        let fast = lastFast.map { latest.timestamp.timeIntervalSince($0) < 120 } ?? false
        guard fast != fastMode else { return }
        fastMode = fast
        configure()
    }

    // MARK: CLLocationManagerDelegate (called on the main thread, where the manager was made)

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            guard let latest = locations.last else { return }
            resumeIfPaused()
            location = latest
            updateFastMode(latest)
            onUpdate?(locations)
            deliverWaiting(latest)
        }
    }

    nonisolated func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            paused = true
            Task { await fenceIn() }
        }
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

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        MainActor.assumeIsolated { deliverWaiting(nil) }
    }
}

/// When to upload a new position: after moving, but not more often than
/// `minInterval`, and at least every `heartbeat` while updates arrive.
/// iOS pauses updates while standing still; then the background refresh and
/// the others' refresh requests bring a fresh position and battery level.
struct SharePolicy {
    var minDistance: CLLocationDistance
    var minInterval: TimeInterval
    var heartbeat: TimeInterval

    /// Driving: the others see the car move, every 5 seconds.
    static let driving = SharePolicy(minDistance: 20, minInterval: 5, heartbeat: 15)
    /// App open: someone may be watching.
    static let foreground = SharePolicy(minDistance: 15, minInterval: 10, heartbeat: 60)
    /// App closed: a little calmer, for the battery.
    static let background = SharePolicy(minDistance: 50, minInterval: 30, heartbeat: 300)

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
