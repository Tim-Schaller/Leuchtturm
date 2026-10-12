import Foundation

enum AppInfo {
    static let name = "Leuchtturm"
    /// CloudKit container. Must match the app's iCloud entitlement.
    static let cloudKitContainer = "iCloud.de.timschaller.leuchtturm"
    /// The page that opens live links (docs/live in the repository).
    static let liveLinkPage = URL(string: "https://tim-schaller.github.io/Leuchtturm/live/")!
}
