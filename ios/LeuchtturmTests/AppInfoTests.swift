import Testing
@testable import Leuchtturm

struct AppInfoTests {
    @Test func appNameIsLeuchtturm() {
        #expect(AppInfo.name == "Leuchtturm")
    }

    @Test func defaultServerUsesHTTPS() {
        #expect(AppInfo.defaultServerURL.scheme == "https")
    }
}
