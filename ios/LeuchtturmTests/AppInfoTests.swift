import Foundation
import Testing
@testable import Leuchtturm

struct AppInfoTests {
    @Test func appNameIsLeuchtturm() {
        #expect(AppInfo.name == "Leuchtturm")
    }
}

struct ServerAddressTests {
    @Test func acceptsHostsAndHTTPS() {
        #expect(ServerAddress.parse("lt.example.org")?.absoluteString == "https://lt.example.org")
        #expect(ServerAddress.parse(" https://lt.example.org/ ")?.absoluteString == "https://lt.example.org")
        #expect(ServerAddress.parse("lt.example.org:8443")?.absoluteString == "https://lt.example.org:8443")
    }

    @Test func allowsHTTPOnlyForLocalAddresses() {
        #expect(ServerAddress.parse("http://192.168.1.20:8080") != nil)
        #expect(ServerAddress.parse("http://macbook.local:8080") != nil)
        #expect(ServerAddress.parse("http://localhost:8080") != nil)
        #expect(ServerAddress.parse("http://lt.example.org") == nil)
        #expect(ServerAddress.parse("http://8.8.8.8") == nil)
    }

    @Test func rejectsGarbage() {
        #expect(ServerAddress.parse("") == nil)
        #expect(ServerAddress.parse("ftp://lt.example.org") == nil)
        #expect(ServerAddress.parse("https://user:pw@lt.example.org") == nil)
        #expect(ServerAddress.parse("https://lt.example.org?x=1") == nil)
    }
}
