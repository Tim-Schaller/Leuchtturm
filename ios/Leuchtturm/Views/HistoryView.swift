import CoreLocation
import CoreTransferable
import LeuchtturmCore
import MapKit
import SwiftUI
import UniformTypeIdentifiers

/// Your history as a GPX file for other map and sports apps.
struct GPXFile: Transferable {
    let days: [HistoryDay]

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: UTType(filenameExtension: "gpx") ?? .xml) { file in
            Data(HistoryDay.gpx(file.days, name: String(localized: "Mein Leuchtturm-Verlauf")).utf8)
        }
        .suggestedFileName("Leuchtturm-Verlauf.gpx")
    }
}

/// A member's path on one day, if they share their history.
struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.memberColors) private var memberColors
    let member: CircleMember
    let ref: CircleRef

    @State private var days: [HistoryDay]?
    @State private var selected = ""

    var body: some View {
        List {
            if let days {
                if let day = days.first(where: { $0.day == selected }) ?? days.first {
                    if days.count > 1 {
                        Picker("Tag", selection: $selected) {
                            ForEach(days) { Text(Self.label(for: $0.day)).tag($0.day) }
                        }
                    }
                    Section {
                        Map(initialPosition: .automatic) {
                            SpeedPathContent(path: SpeedPath(day.points))
                            if let first = day.points.first {
                                Annotation("Start", coordinate: first.coordinate) {
                                    Circle().fill(.white).stroke(color, lineWidth: 3).frame(width: 14, height: 14)
                                }
                            }
                            if let last = day.points.last {
                                Annotation("Zuletzt", coordinate: last.coordinate) {
                                    Avatar(name: member.name, id: member.id, size: 30)
                                }
                            }
                        }
                        .id(day.day)
                        .frame(height: 320)
                        .listRowInsets(EdgeInsets())
                        SpeedLegend()
                    }
                    Section {
                        LabeledContent("Strecke", value: Self.distance(day))
                        if let first = day.points.first, let last = day.points.last {
                            LabeledContent("Unterwegs") {
                                Text("\(first.timestamp, format: .dateTime.hour().minute()) – \(last.timestamp, format: .dateTime.hour().minute())")
                            }
                        }
                    } footer: {
                        Text("Ende-zu-Ende-verschlüsselt. Wie lange der Verlauf aufbewahrt wird, legt \(member.isMe ? "du" : member.name ?? "die Person") selbst fest.")
                    }
                    if member.isMe {
                        Section {
                            ShareLink(item: GPXFile(days: days), preview: SharePreview("Leuchtturm-Verlauf.gpx")) {
                                Label("Als GPX exportieren", systemImage: "square.and.arrow.up")
                            }
                        } footer: {
                            Text("Alle gespeicherten Tage als GPX-Datei, z. B. für Karten- und Sport-Apps. Die Datei ist nicht verschlüsselt.")
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "Kein Verlauf", systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                        description: Text(member.isMe
                            ? "Schalte „Verlauf teilen“ in den Einstellungen ein."
                            : "\(member.name ?? "Die Person") teilt keinen Verlauf.")
                    )
                    .listRowBackground(Color.clear)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Verlauf von \(member.isMe ? "dir" : member.name ?? "Mitglied")")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let id = member.id
            let ref = ref
            let loaded = await model.run { try await $0.history(of: id, in: ref) } ?? []
            days = loaded
            if selected.isEmpty { selected = loaded.first?.day ?? "" }
        }
    }

    private var color: Color { memberColors[member.id] ?? Theme.color(for: member.id) }

    static func label(for dayKey: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: dayKey) else { return dayKey }
        if dayKey == HistoryDay.dayKey(for: Date()) { return String(localized: "Heute") }
        if dayKey == HistoryDay.dayKey(for: Date().addingTimeInterval(-86400)) { return String(localized: "Gestern") }
        return date.formatted(.dateTime.weekday().day().month())
    }

    static func distance(_ day: HistoryDay) -> String {
        let meters = zip(day.points, day.points.dropFirst()).reduce(0.0) { sum, pair in
            sum + CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
                .distance(from: CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude))
        }
        return Measurement(value: meters, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road))
    }
}

extension HistoryDay.Point {
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
