#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import Testing
@testable import LeuchtturmCore

struct SharedRideTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// A 10-minute drive east from `east0` meters, one point every 30 s,
    /// `north` meters off the line.
    func trip(_ device: String, north: Double = 0, minutes: Double = 10, offset: TimeInterval = 0,
              role: Trip.Role? = nil, reason: Trip.Reason? = nil, driverID: String? = nil) -> Trip {
        let points = (0 ... Int(minutes * 2)).map { i in
            HistoryDay.Point(
                latitude: 53.5 + north / 111_320,
                longitude: 9.9 + Double(i) * 400 / (111_320 * cos(53.5 * .pi / 180)),
                timestamp: start.addingTimeInterval(offset + Double(i) * 30)
            )
        }
        return Trip(
            id: CircleCrypto.newCircleID(), deviceID: device, start: start.addingTimeInterval(offset),
            end: start.addingTimeInterval(offset + minutes * 60), distance: minutes * 800, topSpeed: 14,
            hardBrakes: 0, rapidAccelerations: 0, route: points, role: role, reason: reason, driverID: driverID
        )
    }

    @Test func tripsInTheSameCarAreOneRide() {
        let anna = trip("anna"), ben = trip("ben", north: 20, offset: 20), clara = trip("clara", north: 3000)
        let later = trip("ben", offset: 3600)
        let rides = SharedRide.group([anna, ben, clara, later])
        #expect(rides.count == 3)
        let together = rides.first { $0.isShared }
        #expect(Set(together?.devices ?? []) == ["anna", "ben"])
        // Nobody knows who drove: both count until someone says.
        #expect(together?.driver == nil)
        #expect(together?.counted.count == 2)
    }

    @Test func carPlayMakesTheDriverLikely() throws {
        let ride = try #require(SharedRide.group([trip("anna"), trip("ben", role: .driver, reason: .carPlay)]).first)
        let driver = try #require(ride.driver)
        #expect(driver.deviceID == "ben" && driver.certainty == .likely && driver.reason == .carPlay)
        #expect(ride.counted.map(\.deviceID) == ["ben"])
    }

    @Test func answersBeatGuessesAndConflictsAsk() throws {
        let anna = CircleCrypto.newCircleID(), ben = CircleCrypto.newCircleID()
        // Ben's phone guessed (CarPlay), but Anna says she drove.
        let said = try #require(SharedRide.group([
            trip(anna, role: .driver, reason: .confirmed), trip(ben, role: .driver, reason: .carPlay),
        ]).first)
        #expect(said.driver?.deviceID == anna && said.driver?.certainty == .confirmed)
        // A passenger naming the driver counts as an answer.
        let named = try #require(SharedRide.group([trip(anna), trip(ben, role: .passenger, reason: .confirmed, driverID: anna)]).first)
        #expect(named.driver?.deviceID == anna && named.driver?.certainty == .confirmed)
        // Two say they drove: ask again.
        let conflict = try #require(SharedRide.group([
            trip(anna, role: .driver, reason: .confirmed), trip(ben, role: .driver, reason: .confirmed),
        ]).first)
        #expect(conflict.driver == nil)
        // Everyone else rode along.
        let rest = try #require(SharedRide.group([trip(anna), trip(ben, role: .passenger)]).first)
        #expect(rest.driver?.deviceID == anna && rest.driver?.certainty == .likely)
    }

    @Test func passengersDoNotCountForStatistics() {
        let stats = DriveStats.summarize([trip("me"), trip("me", offset: 3600, role: .passenger)], now: start.addingTimeInterval(7200))
        #expect(stats[.all]?.trips == 1)
    }

    @Test func roleAndGapsTravelEncrypted() throws {
        let key = SymmetricKey(size: .bits256)
        let device = CircleCrypto.newCircleID(), driver = CircleCrypto.newCircleID()
        var original = trip(device, role: .passenger, driverID: driver)
        original = Trip(
            id: original.id, deviceID: device, start: original.start, end: original.end, distance: original.distance,
            topSpeed: original.topSpeed, hardBrakes: 0, rapidAccelerations: 0, route: original.route, gaps: [3, 7],
            role: .passenger, reason: .confirmed, carName: "Golf", driverID: driver
        )
        let blob = try CircleCrypto.sealTrip(original, key: key, epoch: 1, circleID: "c")
        let opened = try #require(try CircleCrypto.openTrip(blob, id: original.id, deviceID: device, circleID: "c", keyForEpoch: { _ in key }))
        #expect(opened.gaps == [3, 7] && opened.role == .passenger && opened.reason == .confirmed)
        #expect(opened.carName == "Golf" && opened.driverID == driver && opened.route.count == original.route.count)
    }

    @Test func gapsAreMarkedAndKept() throws {
        var detector = TripDetector()
        var time = 0.0, north = 0.0
        func drive(_ seconds: Int, every step: Double = 1) {
            for _ in 0 ..< seconds {
                time += step
                north += 20 * step
                _ = detector.update(latitude: 53.5 + north / 111_320, longitude: 9.9, speed: 20, at: start.addingTimeInterval(time), deviceID: "me")
            }
        }
        drive(120)
        // A tunnel: nothing for two minutes, then 2.4 km further.
        drive(1, every: 120)
        drive(120)
        let ended = detector.update(latitude: 53.5 + north / 111_320, longitude: 9.9, speed: 0, at: start.addingTimeInterval(time + 600), deviceID: "me")
        let trip = try #require(ended)
        #expect(trip.gaps.count == 1)
        let gap = try #require(trip.gaps.first)
        #expect(trip.route[gap].timestamp.timeIntervalSince(trip.route[gap - 1].timestamp) >= 120)
    }
}
