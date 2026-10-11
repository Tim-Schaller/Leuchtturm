import CoreLocation
import Foundation
import LeuchtturmCore
import Observation
import UIKit

/// App-wide state. Owns the client once setup is done.
@MainActor
@Observable
final class AppModel {
    enum Phase {
        case onboarding
        case ready
    }

    private enum Keys {
        static let displayName = "displayName"
        static let locationPaused = "locationPaused"
        static let lastSharedAt = "lastSharedAt"
    }

    private(set) var phase: Phase = .onboarding
    private(set) var client: LeuchtturmClient? = nil
    private(set) var displayName = ""

    var circles: [CircleSummary] = []
    /// True after the first successful load, so the empty state does not flash.
    private(set) var hasLoadedCircles = false
    var isLoading = false
    var errorMessage: String?
    /// An invite opened via link or QR code, waiting for confirmation.
    var pendingInvite: InviteLink?
    /// Bumped when other members changed something; views reload on change.
    private(set) var externalChanges = 0

    let tracker = LocationTracker()
    /// The user's choice in settings. On by default.
    private(set) var isSharingLocation = true
    /// Last successful upload, so the user can check that background sharing works.
    private(set) var lastSharedAt: Date?
    @ObservationIgnored private var lastShared: CLLocation?

    #if DEBUG
    /// Runs instead of iCloud while set. Debug builds only.
    private(set) var simulation: SimulatedWorld?
    #endif

    var isSimulation: Bool {
        #if DEBUG
        simulation != nil
        #else
        false
        #endif
    }

    private let keychain = KeychainSecretStore()
    /// Off in unit tests, which must not start CoreLocation.
    private let tracksLocation: Bool

    init(tracksLocation: Bool = true) {
        self.tracksLocation = tracksLocation
        UIDevice.current.isBatteryMonitoringEnabled = true
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains(SimulatedWorld.demoArgument) {
            startSimulation()
            Task {
                if await setUp(name: "Tim") { await createDemoCircle() }
            }
            return
        }
        if arguments.contains(SimulatedWorld.launchArgument) {
            startSimulation()
            return
        }
        #endif
        restore()
    }

    /// Picks up the setup saved on this device (or in the simulation).
    private func restore() {
        displayName = savedName ?? ""
        client = nil
        circles = []
        hasLoadedCircles = false
        pendingInvite = nil
        lastShared = nil
        isSharingLocation = isSimulation || !UserDefaults.standard.bool(forKey: Keys.locationPaused)
        lastSharedAt = isSimulation ? nil : UserDefaults.standard.object(forKey: Keys.lastSharedAt) as? Date
        phase = .onboarding
        if !displayName.isEmpty, let client = try? makeClient(name: displayName) {
            self.client = client
            phase = .ready
        }
        updateTracking()
    }

    private func makeClient(name: String) throws -> LeuchtturmClient {
        try LeuchtturmClient(backend: makeBackend(), secrets: secrets, displayName: name)
    }

    // MARK: Storage

    private func makeBackend() -> any CircleBackend {
        #if DEBUG
        if let simulation { return simulation.backend }
        #endif
        return CloudKitBackend(containerIdentifier: AppInfo.cloudKitContainer)
    }

    private var secrets: any SecretStore {
        #if DEBUG
        if let simulation { return simulation.secrets }
        #endif
        return keychain
    }

    /// The name chosen during setup.
    private var savedName: String? {
        get {
            #if DEBUG
            if let simulation { return simulation.savedName }
            #endif
            return UserDefaults.standard.string(forKey: Keys.displayName)
        }
        set {
            #if DEBUG
            if let simulation {
                simulation.savedName = newValue
                return
            }
            #endif
            UserDefaults.standard.set(newValue, forKey: Keys.displayName)
        }
    }

    // MARK: Setup

