import CoreLocation
import Foundation
import Testing
@testable import Leuchtturm

struct SharePolicyTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// A position `meters` north of a fixed point, `seconds` after `start`.
    func fix(_ meters: Double, after seconds: TimeInterval) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 53.55 + meters / 111_320, longitude: 9.99),
            altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10,
            timestamp: start.addingTimeInterval(seconds)
        )
    }

    @Test func firstPositionIsAlwaysShared() {
        #expect(SharePolicy.background.shouldShare(fix(0, after: 0), after: nil))
    }

    @Test func foregroundSharesMovementQuicklyButNotEverySecond() {
        let last = fix(0, after: 0)
        #expect(!SharePolicy.foreground.shouldShare(fix(10, after: 30), after: last))
        #expect(!SharePolicy.foreground.shouldShare(fix(200, after: 5), after: last))
        #expect(SharePolicy.foreground.shouldShare(fix(20, after: 10), after: last))
        #expect(SharePolicy.foreground.shouldShare(fix(0, after: 61), after: last))
    }

    @Test func drivingSharesEveryTenSeconds() {
        let last = fix(0, after: 0)
        #expect(!SharePolicy.driving.shouldShare(fix(150, after: 5), after: last))
        #expect(SharePolicy.driving.shouldShare(fix(140, after: 10), after: last))
        #expect(SharePolicy.driving.shouldShare(fix(0, after: 31), after: last))
    }

    @Test func backgroundSavesBattery() {
        let last = fix(0, after: 0)
        #expect(!SharePolicy.background.shouldShare(fix(40, after: 120), after: last))
        #expect(!SharePolicy.background.shouldShare(fix(500, after: 20), after: last))
        #expect(SharePolicy.background.shouldShare(fix(150, after: 40), after: last))
        #expect(SharePolicy.background.shouldShare(fix(0, after: 301), after: last))
    }
}

struct ThemeTests {
    @Test func everyoneInACircleGetsTheirOwnColor() {
        let ids = (0 ..< 8).map { "device-\($0)" }
        let colors = Theme.colors(for: ids)
        #expect(Set(ids.compactMap { colors[$0] }.map { "\($0)" }).count == 8)
        #expect(Theme.colors(for: ids.reversed()) == colors)
    }
}
