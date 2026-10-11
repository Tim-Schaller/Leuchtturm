import CoreLocation
import LeuchtturmCore
import MapKit
import SwiftUI

/// The last 7 days of the circle: who drove safest, who was out and about
/// most, and the trips. Only members who share trips or history appear.
struct WeekView: View {
    @Environment(AppModel.self) private var model
    let details: CircleDetails

    @State private var trips: [Trip]?
    @State private var walkers: [(member: CircleMember, meters: Double)] = []

    var body: some View {
        List {
            if let trips {
                let board = DriverStats.leaderboard(trips)
                Section {
                    if board.isEmpty {
                        Text("Noch keine geteilten Fahrten diese Woche.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(board.enumerated()), id: \.element.id) { rank, stats in
                        HStack(spacing: 12) {
                            Text(Self.medal(rank)).font(.title2).frame(width: 34)
                            Avatar(name: member(stats.deviceID)?.name, id: stats.deviceID, size: 38)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(member(stats.deviceID)?.name ?? String(localized: "Mitglied")).font(.headline)
                                Text("\(stats.trips) Fahrten · \(Self.km(stats.distance)) · \(stats.hardBrakes)× stark gebremst")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            ScoreBadge(score: stats.score)
                        }
                    }
                } header: {
                    Text("🏆 Sicher gefahren")
                } footer: {
                    Text("100 Punkte pro Fahrt, Abzug für starkes Bremsen, schnelles Beschleunigen und über 130 km/h. Nach Strecke gewichtet. Nur wer „Fahrten teilen“ eingeschaltet hat.")
                }

                let badges = Badge.earned(
                    trips: trips, distances: Dictionary(walkers.map { ($0.member.id, $0.meters) }, uniquingKeysWith: max)
                )
                if !badges.isEmpty {
                    Section("Abzeichen der Woche") {
                        ForEach(badges) { badge in
                            HStack(spacing: 12) {
                                Text(Self.badgeEmoji(badge.kind)).font(.title2).frame(width: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(Self.badgeTitle(badge.kind)).font(.headline)
                                    Text(member(badge.deviceID)?.isMe == true ? String(localized: "Du") : member(badge.deviceID)?.name ?? "")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Avatar(name: member(badge.deviceID)?.name, id: badge.deviceID, size: 30)
                            }
                        }
                    }
                }

                if !walkers.isEmpty {
                    Section {
                        ForEach(Array(walkers.enumerated()), id: \.element.member.id) { rank, entry in
                            HStack(spacing: 12) {
                                Text(Self.medal(rank)).font(.title2).frame(width: 34)
                                Avatar(name: entry.member.name, id: entry.member.id, size: 38)
                                Text(entry.member.isMe ? String(localized: "Du") : entry.member.name ?? String(localized: "Mitglied"))
                                    .font(.headline)
                                Spacer()
                                Text(Self.km(entry.meters)).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text("👟 Am meisten unterwegs")
                    } footer: {
                        Text("Strecke aus dem geteilten Verlauf, auch zu Fuß und mit dem Rad.")
                    }
                }

                if !trips.isEmpty {
                    Section("Fahrten") {
                        ForEach(trips) { trip in
                            NavigationLink(value: DrawerRoute.trip(trip)) {
                                HStack(spacing: 12) {
                                    Avatar(name: member(trip.deviceID)?.name, id: trip.deviceID, size: 32)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(Self.km(trip.distance)) · \(Self.minutes(trip.duration))")
                                            .font(.subheadline.weight(.semibold))
                                        Text(trip.start, format: .dateTime.weekday(.wide).hour().minute())
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    ScoreBadge(score: trip.score)
                                }
                            }
                        }
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Diese Woche")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func member(_ id: String) -> CircleMember? {
        details.members.first { $0.id == id }
    }

    private func load() async {
        let ref = details.ref
        let since = Date().addingTimeInterval(-7 * 86400)
        trips = await model.run { try await $0.trips(in: ref, since: since) } ?? []
        var entries: [(CircleMember, Double)] = []
        for member in details.members where !member.isPending {
            let id = member.id
            let days = await model.run { try await $0.history(of: id, in: ref) } ?? []
            let meters = days.filter { $0.day >= HistoryDay.dayKey(for: since) }
                .reduce(0.0) { $0 + Self.length($1.points) }
            if meters > 0 { entries.append((member, meters)) }
        }
        walkers = entries.sorted { $0.1 > $1.1 }.map { (member: $0.0, meters: $0.1) }
    }

    static func badgeEmoji(_ kind: Badge.Kind) -> String {
        switch kind {
        case .smoothDriver: "🛡️"
        case .roadTripper: "🛣️"
        case .explorer: "🧭"
        }
    }

    static func badgeTitle(_ kind: Badge.Kind) -> String {
        switch kind {
        case .smoothDriver: String(localized: "Sicher unterwegs: 3 Fahrten mit 100 Punkten")
        case .roadTripper: String(localized: "Weite Wege: über 100 km gefahren")
        case .explorer: String(localized: "Entdecker: über 10 km unterwegs")
        }
    }

    static func medal(_ rank: Int) -> String {
        ["🥇", "🥈", "🥉"].indices.contains(rank) ? ["🥇", "🥈", "🥉"][rank] : "\(rank + 1)."
    }

    static func km(_ meters: Double) -> String {
        Measurement(value: meters, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road))
    }

    static func minutes(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    static func length(_ points: [HistoryDay.Point]) -> Double {
        zip(points, points.dropFirst()).reduce(0.0) { sum, pair in
            sum + CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
                .distance(from: CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude))
        }
    }
}

/// A trip's score as a colored pill: green, yellow or red.
struct ScoreBadge: View {
    let score: Int

    var body: some View {
        Text("\(score)")
            .font(.subheadline.bold().monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.gradient, in: .capsule)
            .accessibilityLabel("\(score) von 100 Punkten")
    }

    private var color: Color {
        switch score {
        case 85...: Color.accentColor
        case 65...: .orange
        default: .red
        }
    }
}

/// One trip: the route and how it went.
struct TripView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let trip: Trip
    let member: CircleMember?

    var body: some View {
        List {
            Section {
                Map(initialPosition: .automatic) {
                    MapPolyline(coordinates: trip.route.map(\.coordinate))
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                    if let first = trip.route.first {
                        Annotation("Start", coordinate: first.coordinate) {
                            Circle().fill(.white).stroke(Color.accentColor, lineWidth: 3).frame(width: 14, height: 14)
                        }
                    }
                    if let last = trip.route.last {
                        Annotation("Ziel", coordinate: last.coordinate) {
                            Image(systemName: "flag.checkered.circle.fill").font(.title2).foregroundStyle(Color.accentColor)
                        }
                    }
                }
                .frame(height: 300)
                .listRowInsets(EdgeInsets())
            }
            Section {
                LabeledContent("Punkte") { ScoreBadge(score: trip.score) }
                LabeledContent("Strecke", value: WeekView.km(trip.distance))
                LabeledContent("Dauer", value: WeekView.minutes(trip.duration))
                LabeledContent("Höchsttempo", value: "\(Int((trip.topSpeed * 3.6).rounded())) km/h")
                LabeledContent("Stark gebremst", value: "\(trip.hardBrakes)×")
                LabeledContent("Schnell beschleunigt", value: "\(trip.rapidAccelerations)×")
            } footer: {
                Text("Erkannt auf dem iPhone von \(member?.name ?? "diesem Mitglied"). Ende-zu-Ende-verschlüsselt.")
            }
            if member?.isMe == true {
                Section {
                    Button("Ich bin nur mitgefahren", systemImage: "person.2.badge.minus", role: .destructive) {
                        let id = trip.id
                        Task {
                            if await model.run({ try await $0.deleteTrip(id) }) != nil { dismiss() }
                        }
                    }
                } footer: {
                    Text("Entfernt die Fahrt für alle, sie zählt dann nicht für deine Punkte.")
                }
            }
        }
        .navigationTitle(trip.start.formatted(.dateTime.weekday(.wide).hour().minute()))
        .navigationBarTitleDisplayMode(.inline)
    }
}
