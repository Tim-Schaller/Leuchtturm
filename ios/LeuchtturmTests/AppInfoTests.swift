import Foundation
import Testing
@testable import Leuchtturm

struct AppInfoTests {
    @Test func appNameIsLeuchtturm() {
        #expect(AppInfo.name == "Leuchtturm")
    }

    @Test func cloudKitContainerMatchesBundleID() {
        #expect(AppInfo.cloudKitContainer == "iCloud." + (Bundle.main.bundleIdentifier ?? "de.timschaller.leuchtturm"))
    }
}
