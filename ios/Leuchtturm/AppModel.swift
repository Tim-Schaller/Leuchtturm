import CoreLocation
import Foundation
import LeuchtturmCore
import Observation
import UIKit
import UserNotifications

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
        static let seenNotes = "seenNotes"
        static let newsSince = "newsSince"
        static let morningGreeting = "morningGreeting"
        static let lastMorningGreeting = "lastMorningGreeting"
        static let fog = "fog"
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
    /// While set and not expired, only an approximate area is shared.
    private(set) var fog: Fog?
    var activeFog: Fog? { fog.flatMap { $0.until > Date() ? $0 : nil } }

    /// Says "good morning" to the circles on the first movement of the day.
    private(set) var sendsMorningGreeting = false
    /// Notes already notified (or sent by me), so each one notifies once.
    @ObservationIgnored private var seenNotes: [String] = []
    /// Notes older than this never notify, e.g. from before the setup.
    @ObservationIgnored private var newsSince = Date()
    @ObservationIgnored private var lastMorningGreeting: Date?
    @ObservationIgnored private let notificationPresenter = NotificationPresenter()

    /// Off in unit tests, which must not start CoreLocation or ask for notifications.
    private let usesDeviceServices: Bool

    init(usesDeviceServices: Bool = true) {
        self.usesDeviceServices = usesDeviceServices
        UIDevice.current.isBatteryMonitoringEnabled = true
        if usesDeviceServices { UNUserNotificationCenter.current().delegate = notificationPresenter }
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
        let defaults = UserDefaults.standard
        seenNotes = isSimulation ? [] : defaults.stringArray(forKey: Keys.seenNotes) ?? []
        newsSince = isSimulation ? Date() : defaults.object(forKey: Keys.newsSince) as? Date ?? Date()
        if !isSimulation { defaults.set(newsSince, forKey: Keys.newsSince) }
        sendsMorningGreeting = !isSimulation && defaults.bool(forKey: Keys.morningGreeting)
        lastMorningGreeting = isSimulation ? nil : defaults.object(forKey: Keys.lastMorningGreeting) as? Date
        fog = isSimulation ? nil : defaults.data(forKey: Keys.fog).flatMap { try? JSONDecoder().decode(Fog.self, from: $0) }
        phase = .onboarding
        if !displayName.isEmpty, let client = try? makeClient(name: displayName) {
            self.client = client
            phase = .ready
            subscribe(client)
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
            subscribe(client)
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
        guard let details = try? await client.circle(ref) else { return nil }
        deliverNews(details)
        return details
    }

    // MARK: Location

    /// Tracks while set up: in the background while sharing (also after iOS
    /// relaunched the app for a location event), else only for the map.
    private func updateTracking() {
        guard usesDeviceServices else { return }
        guard phase == .ready else {
            tracker.stop()
            return
        }
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) }
        tracker.start(background: isSharingLocation && !isSimulation) { [weak self] location in
            Task { await self?.share(location) }
        }
    }

    private func share(_ location: CLLocation) async {
        guard isSharingLocation, let client, (0 ... 1000).contains(location.horizontalAccuracy) else { return }
        let inBackground = UIApplication.shared.applicationState != .active
        let policy: SharePolicy = inBackground ? .background : .foreground
        let device = UIDevice.current
        let battery = device.batteryLevel >= 0 ? Int((device.batteryLevel * 100).rounded()) : nil
        let charging = device.batteryState == .charging || device.batteryState == .full
        guard policy.shouldShare(location, after: lastShared),
              let exact = SharedLocation(location, battery: battery, isCharging: charging)
        else { return }
        // In fog the exact position never leaves the device.
        let shared = activeFog.flatMap { exact.inFog(radius: $0.radius) } ?? exact
        lastShared = location
        // Finish the upload even if iOS suspends the app right after this update.
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "share-location")
        if (try? await client.shareLocation(shared)) != nil {
            lastSharedAt = Date()
            if !isSimulation { UserDefaults.standard.set(lastSharedAt, forKey: Keys.lastSharedAt) }
            await greetMorningIfDue()
            // While the app is closed, this is when news arrives (until push).
            if inBackground { await checkForNews() }
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

    // MARK: Push

    /// Silent pushes for changes in any circle. Failures are fine: polling
    /// and background location updates still pick up news.
    private func subscribe(_ client: LeuchtturmClient) {
        guard usesDeviceServices else { return }
        Task { try? await client.subscribeToChanges() }
    }

    /// A silent push arrived: let open views reload.
    func noteRemoteChange() {
        externalChanges += 1
    }

    // MARK: Notes

    /// Sends a reaction, note, check-in (with the current position) or
    /// good-morning. Returns false and shows the error on failure.
    @discardableResult
    func send(_ kind: CircleNote.Kind, text: String = "", to recipientID: String? = nil, in ref: CircleRef) async -> Bool {
        if kind == .checkIn && activeFog != nil {
            errorMessage = "Im Nebel teilst du keinen genauen Ort. Beende den Nebel zuerst, um einzuchecken."
            return false
        }
        let location = kind == .checkIn ? tracker.location.flatMap { SharedLocation($0) } : nil
        if kind == .checkIn && location == nil {
            errorMessage = "Dein Standort ist noch nicht bekannt. Bitte versuch es gleich noch einmal."
            return false
        }
        guard let note = await run({ try await $0.send(kind, text: text, to: recipientID, location: location, in: ref) })
        else { return false }
        markSeen([note.id])
        return true
    }

    // MARK: Fog

    func startFog(radius: Int, hours: Double) async {
        setFog(Fog(radius: radius, until: Date().addingTimeInterval(hours * 3600)))
        await shareLocationNow()
    }

    func endFog() async {
        setFog(nil)
        await shareLocationNow()
    }

    private func setFog(_ new: Fog?) {
        fog = new
        guard !isSimulation else { return }
        UserDefaults.standard.set(new.flatMap { try? JSONEncoder().encode($0) }, forKey: Keys.fog)
    }

    func setMorningGreeting(_ on: Bool) {
        sendsMorningGreeting = on
        if !isSimulation { UserDefaults.standard.set(on, forKey: Keys.morningGreeting) }
    }

    private func greetMorningIfDue() async {
        let now = Date()
        guard sendsMorningGreeting, let client, (5 ..< 12).contains(Calendar.current.component(.hour, from: now)),
              !(lastMorningGreeting.map { Calendar.current.isDate($0, inSameDayAs: now) } ?? false)
        else { return }
        lastMorningGreeting = now
        if !isSimulation { UserDefaults.standard.set(now, forKey: Keys.lastMorningGreeting) }
        for circle in (try? await client.circles()) ?? [] {
            _ = try? await client.send(.morning, in: circle.ref)
        }
    }

    /// Loads every circle and notifies about new notes.
    func checkForNews() async {
        guard let client else { return }
        for circle in (try? await client.circles()) ?? [] {
            if let details = try? await client.circle(circle.ref) { deliverNews(details) }
        }
    }

    /// Notifies once about each new note from others that is for me or for
    /// everyone.
    func deliverNews(_ details: CircleDetails) {
        guard let me = client?.deviceID else { return }
        let fresh = details.notes.filter {
            $0.senderID != me && ($0.recipientID == nil || $0.recipientID == me)
                && $0.timestamp > newsSince && !seenNotes.contains($0.id)
        }
        guard !fresh.isEmpty else { return }
        markSeen(fresh.map(\.id))
        guard usesDeviceServices else { return }
        for note in fresh.reversed() {
            let sender = details.members.first { $0.id == note.senderID }?.name ?? "Jemand"
            let content = UNMutableNotificationContent()
            content.title = sender
            content.subtitle = details.name ?? ""
            content.body = NoteText.body(note, members: details.members, myID: me)
            content.sound = .default
            content.threadIdentifier = details.id
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: note.id, content: content, trigger: nil))
        }
    }

    private func markSeen(_ ids: [String]) {
        seenNotes = Array((seenNotes + ids).suffix(500))
        if !isSimulation { UserDefaults.standard.set(seenNotes, forKey: Keys.seenNotes) }
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
            case .invalidNote: return "Die Nachricht ist zu lang."
            }
        case is ProtocolError:
            return "Die Daten konnten nicht entschlüsselt oder geprüft werden."
        default:
            return "Unbekannter Fehler."
        }
    }
}

/// Fog mode: sharing only an approximate area until a given time.
struct Fog: Codable, Equatable {
    /// Meters; see `SharedLocation.inFog(radius:)`.
    let radius: Int
    let until: Date

    static let sizes: [(radius: Int, label: LocalizedStringResource)] = [
        (1000, "Stadtteil (ca. 2 km)"), (5000, "Stadt (ca. 10 km)"), (25000, "Region (ca. 50 km)"),
    ]
}
