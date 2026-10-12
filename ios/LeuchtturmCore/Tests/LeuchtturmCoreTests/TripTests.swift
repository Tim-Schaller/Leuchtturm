import Foundation
import Testing
@testable import LeuchtturmCore

struct TripTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// Drives north at the given speeds, one sample per second.
    func drive(_ detector: inout TripDetector, speeds: [Double], from offset: TimeInterval = 0, north: inout Double) -> [Trip] {
        var trips: [Trip] = []
        for (i, v) in speeds.enumerated() {
            north += v
            if let trip = detector.update(
                latitude: 53.5 + north / 111_320, longitude: 9.9, speed: v,
                at: start.addingTimeInterval(offset + Double(i)), deviceID: "me"
            ) { trips.append(trip) }
        }
        return trips
    }

    @Test func detectsADriveWithAHardBrake() throws {
        var detector = TripDetector()
        var north = 0.0
        let cruise = Array(repeating: 14.0, count: 150) // ~2 km at 50 km/h
        // 11 -> 14: rapid acceleration; 14 -> 8: hard brake; the rest is smooth.
        var speeds = [0, 3, 8, 11] + cruise + [14, 8, 6, 8, 10, 12, 14] + cruise
        speeds += [12, 10, 8, 6, 4, 2] + Array(repeating: 0, count: 10)
        #expect(drive(&detector, speeds: speeds, north: &north).isEmpty)
        #expect(detector.isDriving)

        // Parked: the next sample after the timeout ends the trip.
        let ended = detector.update(latitude: 53.5 + north / 111_320, longitude: 9.9, speed: 0, at: start.addingTimeInterval(600), deviceID: "me")
        let trip = try #require(ended)
        #expect(!detector.isDriving)
        #expect(trip.distance > 4000 && trip.distance < 4500)
        #expect(trip.hardBrakes == 1 && trip.rapidAccelerations == 1)
        #expect(trip.topSpeed == 14 && trip.score == 87)
        #expect(trip.route.count > 5 && trip.route.count <= Trip.maxRoutePoints)
    }

    @Test func routesKeepTheirCurves() throws {
        // 2 km north, a right turn, 2 km east: dense points while driving.
        var detector = TripDetector()
        var time = 0.0
        func sample(_ north: Double, _ east: Double) -> Trip? {
            time += 1
            return detector.update(
                latitude: 53.5 + north / 111_320, longitude: 9.9 + east / (111_320 * cos(53.5 * .pi / 180)), speed: 20,
                at: start.addingTimeInterval(time), deviceID: "me"
            )
        }
        for i in 0 ... 100 { _ = sample(Double(i) * 20, 0) }
        for i in 1 ... 100 { _ = sample(2000, Double(i) * 20) }
        let ended = detector.update(latitude: 53.5, longitude: 9.9, speed: 0, at: start.addingTimeInterval(time + 600), deviceID: "me")
        let trip = try #require(ended)
        // Every 20 m sample was kept (spacing 15 m) ...
        #expect(trip.route.count > 150 && trip.route.count <= Trip.maxRoutePoints)
        // ... and simplifying keeps the corner, not every n-th point.
        let simple = RouteShape.simplify(trip.route, maxCount: 3)
        #expect(simple.count == 3)
        #expect(abs(simple[1].latitude - (53.5 + 2000 / 111_320)) < 1e-6)
    }

    @Test func longTripsStayWithinTheLimit() throws {
        var detector = TripDetector()
        var north = 0.0
        // About an hour at 90 km/h with a gentle wiggle.
        var trips: [Trip] = []
        for i in 0 ..< 3600 {
            north += 25
            if let trip = detector.update(
                latitude: 53.5 + north / 111_320, longitude: 9.9 + sin(Double(i) / 60) * 0.01, speed: 25,
                at: start.addingTimeInterval(Double(i)), deviceID: "me"
            ) { trips.append(trip) }
        }
        let ended = detector.update(latitude: 53.5 + north / 111_320, longitude: 9.9, speed: 0, at: start.addingTimeInterval(4000), deviceID: "me")
        let trip = try #require(ended)
        #expect(trips.isEmpty)
        #expect(trip.route.count <= Trip.maxRoutePoints && trip.route.count > 100)
        #expect(trip.route.first.map { $0.timestamp.timeIntervalSince(start) <= 1 } == true)
    }

    @Test func suspectsACrashOnlyOnAnAbruptStop() {
        var detector = TripDetector()
        var north = 0.0
        _ = drive(&detector, speeds: [0, 8, 11] + Array(repeating: 14.0, count: 60) + [12, 9, 6, 3, 0], north: &north)
        #expect(detector.takeCrash() == nil) // normal stop
        _ = drive(&detector, speeds: [8, 11, 14, 14, 15, 0], from: 100, north: &north)
        #expect(detector.takeCrash() != nil)
        #expect(detector.takeCrash() == nil) // reported once
    }

    @Test func noTripWhenMotionSaysNotDriving() {
        var detector = TripDetector()
        var north = 0.0
        for (i, v) in Array(repeating: 9.0, count: 300).enumerated() { // 32 km/h on a bike or train
            north += v
            _ = detector.update(latitude: 53.5 + north / 111_320, longitude: 9.9, speed: v, at: start.addingTimeInterval(Double(i)), deviceID: "me", automotive: false)
        }
        #expect(!detector.isDriving)
        _ = detector.update(latitude: 53.6, longitude: 9.9, speed: 9, at: start.addingTimeInterval(400), deviceID: "me", automotive: true)
        _ = detector.update(latitude: 53.6001, longitude: 9.9, speed: 9, at: start.addingTimeInterval(401), deviceID: "me", automotive: true)
        #expect(detector.isDriving)
    }

    @Test func ignoresShortHopsAndWalking() {
        var detector = TripDetector()
        var north = 0.0
        #expect(drive(&detector, speeds: Array(repeating: 1.5, count: 600), north: &north).isEmpty)
        #expect(!detector.isDriving)
        _ = drive(&detector, speeds: Array(repeating: 10, count: 40), from: 700, north: &north) // 400 m
        #expect(detector.finishIfStale(now: start.addingTimeInterval(2000), deviceID: "me") == nil)
    }

    @Test func leaderboardRanksSafestFirst() {
        func trip(_ device: String, km: Double, brakes: Int) -> Trip {
            Trip(id: UUID().uuidString, deviceID: device, start: start, end: start + 600, distance: km * 1000,
                 topSpeed: 20, hardBrakes: brakes, rapidAccelerations: 0, route: [])
        }
        let board = DriverStats.leaderboard([
            trip("ben", km: 10, brakes: 0), trip("ben", km: 30, brakes: 2), trip("clara", km: 5, brakes: 0), trip("tim", km: 50, brakes: 0),
        ])
        #expect(board.map(\.deviceID) == ["tim", "clara", "ben"])
        #expect(board.last?.score == 88 && board.last?.trips == 2)
    }

    @Test func badgesAreEarned() {
        func trip(_ device: String, km: Double, brakes: Int = 0) -> Trip {
            Trip(id: UUID().uuidString, deviceID: device, start: start, end: start + 600, distance: km * 1000,
                 topSpeed: 20, hardBrakes: brakes, rapidAccelerations: 0, route: [])
        }
        let trips = [trip("ben", km: 40), trip("ben", km: 40), trip("ben", km: 30), trip("clara", km: 5, brakes: 1)]
        let badges = Badge.earned(trips: trips, distances: ["anna": 12_000, "clara": 3_000])
        #expect(Set(badges.map(\.id)) == ["ben/smoothDriver", "ben/roadTripper", "anna/explorer"])
    }

    @Test func speedTravelsWithTheLocation() throws {
        let fast = try #require(SharedLocation(latitude: 53.5, longitude: 9.9, accuracy: 5, timestamp: start, speed: 13.94))
        let key = CircleCrypto.newCircleKey()
        let blob = try CircleCrypto.sealLocation(fast, key: key, epoch: 1, circleID: "c", deviceID: "d")
        let opened = try #require(try CircleCrypto.openLocation(blob, circleID: "c", deviceID: "d", keyForEpoch: { _ in key }))
        #expect(opened.location.speed == 13.9)
        #expect(SharedLocation(latitude: 0, longitude: 0, accuracy: 5, timestamp: start, speed: 400) == nil)
        var walker = try #require(SharedLocation(latitude: 53.5, longitude: 9.9, accuracy: 5, timestamp: start))
        walker.steps = 8421
        walker.weekSteps = 61_000
        let walkerBlob = try CircleCrypto.sealLocation(walker, key: key, epoch: 1, circleID: "c", deviceID: "d")
        let back = try #require(try CircleCrypto.openLocation(walkerBlob, circleID: "c", deviceID: "d", keyForEpoch: { _ in key }))
        #expect(back.location.steps == 8421 && back.location.weekSteps == 61_000)
        #expect(walker.inFog(radius: 1000)?.steps == 8421)
    }
}

