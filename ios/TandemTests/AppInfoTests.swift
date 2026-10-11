import Testing
@testable import Tandem

struct AppInfoTests {
    @Test func appNameIsTandem() {
        #expect(AppInfo.name == "Tandem")
    }

    @Test func defaultServerUsesHTTPS() {
        #expect(AppInfo.defaultServerURL.scheme == "https")
    }
}
