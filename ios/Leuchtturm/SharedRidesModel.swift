import AVFoundation
import Foundation
import LeuchtturmCore
import UserNotifications

/// What the phone's audio is connected to: CarPlay, or a Bluetooth device
/// such as a car („Golf“) or headphones. Read while driving, on the device.
enum CarAudio {
    struct Reading {
        var carPlay: Bool
        var bluetooth: String?
    }

    static func now() -> Reading {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        let bluetooth = outputs.first { [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE].contains($0.portType) }?.portName
        return Reading(carPlay: outputs.contains { $0.portType == .carAudio }, bluetooth: bluetooth)
    }
}

/// Readings during one trip.
struct CarSamples {
    var total = 0
    var carPlay = 0
    var bluetooth: [String: Int] = [:]

    mutating func add(_ reading: CarAudio.Reading) {
        total += 1
        if reading.carPlay { carPlay += 1 }
        if let name = reading.bluetooth { bluetooth[name, default: 0] += 1 }
    }

    /// CarPlay for at least a third of the trip.
    var usedCarPlay: Bool { carPlay > 0 && carPlay * 3 >= total }
    /// The Bluetooth device connected for most of the trip.
    var mainBluetooth: String? {
        bluetooth.max { $0.value < $1.value }.flatMap { $0.value * 2 >= total ? $0.key : nil }
    }
}

/// Shared rides: who drove. The driver's phone guesses from CarPlay or one
/// of „Meine Autos“; when it stays unclear, each phone asks once.
extension AppModel {
    private static let myCarsKey = "myCars"
    private static let tripCarsKey = "tripCars"
    private static let askedRidesKey = "askedRides"
    static let rideCategory = "ride"
    static let rideDriver = "ride-driver"
    static let ridePassenger = "ride-passenger"

    func restoreRides() {
        // Not in the simulation or in tests.
        guard usesDeviceServices, !isSimulation else { return }
        let defaults = UserDefaults.standard
        myCars = defaults.stringArray(forKey: Self.myCarsKey) ?? []
        // Cars of trips from the last 30 days; older answers are not asked anymore.
        let recent = Set(tripArchive.trips.filter { $0.end > Date().addingTimeInterval(-30 * 86400) }.map(\.id))
        tripCars = (defaults.dictionary(forKey: Self.tripCarsKey) as? [String: String] ?? [:]).filter { recent.contains($0.key) }
        askedRides = Set(defaults.stringArray(forKey: Self.askedRidesKey) ?? [])
    }

    private func saveRides() {
        // Not in the simulation or in tests.
        guard usesDeviceServices, !isSimulation else { return }
        let defaults = UserDefaults.standard
        defaults.set(myCars, forKey: Self.myCarsKey)
        // Only recent trips need their car.
        defaults.set(tripCars, forKey: Self.tripCarsKey)
        defaults.set(Array(askedRides.suffix(200)), forKey: Self.askedRidesKey)
    }

    func clearRides() {
        (myCars, tripCars, askedRides, rideOthers) = ([], [:], [], [:])
        saveRides()
    }

    func removeCar(_ name: String) {
        myCars.removeAll { $0 == name }
        saveRides()
    }

    /// While driving: what the phone is connected to, every 10 seconds.
    func sampleCarAudio(newTrip: Bool) {
        guard usesDeviceServices, !isSimulation else { return }
        if newTrip { carSamples = CarSamples() }
        guard Date().timeIntervalSince(lastCarSample) >= 10 else { return }
        lastCarSample = Date()
        carSamples.add(CarAudio.now())
    }

    /// The finished trip's guess: CarPlay or a known car means this phone drove.
    func guessDriver(_ trip: Trip) -> Trip {
        var trip = trip
        defer { carSamples = CarSamples() }
        if let car = carSamples.mainBluetooth {
            tripCars[trip.id] = car
            saveRides()
        }
        if carSamples.usedCarPlay {
            (trip.role, trip.reason) = (.driver, .carPlay)
        } else if let car = carSamples.mainBluetooth, myCars.contains(car) {
            (trip.role, trip.reason, trip.carName) = (.driver, .bluetooth, car)
        }
        return trip
    }

