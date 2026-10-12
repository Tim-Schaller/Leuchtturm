import LeuchtturmCore
import SwiftUI

/// A person's driving totals with a period picker, on their page.
struct DriveStatsSection: View {
    @Environment(AppModel.self) private var model
    let member: CircleMember
    @AppStorage("driveStatsPeriod") private var period = DriveStats.Period.month

    private var stats: [DriveStats.Period: DriveStats]? {
        if member.isMe { return model.tripArchive.trips.isEmpty ? nil : model.tripArchive.stats }
        return member.profile?.driving
    }

    var body: some View {
        Section {
            if let stats {
                Picker("Zeitraum", selection: $period) {
                    Text("7 Tage").tag(DriveStats.Period.week)
                    Text("30 Tage").tag(DriveStats.Period.month)
                    Text("1 Jahr").tag(DriveStats.Period.year)
                    Text("Gesamt").tag(DriveStats.Period.all)
                }
                .pickerStyle(.segmented)
                .listRowSeparator(.hidden)
                let current = stats[period] ?? .empty
                if current.trips == 0 {
                    Text("Keine Fahrten in diesem Zeitraum.").foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        StatTile(value: "\(current.trips)", label: "Fahrten", symbol: "car.fill")
                        StatTile(value: WeekView.km(current.distance), label: "Strecke", symbol: "road.lanes")
                        StatTile(value: Duration.seconds(current.duration).formatted(.units(allowed: [.hours, .minutes], width: .narrow)),
                                 label: "Fahrzeit", symbol: "clock")
                        StatTile(value: Theme.speed(current.topSpeed), label: "Höchsttempo", symbol: "gauge.with.dots.needle.67percent")
                        StatTile(value: "\(current.hardBrakes)", label: "Starkes Bremsen", symbol: "exclamationmark.octagon")
                        StatTile(value: "\(current.rapidAccelerations)", label: "Schnelles Beschleunigen", symbol: "bolt.car")
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 8, trailing: 12))
                    if let score = current.score {
                        LabeledContent("Fahrwertung") { ScoreBadge(score: score) }
                    }
                }
            } else {
                Text(member.isMe
                    ? "Noch keine Fahrten. Ab 25 km/h erkennt dein iPhone Fahrten, wenn „Fahrten teilen“ oder die Unfallerkennung an ist."
                    : "\(member.name ?? String(localized: "Diese Person")) teilt keine Fahrten.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Fahrstatistik")
        } footer: {
            if member.isMe {
                Text(model.sharesTrips
                    ? "Deine Leuchttürme sehen diese Summen, Ende-zu-Ende-verschlüsselt. Die einzelnen Fahrten bleiben nur 30 Tage in iCloud, die Summen rechnet dein iPhone aus seinem eigenen Archiv."
                    : "Nur auf diesem iPhone. Schalte „Fahrten teilen“ ein, damit deine Leuchttürme die Summen sehen.")
            }
        }
    }
}

private struct StatTile: View {
    let value: String
    let label: LocalizedStringResource
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: symbol).foregroundStyle(.tint)
            Text(value).font(.title3.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }
}
