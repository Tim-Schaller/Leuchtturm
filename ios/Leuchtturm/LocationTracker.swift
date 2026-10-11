import CoreLocation
import LeuchtturmCore
import Observation

/// This device's position while the app is open ("When In Use").
/// Background tracking follows in a later step.
@MainActor
@Observable
final class LocationTracker {
    private(set) var location: CLLocation?
    /// Location access was declined, or Location Services are off.
    private(set) var isDenied = false

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var session: CLServiceSession?

    func start(onUpdate: @escaping @MainActor (CLLocation) -> Void) {
        guard task == nil else { return }
        session = CLServiceSession(authorization: .whenInUse)
        task = Task { [weak self] in
            do {
                for try await update in CLLocationUpdate.liveUpdates() {
                    guard let self else { return }
                    isDenied = update.authorizationDenied || update.authorizationDeniedGlobally
                    if let location = update.location {
                        self.location = location
                        onUpdate(location)
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
    }
}

extension SharedLocation {
    init?(_ location: CLLocation) {
        self.init(
            latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
            accuracy: location.horizontalAccuracy, timestamp: location.timestamp
        )
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var clLocation: CLLocation {
        CLLocation(latitude: latitude, longitude: longitude)
    }
}
