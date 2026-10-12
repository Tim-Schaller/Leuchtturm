import CoreLocation
import LeuchtturmCore
import MapKit
import SwiftUI

/// The last 7 days of the circle: who drove safest, who was out and about
/// most, and the trips. Only members who share trips or history appear.
struct WeekView: View {
    enum Mode {
        case ranking
        case trips
    }

    @Environment(AppModel.self) private var model
    let details: CircleDetails
    var mode = Mode.ranking

    @State private var trips: [Trip]?
    @State private var walkers: [(member: CircleMember, meters: Double)] = []

    var body: some View {
        List {
            if let trips, mode == .trips {
                Section {
                    if trips.isEmpty {
                        Text("Noch keine geteilten Fahrten diese Woche.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(SharedRide.group(trips)) { ride in
                        NavigationLink(value: DrawerRoute.ride(ride)) {
                            RideRow(ride: ride, members: details.members)
                        }
                    }
                } header: {
                    Text("Fahrten der letzten 7 Tage")
                } footer: {
                    Text("Nur von Leuten, die „Fahrten teilen“ eingeschaltet haben.")
                }
            } else if let all = trips {
                // A car of four counts once: only the driver's trip.
                let trips = SharedRide.counted(all)
                let board = DriverStats.leaderboard(trips)
                Section {
                    if board.isEmpty {
                        Text("Noch keine geteilten Fahrten diese Woche.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(board.enumerated()), id: \.element.id) { rank, stats in
                        HStack(spacing: 12) {
                            Text(Self.medal(rank)).font(.title2).frame(width: 34)
                                .accessibilityLabel("Platz \(rank + 1)")
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
                        .accessibilityElement(children: .combine)
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

                ChallengesSection(details: details, trips: trips, walkers: walkers)

                if !walkers.isEmpty {
                    Section {
                        ForEach(Array(walkers.enumerated()), id: \.element.member.id) { rank, entry in
                            HStack(spacing: 12) {
                                Text(Self.medal(rank)).font(.title2).frame(width: 34)
                                .accessibilityLabel("Platz \(rank + 1)")
                                Avatar(name: entry.member.name, id: entry.member.id, size: 38)
                                Text(entry.member.isMe ? String(localized: "Du") : entry.member.name ?? String(localized: "Mitglied"))
                                    .font(.headline)
                                Spacer()
                                Text(Self.km(entry.meters)).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    } header: {
                        Text("👟 Am meisten unterwegs")
                    } footer: {
                        Text("Strecke aus dem geteilten Verlauf, auch zu Fuß und mit dem Rad.")
                    }
                }

            } else {
                ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
            }
        }
        .contentMargins(.top, 0, for: .scrollContent)
        .task(id: "\(details.id)|\(model.externalChanges)") { await load() }
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

/// A trip in the list: one person, or a shared ride with everyone in it.
struct RideRow: View {
    @Environment(AppModel.self) private var model
    let ride: SharedRide
    let members: [CircleMember]

    var body: some View {
        let main = ride.mainTrip
        HStack(spacing: 12) {
            ZStack(alignment: .leading) {
                ForEach(Array(ride.devices.prefix(3).enumerated()), id: \.offset) { index, id in
                    Avatar(name: name(id), id: id, size: 32)
                        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                        .offset(x: CGFloat(index) * 14)
                }
            }
            .frame(width: 32 + CGFloat(min(ride.devices.count, 3) - 1) * 14, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(WeekView.km(main.distance)) · \(WeekView.minutes(main.duration))")
                    .font(.subheadline.weight(.semibold))
                Text(ride.isShared ? RideText.driverLine(ride, name: name) : RideText.single(main, name: name(main.deviceID)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(main.start.formatted(.dateTime.weekday(.wide).hour().minute()))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            ScoreBadge(score: main.score)
        }
    }

    private func name(_ id: String) -> String {
        members.first { $0.id == id }.map { $0.isMe ? String(localized: "Du") : $0.name ?? String(localized: "Mitglied") } ?? model.name(of: id)
    }
}

/// How a ride's driver reads.
enum RideText {
    static func driverLine(_ ride: SharedRide, name: (String) -> String) -> String {
        let together = String(localized: "Gemeinsame Fahrt")
        guard let driver = ride.driver else { return together + " · " + String(localized: "Wer ist gefahren?") }
        let who = name(driver.deviceID)
        switch (driver.certainty, driver.reason) {
        case (.confirmed, _): return together + " · " + String(localized: "\(who) ist gefahren")
        case (_, .carPlay?): return together + " · " + String(localized: "\(who) ist vermutlich gefahren · CarPlay")
        case (_, .bluetooth?): return together + " · " + String(localized: "\(who) ist vermutlich gefahren · mit „\(driver.carName ?? "")“ verbunden")
        default: return together + " · " + String(localized: "\(who) ist vermutlich gefahren")
        }
    }

    static func single(_ trip: Trip, name: String) -> String {
        trip.isPassenger ? String(localized: "\(name) · mitgefahren") : name
    }
}

extension SharedRide {
    /// The trip to show: the driver's, else the one with the most points.
    var mainTrip: Trip {
        if let driver, let trip = trips.first(where: { $0.deviceID == driver.deviceID }) { return trip }
        return trips.max { $0.route.count < $1.route.count } ?? trips[0]
    }
}

/// One trip or shared ride: the route, how it went, and who drove.
struct TripView: View {
    @Environment(AppModel.self) private var model
    let ride: SharedRide
    let members: [CircleMember]
    /// The answer given here, until the ride reloads.
    @State private var answered: String??

    private var trip: Trip { ride.mainTrip }
    private var me: String? { model.client?.deviceID }
    private var mine: Trip? { ride.trips.first { $0.deviceID == me } }

    var body: some View {
        List {
            Section {
                Map(initialPosition: .automatic) {
                    SpeedPathContent(path: SpeedPath(trip.route, gaps: trip.gaps))
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
                SpeedLegend()
                if !trip.gaps.isEmpty {
                    Label("Gestrichelt: keine Daten, z. B. im Tunnel", systemImage: "line.diagonal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if ride.isShared || mine != nil {
                driverSection
            }
            Section {
                LabeledContent("Punkte") { ScoreBadge(score: trip.score) }
                LabeledContent("Strecke", value: WeekView.km(trip.distance))
                LabeledContent("Dauer", value: WeekView.minutes(trip.duration))
                LabeledContent("Höchsttempo", value: Theme.speed(trip.topSpeed))
                LabeledContent("Stark gebremst", value: "\(trip.hardBrakes)×")
                LabeledContent("Schnell beschleunigt", value: "\(trip.rapidAccelerations)×")
            } footer: {
                Text("Erkannt auf dem iPhone von \(name(trip.deviceID)). Ende-zu-Ende-verschlüsselt.")
            }
        }
        .navigationTitle(trip.start.formatted(.dateTime.weekday(.wide).hour().minute()))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var driverSection: some View {
        Section {
            if ride.isShared {
                ForEach(ride.devices, id: \.self) { id in
                    HStack(spacing: 12) {
                        Avatar(name: name(id), id: id, size: 32)
                        Text(name(id))
                        Spacer()
                        Text(roleText(id)).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            if let mine {
                Picker(selection: Binding(
                    get: { answered ?? currentAnswer(mine) },
                    set: { choice in
                        answered = .some(choice)
                        Task { await model.answerRide(tripID: mine.id, driverID: choice) }
                    }
                )) {
                    Text("Ich").tag(String?.some(mine.deviceID))
                    ForEach(ride.devices.filter { $0 != mine.deviceID }, id: \.self) { id in
                        Text(name(id)).tag(String?.some(id))
                    }
                    Text(ride.isShared ? "Jemand anderes" : "Ich bin nur mitgefahren").tag(String?.none)
                } label: {
                    Text("Wer ist gefahren?")
                }
            }
        } header: {
            Text(ride.isShared ? "Gemeinsame Fahrt" : "Fahrer")
        } footer: {
            Text(ride.isShared
                 ? "Erkannt, weil ihr zur selben Zeit dieselbe Strecke gefahren seid. In der Bestenliste zählt nur die Fahrt des Fahrers. Mit CarPlay oder einem deiner Autos per Bluetooth vermutet die App, dass du gefahren bist."
                 : "Mitgefahrene Fahrten zählen nicht für die Bestenliste und deine Statistik.")
        }
    }

    /// My current answer as a picker tag: nil while unanswered counts as "Ich" if I likely drove.
    private func currentAnswer(_ mine: Trip) -> String? {
        if mine.isPassenger { return mine.driverID }
        if mine.role == .driver { return mine.deviceID }
        if let driver = ride.driver { return driver.deviceID }
        return mine.deviceID
    }

    private func roleText(_ id: String) -> String {
        guard let driver = ride.driver else {
            return ride.trips.first { $0.deviceID == id }?.isPassenger == true ? String(localized: "mitgefahren") : String(localized: "unklar")
        }
        guard driver.deviceID == id else { return String(localized: "mitgefahren") }
        switch (driver.certainty, driver.reason) {
        case (.confirmed, _): return String(localized: "ist gefahren")
        case (_, .carPlay?): return String(localized: "vermutlich · CarPlay")
        case (_, .bluetooth?): return String(localized: "vermutlich · „\(driver.carName ?? "")“")
        default: return String(localized: "vermutlich gefahren")
        }
    }

    private func name(_ id: String) -> String {
        members.first { $0.id == id }.map { $0.isMe ? String(localized: "Du") : $0.name ?? String(localized: "Mitglied") } ?? model.name(of: id)
    }
}

/// Weekly challenges with progress, streaks and the steps leaderboard,
/// all computed on this device from what the circle shares.
struct ChallengesSection: View {
    @Environment(AppModel.self) private var model
    let details: CircleDetails
    let trips: [Trip]
    let walkers: [(member: CircleMember, meters: Double)]

    static let stepsGoal = 70_000
    static let distanceGoal = 50_000.0

    private var stepCounts: [(member: CircleMember, week: Int)] {
        details.members.compactMap { m in
            let week = m.isMe ? (model.sharesSteps ? model.steps.week : nil) : m.location?.weekSteps
            return week.map { (m, $0) }
        }
        .sorted { $0.week > $1.week }
    }

    /// Latest trips in a row without hard braking, per driver.
    private var smoothStreaks: [(member: CircleMember, count: Int)] {
        Dictionary(grouping: trips, by: \.deviceID).compactMap { id, trips in
            let count = trips.sorted { $0.end > $1.end }.prefix { $0.hardBrakes == 0 }.count
            guard count > 0, let member = details.members.first(where: { $0.id == id }) else { return nil }
            return (member, count)
        }
        .sorted { $0.count > $1.count }
    }

    var body: some View {
        let steps = stepCounts
        if !steps.isEmpty {
            Section {
                ForEach(Array(steps.enumerated()), id: \.element.member.id) { rank, entry in
                    HStack(spacing: 12) {
                        Text(WeekView.medal(rank)).font(.title2).frame(width: 34)
                        Avatar(name: entry.member.name, id: entry.member.id, size: 38)
                        Text(entry.member.isMe ? String(localized: "Du") : entry.member.name ?? "").font(.headline)
                        Spacer()
                        Text(entry.week.formatted()).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("🚶 Schritte diese Woche")
            } footer: {
                Text("Nur wer „Schritte teilen“ eingeschaltet hat (Daten aus Health).")
            }
        }

        Section("🎯 Challenges der Woche") {
            challenge(String(localized: "70.000 Schritte"), symbol: "figure.walk",
                      entries: steps.map { ($0.member, Double($0.week) / Double(Self.stepsGoal)) })
            challenge(String(localized: "50 km unterwegs"), symbol: "map",
                      entries: walkers.map { ($0.member, $0.meters / Self.distanceGoal) })
            if !smoothStreaks.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Sanft gefahren: Serie ohne starkes Bremsen", systemImage: "flame.fill").font(.subheadline.weight(.semibold))
                    ForEach(smoothStreaks, id: \.member.id) { entry in
                        HStack {
                            Avatar(name: entry.member.name, id: entry.member.id, size: 24)
                            Text(entry.member.isMe ? String(localized: "Du") : entry.member.name ?? "")
                            Spacer()
                            Text("🔥 \(entry.count)").monospacedDigit()
                        }
                        .font(.subheadline)
                    }
                }
            }
        }
    }

    private func challenge(_ title: String, symbol: String, entries: [(CircleMember, Double)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.subheadline.weight(.semibold))
            if entries.isEmpty {
                Text("Noch niemand dabei.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(entries, id: \.0.id) { member, progress in
                HStack {
                    Avatar(name: member.name, id: member.id, size: 24)
                    ProgressView(value: min(progress, 1)).tint(progress >= 1 ? .yellow : .accentColor)
                    Text(progress >= 1 ? "🏅" : "\(Int(progress * 100)) %").font(.caption).monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(member.name ?? ""): \(Int(min(progress, 1) * 100)) Prozent")
            }
        }
    }
}

/// "Heute vor einem Jahr": a path from the local archive.
struct MemoryCard: View {
    @Environment(AppModel.self) private var model

    /// Tight around the path; the automatic framing zoomed out so far that
    /// the city's name covered the map.
    static func position(for points: [HistoryDay.Point]) -> MapCameraPosition {
        guard let first = points.first else { return .automatic }
        var (minLat, maxLat, minLon, maxLon) = (first.latitude, first.latitude, first.longitude, first.longitude)
        for p in points {
            minLat = min(minLat, p.latitude); maxLat = max(maxLat, p.latitude)
            minLon = min(minLon, p.longitude); maxLon = max(maxLon, p.longitude)
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max(0.004, (maxLat - minLat) * 1.8), longitudeDelta: max(0.004, (maxLon - minLon) * 1.4))
        return .region(MKCoordinateRegion(center: center, span: span))
    }

    var body: some View {
        if model.keepsMemories, let memory = model.memories.memory() {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label(memory.title, systemImage: "calendar.badge.clock").font(.headline)
                    Map(initialPosition: Self.position(for: memory.points), interactionModes: []) {
                        SpeedPathContent(path: SpeedPath(memory.points))
                    }
                    .mapStyle(.standard(emphasis: .muted, pointsOfInterest: .excludingAll))
                    .frame(height: 150)
                    .clipShape(.rect(cornerRadius: 14))
                    Text("\(WeekView.km(WeekView.length(memory.points))) unterwegs · nur auf diesem iPhone gespeichert")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Weather at a person's place, e.g. "☀️ 18 °C".
struct WeatherBadge: View {
    @Environment(AppModel.self) private var model
    let location: SharedLocation?
    /// Shows Apple's required " Weather" link next to it, only while there is weather to show.
    var withAttribution = false
    @State private var entry: WeatherCache.Entry?

    var body: some View {
        Group {
            if let entry {
                HStack {
                    Label {
                        Text(entry.temperature.formatted(.measurement(width: .narrow, usage: .weather, numberFormatStyle: .number.precision(.fractionLength(0)))))
                    } icon: {
                        Image(systemName: entry.symbol).symbolRenderingMode(.multicolor)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if withAttribution {
                        Spacer()
                        Link("\u{F8FF} Weather", destination: model.weather.attribution?.legalPageURL
                             ?? URL(string: "https://weatherkit.apple.com/legal-attribution.html")!)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task(id: location.map { "\(($0.latitude * 100).rounded()),\(($0.longitude * 100).rounded())" }) {
            guard model.showsWeather, let location else { entry = nil; return }
            entry = await model.weather.weather(at: location.coordinate)
        }
    }
}