    /// Creates the device keys (if needed), checks iCloud and stores the name.
    func setUp(name: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= LeuchtturmClient.maxNameLength else {
            errorMessage = "Bitte gib einen Namen mit höchstens \(LeuchtturmClient.maxNameLength) Zeichen ein."
            return false
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let client = try makeClient(name: trimmed)
            try await client.start()
            savedName = trimmed
            self.client = client
            displayName = trimmed
            phase = .ready
            updateTracking()
            await refresh()
            return true
        } catch {
            errorMessage = Self.describe(error)
            return false
        }
    }

    // MARK: Circles

    func refresh() async {
        guard let client else { return }
        await simulateOthers()
        do {
            circles = try await client.circles()
            hasLoadedCircles = true
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    func createCircle(name: String) async -> CircleRef? {
        let ref = await run { try await $0.createCircle(name: name) }
        if ref != nil {
            await shareLocationNow()
            await refresh()
        }
        return ref
    }

    func join(_ link: InviteLink) async -> CircleRef? {
        let ref = await run { try await $0.join(link) }
        if ref != nil {
            await shareLocationNow()
            await refresh()
        }
        return ref
    }

    /// The circle shown on the map. Quiet on errors, it is polled.
    func mapDetails(for ref: CircleRef) async -> CircleDetails? {
        guard let client else { return nil }
        #if DEBUG
        await simulation?.move(near: tracker.location)
        #endif
        await simulateOthers()
        return try? await client.circle(ref)
    }

    // MARK: Location

    /// Tracks while set up: in the background while sharing (also after iOS
    /// relaunched the app for a location event), else only for the map.
    private func updateTracking() {
        guard tracksLocation else { return }
        guard phase == .ready else {
            tracker.stop()
            return
        }
        tracker.start(background: isSharingLocation && !isSimulation) { [weak self] location in
            Task { await self?.share(location) }
        }
    }

    private func share(_ location: CLLocation) async {
        guard isSharingLocation, let client, (0 ... 1000).contains(location.horizontalAccuracy) else { return }
        let policy: SharePolicy = UIApplication.shared.applicationState == .active ? .foreground : .background
        let device = UIDevice.current
        let battery = device.batteryLevel >= 0 ? Int((device.batteryLevel * 100).rounded()) : nil
        let charging = device.batteryState == .charging || device.batteryState == .full
        guard policy.shouldShare(location, after: lastShared),
              let shared = SharedLocation(location, battery: battery, isCharging: charging)
        else { return }
        lastShared = location
        // Finish the upload even if iOS suspends the app right after this update.
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "share-location")
        if (try? await client.shareLocation(shared)) != nil {
            lastSharedAt = Date()
            if !isSimulation { UserDefaults.standard.set(lastSharedAt, forKey: Keys.lastSharedAt) }
        }
        UIApplication.shared.endBackgroundTask(backgroundTask)
    }

    private func shareLocationNow() async {
        lastShared = nil
        if let location = tracker.location { await share(location) }
    }

    /// Turning sharing off removes the position from every circle at once.
    func setSharingLocation(_ on: Bool) async {
        isSharingLocation = on
        if !isSimulation { UserDefaults.standard.set(!on, forKey: Keys.locationPaused) }
        updateTracking()
        if on {
            await shareLocationNow()
        } else {
            await run { try await $0.stopSharingLocation() }
        }
    }

    /// Runs a client operation and reports errors. Returns nil on failure.
    @discardableResult
    func run<T: Sendable>(_ operation: @Sendable (LeuchtturmClient) async throws -> T) async -> T? {
        guard let client else { return nil }
        await simulateOthers()
        do {
            return try await operation(client)
        } catch {
            errorMessage = Self.describe(error)
            return nil
        }
    }

    func handle(url: URL) {
        guard let link = InviteLink(url: url) else { return }
        pendingInvite = link
    }

    // MARK: Settings

    func changeDisplayName(_ name: String) async -> Bool {
        let ok = await run { try await $0.setDisplayName(name) } != nil
        if ok {
            displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            savedName = displayName
        }
        return ok
    }

    /// Deletes own circles, leaves all others, then wipes this device.
    func deleteAllData() async {
        guard await run({ try await $0.deleteAllData() }) != nil else { return }
        resetLocal()
    }

    /// Wipes keys and settings on this device only. iCloud data stays.
    func resetLocal() {
        for account in (try? secrets.accounts()) ?? [] {
            try? secrets.delete(account)
        }
        savedName = nil
        client = nil
        circles = []
        hasLoadedCircles = false
        displayName = ""
        phase = .onboarding
        updateTracking()
    }

    // MARK: Simulation

    /// In the simulation, the made-up people open their app first, so they
    /// confirm new members and pick up new keys like a real second device.
    private func simulateOthers() async {
        #if DEBUG
        await simulation?.tick()
        #endif
    }

    #if DEBUG
    /// "Familie" with Anna, Ben and Clara in one step.
    func createDemoCircle() async {
        guard let ref = await createCircle(name: "Familie"),
              let link = await run({ try await $0.createInvite(for: ref) })
        else { return }
        await simulate { world in
            for person in world.people {
                try await world.join(person, using: link)
            }
        }
    }

    /// Switches to the simulation. The real setup stays untouched.
    func startSimulation() {
        do {
            simulation = try SimulatedWorld()
        } catch {
            errorMessage = Self.describe(error)
        }
        restore()
    }

    /// Back to iCloud and the real setup of this device.
    func endSimulation() {
        simulation = nil
        restore()
    }

    /// Runs an action of the made-up people and lets the views reload.
    @discardableResult
    func simulate<T>(_ action: @MainActor (SimulatedWorld) async throws -> T) async -> T? {
        guard let simulation else { return nil }
        do {
            let result = try await action(simulation)
            externalChanges += 1
            return result
        } catch {
            errorMessage = Self.describe(error)
            return nil
        }
    }
    #endif

    // MARK: Errors

    static func describe(_ error: any Error) -> String {
        switch error {
        case let error as BackendError:
            switch error {
            case .noAccount:
                return "Bitte melde dich in den Einstellungen bei iCloud an. Leuchtturm speichert seine verschlüsselten Daten in deiner iCloud."
            case .notFound: return "Nicht gefunden. Vielleicht wurde der Kreis gelöscht oder du wurdest entfernt."
            case .permissionDenied: return "Dafür fehlen dir die Rechte."
            case .network: return "Keine Verbindung zu iCloud. Bitte versuch es gleich noch einmal."
            case .quotaExceeded: return "Dein iCloud-Speicher ist voll."
            case let .other(message): return "iCloud-Fehler: \(message)"
            }
        case let error as ClientError:
            switch error {
            case .missingCircleKey: return "Auf diesem Gerät fehlt noch der Schlüssel für den Kreis. Der Besitzer muss die App einmal öffnen."
            case .notOwner: return "Das darf nur der Besitzer des Kreises."
            case .unknownMember: return "Dieses Mitglied gibt es nicht."
            case .invalidName: return "Namen müssen 1 bis \(LeuchtturmClient.maxNameLength) Zeichen lang sein."
            case .invalidDuration: return "Ungültige Gültigkeitsdauer."
            case .inviteInvalid: return "Die Einladung ist ungültig oder wurde zurückgezogen."
            case .inviteExpired: return "Die Einladung ist abgelaufen. Bitte um eine neue."
            case .untrustedCircle: return "Dieses Gerät kann den Kreis nicht prüfen, z. B. nach einer Neuinstallation. Lass dich neu einladen."
            case .tampered: return "Die Kreisdaten wurden verändert und sind nicht vom Besitzer signiert."
            case .ownerMustDelete: return "Als Besitzer kannst du den Kreis nicht verlassen, nur löschen."
            }
        case is ProtocolError:
            return "Die Daten konnten nicht entschlüsselt oder geprüft werden."
        default:
            return "Unbekannter Fehler."
        }
    }
}
