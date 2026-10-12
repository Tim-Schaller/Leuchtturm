import Foundation

/// What the widgets, the Live Activity and Siri show, written by the app
/// into the shared App Group container. Plain JSON, protected like the
/// keys (readable after first unlock); nothing here goes to iCloud.
struct WidgetSnapshot: Codable, Sendable {
    struct Person: Codable, Sendable, Identifiable {
        var id: String
        var name: String
        var initials: String
        var colorHex: String
        var emoji: String?
        var status: String?
        /// "zu Hause", "Café am See" or "vor 5 Min." – already localized.
        var place: String
        var battery: Int?
        var updated: Date?
        /// 64 px JPEG.
        var photo: Data?
    }

    var circleName: String
    var people: [Person]
    var written: Date

    static let appGroup = "group.de.timschaller.leuchtturm"

    static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?.appending(path: "snapshot.json")
    }

    static func load() -> WidgetSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    func save() {
        guard let url = Self.fileURL, let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static let preview = WidgetSnapshot(circleName: "Familie", people: [
        Person(id: "a", name: "Anna", initials: "A", colorHex: "#D9567F", status: "☕️ Kaffeepause", place: "Café am See", battery: 82, updated: Date()),
        Person(id: "b", name: "Ben", initials: "B", colorHex: "#E0533A", emoji: "🏎️", place: "unterwegs · 57 km/h", battery: 34, updated: Date()),
        Person(id: "c", name: "Clara", initials: "C", colorHex: "#9576C9", status: "📚 in der Schule", place: "Schule", battery: 9, updated: Date()),
    ], written: Date())
}