struct DriveStatsTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func trip(daysAgo: Double, km: Double, top: Double = 20, brakes: Int = 0) -> Trip {
        let end = now.addingTimeInterval(-daysAgo * 86400)
        return Trip(id: UUID().uuidString, deviceID: "ben", start: end - 600, end: end, distance: km * 1000,
                    topSpeed: top, hardBrakes: brakes, rapidAccelerations: 0, route: [])
    }

    @Test func periodsCountOnlyTheirTrips() {
        let trips = [trip(daysAgo: 1, km: 10, top: 30), trip(daysAgo: 20, km: 20, brakes: 2), trip(daysAgo: 200, km: 30, top: 40), trip(daysAgo: 800, km: 40)]
        let stats = DriveStats.summarize(trips, now: now)
        #expect(stats[.week]?.trips == 1 && stats[.week]?.distance == 10_000 && stats[.week]?.topSpeed == 30)
        #expect(stats[.month]?.trips == 2 && stats[.month]?.hardBrakes == 2)
        #expect(stats[.year]?.trips == 3 && stats[.year]?.topSpeed == 40)
        #expect(stats[.all]?.trips == 4 && stats[.all]?.distance == 100_000)
        #expect(stats[.week]?.score == 100)
        #expect(DriveStats([]).score == nil)
    }

    @Test func statsTravelInTheEncryptedProfile() throws {
        let stats = DriveStats.summarize([trip(daysAgo: 1, km: 12, top: 33)], now: now)
        let profile = Profile(color: "#2F8F5B", driving: stats)
        let key = CircleCrypto.newCircleKey()
        let sealed = try CircleCrypto.sealProfile(profile, key: key, epoch: 1, circleID: "c", deviceID: "d")
        let opened = try #require(try CircleCrypto.openProfile(sealed, circleID: "c", deviceID: "d") { $0 == 1 ? key : nil })
        #expect(opened.driving == stats)
        var forged = profile
        forged.driving?[.all]?.topSpeed = 900 // 3240 km/h
        #expect(!forged.isValid)
    }
}
