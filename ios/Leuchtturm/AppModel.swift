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
        static let keysOnDeviceOnly = "keysOnDeviceOnly"
        static let lastSharedAt = "lastSharedAt"
        static let seenNotes = "seenNotes"
        static let newsSince = "newsSince"
        static let morningGreeting = "morningGreeting"
        static let lastMorningGreeting = "lastMorningGreeting"
        static let fog = "fog"
        static let placeTracker = "placeTracker"
        static let sharesHistory = "sharesHistory"
        static let historyDays = "historyDays"
        static let sharesTrips = "sharesTrips"
        static let tripDetector = "tripDetector"
        static let detectsCrashes = "detectsCrashes"
        static let journey = "journey"
        static let lowBatteryWarned = "lowBatteryWarned"
        static let arrivalWatches = "arrivalWatches"
        static let verifiedDevices = "verifiedDevices"
        static let knownMembers = "knownMembers"
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

    /// Keys travel with iCloud Keychain unless the user keeps them on this device.
    private(set) var keysOnDeviceOnly = UserDefaults.standard.bool(forKey: Keys.keysOnDeviceOnly)
    private var keychain: KeychainSecretStore { KeychainSecretStore(synchronized: !keysOnDeviceOnly) }
    /// While set and not expired, only an approximate area is shared.
    private(set) var fog: Fog?
    var activeFog: Fog? { fog.flatMap { $0.until > Date() ? $0 : nil } }

    /// "Bin auf dem Weg" or "Heimweg" of this device, until arrival.
    private(set) var journey: Journey?
    /// Share the next position even if the policy would skip it.
    @ObservationIgnored private var forceShare = false

    /// This device's picture, pin and status, kept locally and written to all circles.
    private(set) var myProfile = Profile()

    /// Shares today's path (and keeps `historyDays` days) with the circles.
    private(set) var sharesHistory = false
    private(set) var historyDays = 7
    @ObservationIgnored private var historyRecorder = HistoryRecorder(persistent: false)
    /// Detects drives on this device and shares them (and live speed).
    private(set) var sharesTrips = false
    @ObservationIgnored private var tripDetector = TripDetector()
    @ObservationIgnored private let motion = MotionMonitor()
    @ObservationIgnored private var visitStore = VisitStore(persistent: false)
    /// Asks "Are you OK?" after an abrupt stop while driving. On by default.
    private(set) var detectsCrashes = true
    /// Set while the "Are you OK?" countdown runs: when the SOS goes out.
    private(set) var crashCheckDeadline: Date?
    /// The last SOS this device sent, until the all-clear.
    private(set) var sosSentAt: Date?

    /// Says "good morning" to the circles on the first movement of the day.
    private(set) var sendsMorningGreeting = false
    /// Notes already notified (or sent by me), so each one notifies once.
    @ObservationIgnored private var seenNotes: [String] = []
    /// Notes older than this never notify, e.g. from before the setup.
    @ObservationIgnored private var newsSince = Date()
    @ObservationIgnored private var lastMorningGreeting: Date?
    @ObservationIgnored private let notificationPresenter = NotificationPresenter()
    /// Devices whose safety code the user compared in person.
    private(set) var verifiedDevices: Set<String> = []
    /// Member devices seen per circle, to notice new keys.
    @ObservationIgnored private var knownMembers: [String: Set<String>] = [:]
    /// "Not arrived yet" alerts set on this device.
    private(set) var arrivalWatches: [ArrivalWatch] = []
    /// Every circle as last loaded, for arrival checks.
    @ObservationIgnored private var latestDetails: [String: CircleDetails] = [:]
    /// Places of every circle, from the last time each circle was loaded.
    @ObservationIgnored private var knownPlaces: [String: (ref: CircleRef, places: [CirclePlace])] = [:]
    @ObservationIgnored private var placeTracker = PlaceTracker()

    /// Off in unit tests, which must not start CoreLocation or ask for notifications.
    private let usesDeviceServices: Bool

    init(usesDeviceServices: Bool = true) {
        self.usesDeviceServices = usesDeviceServices
        UIDevice.current.isBatteryMonitoringEnabled = true
        if usesDeviceServices {
            let center = UNUserNotificationCenter.current()
            center.delegate = notificationPresenter
            center.setNotificationCategories([UNNotificationCategory(
                identifier: Self.crashCategory,
                actions: [
                    UNNotificationAction(identifier: Self.crashOK, title: String(localized: "Mir geht's gut")),
                    UNNotificationAction(identifier: Self.crashHelp, title: String(localized: "Hilfe rufen"), options: [.destructive]),
                ],
                intentIdentifiers: []
            )])
            notificationPresenter.onAction = { [weak self] action in self?.handleNotificationAction(action) }
        }
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
        // An iPad shares no location unless asked to (the iPhone usually does).
        let pausedByDefault = UIDevice.current.userInterfaceIdiom != .phone
        isSharingLocation = isSimulation
            || !(UserDefaults.standard.object(forKey: Keys.locationPaused) as? Bool ?? pausedByDefault)
        lastSharedAt = isSimulation ? nil : UserDefaults.standard.object(forKey: Keys.lastSharedAt) as? Date
        let defaults = UserDefaults.standard
        seenNotes = isSimulation ? [] : defaults.stringArray(forKey: Keys.seenNotes) ?? []
        newsSince = isSimulation ? Date() : defaults.object(forKey: Keys.newsSince) as? Date ?? Date()
        if !isSimulation { defaults.set(newsSince, forKey: Keys.newsSince) }
        sendsMorningGreeting = !isSimulation && defaults.bool(forKey: Keys.morningGreeting)
        lastMorningGreeting = isSimulation ? nil : defaults.object(forKey: Keys.lastMorningGreeting) as? Date
        knownPlaces = [:]
        journey = isSimulation ? nil : defaults.data(forKey: Keys.journey).flatMap { try? JSONDecoder().decode(Journey.self, from: $0) }
        myProfile = isSimulation ? Profile() : Self.loadStoredProfile() ?? Profile()
        latestDetails = [:]
        verifiedDevices = isSimulation ? [] : Set(defaults.stringArray(forKey: Keys.verifiedDevices) ?? [])
        knownMembers = isSimulation ? [:] : (defaults.dictionary(forKey: Keys.knownMembers) as? [String: [String]] ?? [:])
            .mapValues { Set($0) }
        visitStore = VisitStore(persistent: !isSimulation)
        arrivalWatches = isSimulation ? [] : defaults.data(forKey: Keys.arrivalWatches)
            .flatMap { try? JSONDecoder().decode([ArrivalWatch].self, from: $0) } ?? []
        sharesHistory = !isSimulation && defaults.bool(forKey: Keys.sharesHistory)
        historyDays = isSimulation ? 7 : (defaults.object(forKey: Keys.historyDays) as? Int ?? 7)
        historyRecorder = HistoryRecorder(persistent: !isSimulation)
        sharesTrips = !isSimulation && defaults.bool(forKey: Keys.sharesTrips)
        detectsCrashes = isSimulation || (defaults.object(forKey: Keys.detectsCrashes) as? Bool ?? true)
        tripDetector = isSimulation ? TripDetector() : defaults.data(forKey: Keys.tripDetector)
            .flatMap { try? JSONDecoder().decode(TripDetector.self, from: $0) } ?? TripDetector()
        placeTracker = isSimulation ? PlaceTracker() : defaults.data(forKey: Keys.placeTracker)
            .flatMap { try? JSONDecoder().decode(PlaceTracker.self, from: $0) } ?? PlaceTracker()
        fog = isSimulation ? nil : defaults.data(forKey: Keys.fog).flatMap { try? JSONDecoder().decode(Fog.self, from: $0) }
        phase = .onboarding
        if !displayName.isEmpty, let client = try? makeClient(name: displayName) {
            self.client = client
            phase = .ready
            subscribe(client)
            // Also after a background relaunch: load places and news.
            Task { await checkForNews() }
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
            errorMessage = String(localized: "Bitte gib einen Namen mit höchstens \(LeuchtturmClient.maxNameLength) Zeichen ein.")
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

    func createCircle(name: String, lasting days: Int? = nil) async -> CircleRef? {
        let expiresAt = days.map { Date().addingTimeInterval(Double($0) * 86400) }
        let ref = await run { try await $0.createCircle(name: name, expiresAt: expiresAt) }
        if let ref {
            await pushProfile(to: ref)
            await shareLocationNow()
            await refresh()
        }
        return ref
    }

    func join(_ link: InviteLink) async -> CircleRef? {
        let ref = await run { try await $0.join(link) }
        if let ref {
            await pushProfile(to: ref)
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
            motion.stop()
            return
        }
        if sharesTrips && !isSimulation { motion.start() } else { motion.stop() }
        tracker.onVisit = { [weak self] visit in self?.visitStore.add(visit) }
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) }
        tracker.start(background: isSharingLocation && !isSimulation) { [weak self] location in
            Task { await self?.share(location) }
        }
    }

    private func share(_ location: CLLocation) async {
        guard isSharingLocation, let client, (0 ... 1000).contains(location.horizontalAccuracy) else { return }
        await watchPlaces(location)
        await watchTrips(location)
        let inBackground = UIApplication.shared.applicationState != .active
        let policy: SharePolicy = inBackground ? .background : .foreground
        let device = UIDevice.current
        let battery = device.batteryLevel >= 0 ? Int((device.batteryLevel * 100).rounded()) : nil
        let charging = device.batteryState == .charging || device.batteryState == .full
        await warnIfBatteryLow(battery, charging: charging)
        await watchJourney(location)
        let forced = forceShare
        forceShare = false
        guard forced || policy.shouldShare(location, after: lastShared),
              let exact = SharedLocation(
                  location, battery: battery, isCharging: charging,
                  speed: sharesTrips && tripDetector.isDriving && location.speed >= 0 ? location.speed : nil
              )
        else { return }
        // In fog the exact position never leaves the device.
        let shared = activeFog.flatMap { exact.inFog(radius: $0.radius) } ?? exact
        lastShared = location
        // Finish the upload even if iOS suspends the app right after this update.
        // History: exact points, but never while in fog.
        let history = sharesHistory && activeFog == nil
            ? HistoryUpdate(
                today: historyRecorder.add(latitude: exact.latitude, longitude: exact.longitude, at: exact.timestamp, deviceID: client.deviceID),
                keepDays: historyDays
            )
            : nil
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "share-location")
        if (try? await client.shareLocation(shared, history: history)) != nil {
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
            errorMessage = String(localized: "Im Nebel teilst du keinen genauen Ort. Beende den Nebel zuerst, um einzuchecken.")
            return false
        }
        // An SOS always carries the exact position, also in fog.
        let location = [.checkIn, .sos, .pickUp].contains(kind) ? tracker.location.flatMap { SharedLocation($0) } : nil
        if kind == .pickUp && location == nil {
            errorMessage = String(localized: "Dein Standort ist noch nicht bekannt. Bitte versuch es gleich noch einmal.")
            return false
        }
        if kind == .checkIn && location == nil {
            errorMessage = String(localized: "Dein Standort ist noch nicht bekannt. Bitte versuch es gleich noch einmal.")
            return false
        }
        guard let note = await run({ try await $0.send(kind, text: text, to: recipientID, location: location, in: ref) })
        else { return false }
        markSeen([note.id])
        return true
    }

    // MARK: Places

    /// Arrivals and departures are detected here, on the device, and told
    /// to the circle as notes. Not while in fog: that would reveal the place.
    private func watchPlaces(_ location: CLLocation) async {
        guard activeFog == nil, let client, !knownPlaces.isEmpty else { return }
        let events = placeTracker.update(
            latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
            accuracy: location.horizontalAccuracy, places: knownPlaces.values.flatMap(\.places)
        )
        if !isSimulation {
            UserDefaults.standard.set(try? JSONEncoder().encode(placeTracker), forKey: Keys.placeTracker)
        }
        for event in events {
            let (kind, place): (CircleNote.Kind, CirclePlace) = switch event {
            case let .arrived(place): (.arrival, place)
            case let .left(place): (.departure, place)
            }
            guard let ref = knownPlaces.values.first(where: { $0.places.contains(place) })?.ref,
                  let note = try? await client.send(kind, text: place.name, in: ref)
            else { continue }
            markSeen([note.id])
        }
    }

    // MARK: Trips

    private func watchTrips(_ location: CLLocation) async {
        guard sharesTrips || detectsCrashes, let client else { return }
        let trip = tripDetector.update(
            latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
            speed: location.speed, at: location.timestamp, deviceID: client.deviceID, automotive: motion.automotive
        )
        saveTripDetector()
        if tripDetector.takeCrash() != nil, detectsCrashes { startCrashCheck() }
        if let trip, sharesTrips { try? await client.shareTrip(trip) }
    }

    /// After parking iOS pauses updates; end the trip when the app wakes up.
    private func finishStaleTrip() async {
        guard sharesTrips, let client, let trip = tripDetector.finishIfStale(now: Date(), deviceID: client.deviceID) else { return }
        saveTripDetector()
        try? await client.shareTrip(trip)
    }

    private func saveTripDetector() {
        guard !isSimulation else { return }
        UserDefaults.standard.set(try? JSONEncoder().encode(tripDetector), forKey: Keys.tripDetector)
    }

    /// Turning trips off deletes them from every circle right away.
    func setSharesTrips(_ on: Bool) async {
        sharesTrips = on
        if !isSimulation { UserDefaults.standard.set(on, forKey: Keys.sharesTrips) }
        updateTracking()
        if !on {
            tripDetector = TripDetector()
            saveTripDetector()
            await run { try await $0.deleteTrips() }
        }
    }

    // MARK: Journeys

    func startJourney(_ new: Journey) async -> Bool {
        guard let ref = circles.first(where: { $0.id == new.circleID })?.ref,
              let destination = SharedLocation(latitude: new.latitude, longitude: new.longitude, accuracy: 50, timestamp: Date())
        else { return false }
        let kind: CircleNote.Kind = new.isWalkHome ? .walkHome : .onMyWay
        guard let note = await run({ try await $0.send(kind, text: new.destination, location: destination, deadline: new.deadline, in: ref) })
        else { return false }
        markSeen([note.id])
        setJourney(new)
        await shareLocationNow()
        noteRemoteChange()
        return true
    }

    func cancelJourney() async {
        guard let journey, let ref = circles.first(where: { $0.id == journey.circleID })?.ref else { setJourney(nil); return }
        await send(.journeyCancelled, text: journey.destination, in: ref)
        setJourney(nil)
        noteRemoteChange()
    }

    private func setJourney(_ new: Journey?) {
        journey = new
        if !isSimulation { UserDefaults.standard.set(new.flatMap { try? JSONEncoder().encode($0) }, forKey: Keys.journey) }
    }

    /// Arrived within 150 m of the destination: tell the circle.
    private func watchJourney(_ location: CLLocation) async {
        guard let journey, location.distance(from: CLLocation(latitude: journey.latitude, longitude: journey.longitude)) <= 150,
              let ref = circles.first(where: { $0.id == journey.circleID })?.ref
        else { return }
        setJourney(nil)
        await send(.arrival, text: journey.destination, in: ref)
        noteRemoteChange()
    }

    func sendMeetingPoint(name: String, coordinate: CLLocationCoordinate2D, in ref: CircleRef) async -> Bool {
        guard let point = SharedLocation(latitude: coordinate.latitude, longitude: coordinate.longitude, accuracy: 30, timestamp: Date()),
              let note = await run({ try await $0.send(.meetingPoint, text: name, location: point, in: ref) })
        else { return false }
        markSeen([note.id])
        noteRemoteChange()
        return true
    }

    /// The circle a member is in (the first one this device knows).
    func circleOf(_ memberID: String) -> String? {
        latestDetails.first { $0.value.members.contains { $0.id == memberID } }?.key
    }

    // MARK: Chat

    @discardableResult
    func sendChat(_ text: String, replyTo: String? = nil, reactsTo: String? = nil, image: Data? = nil, isSticker: Bool = false, in ref: CircleRef) async -> Bool {
        guard let message = await run({ try await $0.sendMessage(text, replyTo: replyTo, reactsTo: reactsTo, image: image, isSticker: isSticker, in: ref) })
        else { return false }
        markSeen([message.id])
        noteRemoteChange()
        return true
    }

    // MARK: Profile

    private static var profileURL: URL { URL.applicationSupportDirectory.appending(path: "profile.json") }

    private struct StoredProfile: Codable {
        var color, emoji, bannerStyle, statusEmoji, statusText: String?
        var photo, banner: Data?
        var statusUntil: Date?
    }

    private static func loadStoredProfile() -> Profile? {
        guard let data = try? Data(contentsOf: profileURL), let s = try? JSONDecoder().decode(StoredProfile.self, from: data) else { return nil }
        return Profile(color: s.color, emoji: s.emoji, photo: s.photo, banner: s.banner, bannerStyle: s.bannerStyle,
                       statusEmoji: s.statusEmoji, statusText: s.statusText, statusUntil: s.statusUntil)
    }

    /// Saves locally and sends to every circle.
    func saveProfile(_ profile: Profile) async -> Bool {
        guard await run({ try await $0.setProfile(profile) }) != nil else { return false }
        myProfile = profile
        if !isSimulation {
            let stored = StoredProfile(color: profile.color, emoji: profile.emoji, bannerStyle: profile.bannerStyle,
                                       statusEmoji: profile.statusEmoji, statusText: profile.statusText,
                                       photo: profile.photo, banner: profile.banner, statusUntil: profile.statusUntil)
            try? FileManager.default.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
            try? JSONEncoder().encode(stored).write(to: Self.profileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        noteRemoteChange()
        return true
    }

    private func pushProfile(to ref: CircleRef) async {
        guard myProfile != Profile() else { return }
        let profile = myProfile
        await run { try await $0.setProfile(profile, in: [ref]) }
    }

    // MARK: Key storage

    /// Moves all keys into or out of iCloud Keychain.
    func setKeysOnDeviceOnly(_ onDevice: Bool) {
        guard onDevice != keysOnDeviceOnly else { return }
        do {
            try KeychainSecretStore(synchronized: !onDevice).migrateAll()
            keysOnDeviceOnly = onDevice
            UserDefaults.standard.set(onDevice, forKey: Keys.keysOnDeviceOnly)
        } catch {
            errorMessage = String(localized: "Die Schlüssel konnten nicht umgezogen werden.")
        }
    }

    // MARK: Roles

    /// Takes the Leuchtturm over (admins) and switches to the new one.
    @discardableResult
    func takeOver(_ ref: CircleRef) async -> CircleRef? {
        guard let newRef = await run({ try await $0.takeOver(ref) }) else { return nil }
        await pushProfile(to: newRef)
        await refresh()
        noteRemoteChange()
        return newRef
    }

    // MARK: Safety codes

    func setVerified(_ deviceID: String, _ verified: Bool) {
        if verified { verifiedDevices.insert(deviceID) } else { verifiedDevices.remove(deviceID) }
        if !isSimulation { UserDefaults.standard.set(Array(verifiedDevices), forKey: Keys.verifiedDevices) }
    }

    /// Members that joined (or got a new key, e.g. after reinstalling) since
    /// this device last looked at the circle. Records them as known.
    func newMembers(in details: CircleDetails) -> [CircleMember] {
        let current = Set(details.members.filter { !$0.isMe && !$0.isPending }.map(\.id))
        defer {
            knownMembers[details.id] = current
            if !isSimulation {
                UserDefaults.standard.set(knownMembers.mapValues { Array($0) }, forKey: Keys.knownMembers)
            }
        }
        // The first look at a circle only records who is there.
        guard let known = knownMembers[details.id] else { return [] }
        return details.members.filter { current.contains($0.id) && !known.contains($0.id) }
    }

    /// "New in Familie: Dave. Compare the safety code."
    private func announceNewMembers(_ details: CircleDetails) {
        let fresh = newMembers(in: details)
        guard usesDeviceServices, !fresh.isEmpty else { return }
        for member in fresh {
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Neu in „\(details.name ?? "deinem Leuchtturm")“: \(member.name ?? "Unbekannt")")
            content.body = String(localized: "Vergleicht den Sicherheitscode persönlich, bevor ihr euch darauf verlasst: \(member.safetyCode)")
            content.sound = .default
            content.threadIdentifier = details.id
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "member-\(member.id)", content: content, trigger: nil))
        }
    }

    // MARK: Arrival watches

    /// The circle as last loaded on this device.
    func latestCircle(_ circleID: String) -> CircleDetails? {
        latestDetails[circleID]
    }

    func places(inCircle circleID: String) -> [CirclePlace] {
        latestDetails[circleID]?.places ?? knownPlaces[circleID]?.places ?? []
    }

    /// Spots you often stay at that are no place in the circle yet. Computed
    /// from stays stored only on this device.
    func placeSuggestions(inCircle circleID: String) -> [PlaceSuggestion] {
        PlaceSuggestion.suggest(visits: visitStore.visits, existing: places(inCircle: circleID), calendar: .current)
    }

    func addArrivalWatch(member: CircleMember, place: CirclePlace, circleID: String, hour: Int, minute: Int, repeats: ArrivalWatch.Repeat) async {
        arrivalWatches.append(ArrivalWatch(
            id: CircleCrypto.newCircleID(), circleID: circleID, memberID: member.id, placeID: place.id,
            hour: hour, minute: minute, repeats: repeats, created: Date()
        ))
        saveArrivalWatches()
        await scheduleArrivalWatches()
    }

    func removeArrivalWatch(_ id: String) async {
        arrivalWatches.removeAll { $0.id == id }
        saveArrivalWatches()
        await scheduleArrivalWatches()
    }

    private func saveArrivalWatches() {
        guard !isSimulation else { return }
        UserDefaults.standard.set(try? JSONEncoder().encode(arrivalWatches), forKey: Keys.arrivalWatches)
    }

    /// Keeps one local notification per open deadline in the next 7 days
    /// and withdraws it as soon as the member is known to have arrived.
    func scheduleArrivalWatches() async {
        let calendar = Calendar.current
        let now = Date()
        // One-off watches whose deadline has passed are done.
        let finished = arrivalWatches.filter { $0.repeats == .once && $0.deadlines(after: $0.created, days: 2, calendar: calendar).allSatisfy { $0 < now } }
        if !finished.isEmpty {
            arrivalWatches.removeAll { w in finished.contains { $0.id == w.id } }
            saveArrivalWatches()
        }
        guard usesDeviceServices else { return }

        var desired: [String: UNNotificationRequest] = [:]
        // Heimweg-Begleitung of others: alert at the deadline unless they arrived.
        for details in latestDetails.values {
            for member in details.members where !member.isMe {
                guard let walk = activeJourney(of: member.id, in: details.notes, now: now), walk.kind == .walkHome,
                      let deadline = walk.deadline, deadline > now, let destination = walk.location
                else { continue }
                if let l = member.location, l.timestamp > walk.timestamp,
                   CLLocation(latitude: l.latitude, longitude: l.longitude).distance(from: destination.clLocation) <= 150 { continue }
                let id = "walk-\(walk.id)"
                let content = UNMutableNotificationContent()
                content.title = String(localized: "⏰ \(member.name ?? "Jemand") ist noch nicht angekommen")
                content.body = String(localized: "Der Heimweg nach „\(walk.text)“ sollte bis \(deadline.formatted(date: .omitted, time: .shortened)) dauern. Vielleicht mal nachfragen?")
                content.sound = .default
                content.interruptionLevel = .timeSensitive
                content.threadIdentifier = details.id
                let trigger = UNCalendarNotificationTrigger(dateMatching: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: deadline), repeats: false)
                desired[id] = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
            }
        }
        for watch in arrivalWatches {
            guard let details = latestDetails[watch.circleID],
                  let place = details.places.first(where: { $0.id == watch.placeID }),
                  let member = details.members.first(where: { $0.id == watch.memberID })
            else { continue }
            for deadline in watch.deadlines(after: now, days: 7, calendar: calendar)
            where !watch.isSatisfied(deadline: deadline, place: place, location: member.location, notes: details.notes, calendar: calendar) {
                let id = "watch-\(watch.id)-\(Int(deadline.timeIntervalSince1970))"
                let content = UNMutableNotificationContent()
                content.title = String(localized: "⏰ \(member.name ?? "Jemand") ist noch nicht angekommen")
                content.body = String(localized: "Bis \(deadline.formatted(date: .omitted, time: .shortened)) gab es keine Ankunft bei „\(place.name)“.")
                content.sound = .default
                content.interruptionLevel = .timeSensitive
                content.threadIdentifier = details.id
                let trigger = UNCalendarNotificationTrigger(
                    dateMatching: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: deadline), repeats: false
                )
                desired[id] = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
            }
        }
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix("watch-") || $0.hasPrefix("walk-") }
        center.removePendingNotificationRequests(withIdentifiers: pending.filter { desired[$0] == nil })
        for (id, request) in desired where !pending.contains(id) {
            try? await center.add(request)
        }
    }

    // MARK: Battery

    static let lowBatteryLevel = 15

    /// Tells the circles once per discharge when the battery gets low.
    private func warnIfBatteryLow(_ level: Int?, charging: Bool) async {
        guard let level, !isSimulation else { return }
        let defaults = UserDefaults.standard
        if charging || level > 30 {
            defaults.set(false, forKey: Keys.lowBatteryWarned)
            return
        }
        guard level <= Self.lowBatteryLevel, !defaults.bool(forKey: Keys.lowBatteryWarned) else { return }
        defaults.set(true, forKey: Keys.lowBatteryWarned)
        for circle in circles { await send(.lowBattery, text: "\(level)", in: circle.ref) }
    }

    // MARK: SOS and crash detection

    static let crashCategory = "crash"
    static let crashOK = "crash-ok"
    static let crashHelp = "crash-help"
    static let crashCountdown: TimeInterval = 60

    /// Alerts every circle with the exact position. Returns false if no circle got it.
    @discardableResult
    func sendSOS(reason: String = "") async -> Bool {
        var sent = false
        for circle in circles where await send(.sos, text: reason, in: circle.ref) { sent = true }
        if sent { sosSentAt = Date() }
        return sent
    }

    func sendAllClear() async {
        for circle in circles { await send(.safe, in: circle.ref) }
        sosSentAt = nil
    }

    func setDetectsCrashes(_ on: Bool) {
        detectsCrashes = on
        if !isSimulation { UserDefaults.standard.set(on, forKey: Keys.detectsCrashes) }
    }

    /// "Are you OK?": in the app and as a notification with answers. Without
    /// an answer the SOS goes out after the countdown.
    func startCrashCheck() {
        guard crashCheckDeadline == nil else { return }
        let deadline = Date().addingTimeInterval(Self.crashCountdown)
        crashCheckDeadline = deadline
        if usesDeviceServices {
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Alles okay?")
            content.body = String(localized: "Es sah nach einem Unfall aus. Ohne Antwort alarmiert die App in 60 Sekunden deine Leuchttürme.")
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            content.categoryIdentifier = Self.crashCategory
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "crash-check", content: content, trigger: nil))
        }
        Task {
            try? await Task.sleep(for: .seconds(Self.crashCountdown))
            guard crashCheckDeadline == deadline else { return }
            await confirmCrashHelp()
        }
    }

    func cancelCrashCheck() {
        crashCheckDeadline = nil
        if usesDeviceServices {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["crash-check"])
        }
    }

    func confirmCrashHelp() async {
        cancelCrashCheck()
        await sendSOS(reason: String(localized: "Möglicher Unfall erkannt"))
    }

    private func handleNotificationAction(_ action: String) {
        switch action {
        case Self.crashOK: cancelCrashCheck()
        case Self.crashHelp: Task { await confirmCrashHelp() }
        default: break
        }
    }

    // MARK: History

    /// Turning history off deletes it from every circle right away.
    func setSharesHistory(_ on: Bool) async {
        sharesHistory = on
        if !isSimulation { UserDefaults.standard.set(on, forKey: Keys.sharesHistory) }
        if on {
            await shareLocationNow()
        } else {
            historyRecorder.clear()
            await run { try await $0.deleteHistory() }
        }
    }

    func setHistoryDays(_ days: Int) async {
        historyDays = days
        if !isSimulation { UserDefaults.standard.set(days, forKey: Keys.historyDays) }
        await shareLocationNow()
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
        await finishStaleTrip()
        for circle in (try? await client.circles()) ?? [] {
            if let details = try? await client.circle(circle.ref) { deliverNews(details) }
        }
    }

    /// Notifies once about each new note from others that is for me or for
    /// everyone.
    func deliverNews(_ details: CircleDetails) {
        latestDetails[details.id] = details
        announceNewMembers(details)
        if !arrivalWatches.isEmpty || details.notes.contains(where: { $0.kind == .walkHome }) { Task { await scheduleArrivalWatches() } }
        let placesChanged = knownPlaces[details.id]?.places != details.places
        knownPlaces[details.id] = (details.ref, details.places)
        if placesChanged, usesDeviceServices {
            let all = knownPlaces.values.flatMap(\.places)
            Task { await tracker.monitor(places: all) }
        }
        guard let me = client?.deviceID else { return }
        let fresh = details.notes.filter {
            $0.senderID != me && ($0.recipientID == nil || $0.recipientID == me)
                && $0.timestamp > newsSince && !seenNotes.contains($0.id)
        }
        let newMessages = details.messages.filter {
            $0.senderID != me && $0.timestamp > newsSince && !seenNotes.contains($0.id)
        }
        if !newMessages.isEmpty {
            markSeen(newMessages.map(\.id))
            if usesDeviceServices {
                for message in newMessages {
                    let sender = details.members.first { $0.id == message.senderID }?.name ?? String(localized: "Jemand")
                    let content = UNMutableNotificationContent()
                    content.title = sender
                    content.subtitle = details.name ?? ""
                    content.body = message.reactsTo != nil
                        ? String(localized: "hat mit \(message.text) reagiert")
                        : message.text.isEmpty ? String(localized: message.isSticker ? "hat einen Sticker gesendet" : "hat ein Foto gesendet") : message.text
                    content.sound = .default
                    content.threadIdentifier = "chat-\(details.id)"
                    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: message.id, content: content, trigger: nil))
                }
            }
        }
        guard !fresh.isEmpty else { return }
        markSeen(fresh.map(\.id))
        if fresh.contains(where: { $0.kind == .locationRequest && $0.recipientID == me }), isSharingLocation {
            forceShare = true
            tracker.requestFresh()
            if let here = tracker.location { Task { await share(here) } }
        }
        guard usesDeviceServices else { return }
        for note in fresh.reversed() {
            let sender = details.members.first { $0.id == note.senderID }?.name ?? String(localized: "Jemand")
            let content = UNMutableNotificationContent()
            content.title = sender
            content.subtitle = details.name ?? ""
            content.body = NoteText.body(note, members: details.members, myID: me)
            content.sound = .default
            if note.kind == .sos {
                content.title = String(localized: "🆘 \(sender) braucht Hilfe")
                content.body = note.text.isEmpty
                    ? String(localized: "Tippe, um den Ort zu sehen.")
                    : String(localized: "\(note.text). Tippe, um den Ort zu sehen.")
                content.interruptionLevel = .timeSensitive
            }
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
        historyRecorder.clear()
        visitStore.clear()
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
        let here = tracker.location
        let home = here?.coordinate ?? SimulatedWorld.fallbackHome
        await run { try await $0.addPlace(name: "Zuhause", emoji: "🏠", latitude: home.latitude, longitude: home.longitude, radius: 150, in: ref) }
        await simulate { world in
            for person in world.people {
                try await world.join(person, using: link)
            }
            try await world.addDemoPlaces(circleID: ref.circleID, near: here)
            try await world.addDemoTrips(near: here)
        }
        // Everyone has their own look.
        await simulate { world in
            try await world.people[0].client.setProfile(Profile(color: "#D9567F", bannerStyle: "sunset", statusEmoji: "☕️", statusText: String(localized: "Kaffeepause"), statusUntil: Date().addingTimeInterval(3600)))
            try await world.people[1].client.setProfile(Profile(color: "#E0533A", emoji: "🏎️", bannerStyle: "night"))
            try await world.people[2].client.setProfile(Profile(color: "#9576C9", photo: SimulatedWorld.demoPhoto(), bannerStyle: "lavender", statusEmoji: "📚", statusText: String(localized: "in der Schule")))
        }
        // A little chat to start with.
        await simulate { world in
            let (anna, ben, clara) = (world.people[0].client, world.people[1].client, world.people[2].client)
            guard let annasRef = try await anna.circles().first(where: { $0.id == ref.circleID })?.ref,
                  let bensRef = try await ben.circles().first(where: { $0.id == ref.circleID })?.ref,
                  let clarasRef = try await clara.circles().first(where: { $0.id == ref.circleID })?.ref
            else { return }
            let question = try await anna.sendMessage(String(localized: "Wer holt heute Brötchen? 🥐"), in: annasRef)
            let answer = try await ben.sendMessage(String(localized: "Ich! Bin eh unterwegs."), replyTo: question.id, in: bensRef)
            try await clara.sendMessage("👍", reactsTo: answer.id, in: clarasRef)
            try await clara.sendMessage("", image: SimulatedWorld.demoSticker(), isSticker: true, in: clarasRef)
        }
        // Anna helps run it.
        if let anna = simulation?.people.first {
            _ = await mapDetails(for: ref)
            await run { try await $0.setAdmin(anna.client.deviceID, true, in: ref) }
        }
        // Three evenings at the sports club, for the place suggestions.
        let (lat, lon) = SimulatedWorld.offset(home, north: -600, east: 900)
        for day in 1 ... 3 {
            let arrival = Date().addingTimeInterval(-Double(day) * 86400 - 3 * 3600)
            visitStore.add(Visit(latitude: lat, longitude: lon, arrival: arrival, departure: arrival.addingTimeInterval(5400)))
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
                return String(localized: "Bitte melde dich in den Einstellungen bei iCloud an. Leuchtturm speichert seine verschlüsselten Daten in deiner iCloud.")
            case .notFound: return String(localized: "Nicht gefunden. Vielleicht wurde der Leuchtturm gelöscht oder du wurdest entfernt.")
            case .permissionDenied: return String(localized: "Dafür fehlen dir die Rechte.")
            case .network: return String(localized: "Keine Verbindung zu iCloud. Bitte versuch es gleich noch einmal.")
            case .quotaExceeded: return String(localized: "Dein iCloud-Speicher ist voll.")
            case let .other(message): return String(localized: "iCloud-Fehler: \(message)")
            }
        case let error as ClientError:
            switch error {
            case .missingCircleKey: return String(localized: "Auf diesem Gerät fehlt noch der Schlüssel für den Leuchtturm. Der Besitzer muss die App einmal öffnen.")
            case .notOwner: return String(localized: "Das darf nur der Besitzer des Leuchtturms.")
            case .unknownMember: return String(localized: "Dieses Mitglied gibt es nicht.")
            case .invalidName: return String(localized: "Namen müssen 1 bis \(LeuchtturmClient.maxNameLength) Zeichen lang sein.")
            case .invalidDuration: return String(localized: "Ungültige Gültigkeitsdauer.")
            case .inviteInvalid: return String(localized: "Die Einladung ist ungültig oder wurde zurückgezogen.")
            case .inviteExpired: return String(localized: "Die Einladung ist abgelaufen. Bitte um eine neue.")
            case .untrustedCircle: return String(localized: "Dieses Gerät kann den Leuchtturm nicht prüfen, z. B. nach einer Neuinstallation. Lass dich neu einladen.")
            case .tampered: return String(localized: "Die Daten des Leuchtturms wurden verändert und sind nicht vom Besitzer signiert.")
            case .ownerMustDelete: return String(localized: "Als Besitzer kannst du den Leuchtturm nicht verlassen, nur löschen.")
            case .invalidNote: return String(localized: "Die Nachricht ist zu lang.")
            case .invalidPlace: return String(localized: "Bitte gib dem Ort einen Namen mit höchstens \(CirclePlace.maxNameLength) Zeichen.")
            case .notAdmin: return String(localized: "Das dürfen nur Admins.")
            case .invalidProfile: return String(localized: "Das Bild ist zu groß oder der Status zu lang.")
            case .takeoverNotAllowed: return String(localized: "Übernehmen geht erst, wenn der Besitzer drei Tage nicht aktiv war oder dir den Leuchtturm übergibt.")
            }
        case is ProtocolError:
            return String(localized: "Die Daten konnten nicht entschlüsselt oder geprüft werden.")
        default:
            return String(localized: "Unbekannter Fehler.")
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