    /// Looks at own trips of the last day: takes over a clear driver, and
    /// asks once when a shared ride is unclear. At most every two minutes.
    func checkSharedRides(force: Bool = false) async {
        guard sharesTrips, let client, force || Date().timeIntervalSince(lastRideCheck) > 120 else { return }
        let since = Date().addingTimeInterval(-86400)
        guard tripArchive.trips.contains(where: { $0.end > since }) else { return }
        lastRideCheck = Date()
        let me = client.deviceID
        for ride in SharedRide.group(await recentTrips(since: since)) where ride.isShared {
            guard let mine = ride.trips.first(where: { $0.deviceID == me }), mine.reason != .confirmed else { continue }
            rideOthers[mine.id] = ride.devices.filter { $0 != me }
            if let driver = ride.driver, driver.deviceID != me {
                // Someone else drove (CarPlay, their car or an answer): ride along quietly.
                guard !(mine.isPassenger && mine.driverID == driver.deviceID) else { continue }
                var trip = mine
                (trip.role, trip.reason, trip.driverID, trip.carName) = (.passenger, nil, driver.deviceID, nil)
                await store(trip)
            } else if ride.driver == nil, !askedRides.contains(mine.id) {
                askedRides.insert(mine.id)
                saveRides()
                if usesDeviceServices { ask(about: ride, mine: mine) }
            }
        }
    }

    /// My answer: `driverID` is this device, someone else, or nil (not me, unknown who).
    func answerRide(tripID: String, driverID: String?) async {
        guard let client, var trip = await recentTrips(since: Date().addingTimeInterval(-30 * 86400)).first(where: {
            $0.id == tripID && $0.deviceID == client.deviceID
        }) else { return }
        if driverID == client.deviceID {
            (trip.role, trip.reason, trip.driverID) = (.driver, .confirmed, nil)
            // This car is mine from now on.
            if let car = tripCars[trip.id] {
                trip.carName = car
                if !myCars.contains(car) { myCars.append(car) }
            }
        } else {
            (trip.role, trip.reason, trip.driverID, trip.carName) = (.passenger, .confirmed, driverID, nil)
        }
        askedRides.insert(trip.id)
        saveRides()
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["ride-\(trip.id)"])
        await store(trip)
        noteRemoteChange()
    }

    /// The answer from the notification.
    func answerRideFromNotification(_ action: String, requestID: String) {
        guard requestID.hasPrefix("ride-"), let me = client?.deviceID else { return }
        let tripID = String(requestID.dropFirst("ride-".count))
        let others = rideOthers[tripID] ?? []
        let driver = action == Self.rideDriver ? me : (others.count == 1 ? others.first : nil)
        Task { await answerRide(tripID: tripID, driverID: driver) }
    }

    private func store(_ trip: Trip) async {
        tripArchive.update(trip)
        await run { try await $0.shareTrip(trip) }
        await publishDrivingStats()
    }

    /// Trips in all circles since `since`, each once.
    private func recentTrips(since: Date) async -> [Trip] {
        guard let client else { return [] }
        var byID: [String: Trip] = [:]
        for circle in circles {
            for trip in (try? await client.trips(in: circle.ref, since: since)) ?? [] { byID[trip.id] = trip }
        }
        return Array(byID.values)
    }

    private func ask(about ride: SharedRide, mine: Trip) {
        let names = ride.devices.filter { $0 != mine.deviceID }.map { name(of: $0) }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Gemeinsame Fahrt mit \(names.formatted(.list(type: .and)))")
        content.body = String(localized: "Wer ist gefahren? Deine Antwort zählt für die Bestenliste.")
        content.categoryIdentifier = Self.rideCategory
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "ride-\(mine.id)", content: content, trigger: nil))
    }

    /// A member's name from any circle.
    func name(of deviceID: String) -> String {
        latestDetails.values.lazy.flatMap(\.members).first { $0.id == deviceID }?.name ?? String(localized: "Jemand")
    }
}
