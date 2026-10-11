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
        #expect(SharePolicy.foreground.shouldShare(fix(30, after: 20), after: last))
        #expect(SharePolicy.foreground.shouldShare(fix(0, after: 121), after: last))
    }

    @Test func backgroundSavesBattery() {
        let last = fix(0, after: 0)
        #expect(!SharePolicy.background.shouldShare(fix(50, after: 120), after: last))
        #expect(!SharePolicy.background.shouldShare(fix(500, after: 30), after: last))
        #expect(SharePolicy.background.shouldShare(fix(150, after: 90), after: last))
        #expect(SharePolicy.background.shouldShare(fix(0, after: 601), after: last))
    }
}
