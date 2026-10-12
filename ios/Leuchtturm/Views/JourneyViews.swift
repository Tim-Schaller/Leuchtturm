import CoreLocation
import LeuchtturmCore
import MapKit
import SwiftUI

/// A journey this device is on: "Bin auf dem Weg" or "Heimweg-Begleitung".
struct Journey: Codable, Equatable {
    var isWalkHome: Bool
    var circleID: String
    var destination: String
    var latitude: Double
    var longitude: Double
    /// Expected (on the way) or latest (walk home) arrival.
    var deadline: Date

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

/// The member's journey that is still running, from the circle's notes.
func activeJourney(of memberID: String, in notes: [CircleNote], now: Date = Date()) -> CircleNote? {
    let mine = notes.filter { $0.senderID == memberID }.sorted { $0.timestamp > $1.timestamp }
    guard let start = mine.first(where: { $0.kind == .onMyWay || $0.kind == .walkHome }) else { return nil }
    let ended = mine.contains { ($0.kind == .arrival && $0.text == start.text || $0.kind == .journeyCancelled) && $0.timestamp >= start.timestamp }
    guard !ended, (start.deadline ?? now) > now.addingTimeInterval(-3 * 3600) else { return nil }
    return start
}

/// Round coloured buttons for what you can do right now. Each one answers
/// a tap: it gives way, the phone ticks, and what is sent right away shows
/// a spinner and then a check mark.
struct ActionGrid: View {
    @Environment(AppModel.self) private var model
    let details: CircleDetails
    @Binding var sheet: HomeSheet?

    enum Sent { case checkIn, pickUp }
    @State private var sending: Sent?
    @State private var sent: Sent?
    @State private var taps = 0
    @State private var successes = 0

    var body: some View {
        let ref = details.ref
        let fog = model.activeFog != nil
        VStack(spacing: 18) {
            HStack(alignment: .top, spacing: 4) {
                QuickButton(
                    title: sent == .checkIn ? "Eingecheckt" : "Einchecken", symbol: "mappin.and.ellipse", color: .green,
                    working: sending == .checkIn, done: sent == .checkIn
                ) { send(.checkIn, as: .checkIn) }
                    .disabled(!details.hasKey || fog)
                QuickButton(title: "Auf dem Weg", symbol: "figure.walk.motion", color: .blue) { open(.journey(ref, walkHome: false)) }
                    .disabled(!details.hasKey || model.journey != nil)
                QuickButton(title: "Heimweg", symbol: "house.and.flag.fill", color: .indigo) { open(.journey(ref, walkHome: true)) }
                    .disabled(!details.hasKey || model.journey != nil)
                QuickButton(
                    title: sent == .pickUp ? "Abgeschickt" : "Hol mich ab", symbol: "car.side.fill", color: .orange,
                    working: sending == .pickUp, done: sent == .pickUp
                ) { send(.pickUp, as: .pickUp) }
                    .disabled(!details.hasKey || fog)
            }
            HStack(alignment: .top, spacing: 4) {
                QuickButton(title: "Treffpunkt", symbol: "point.3.filled.connected.trianglepath.dotted", color: .teal) { open(.meetingPoint(ref)) }
                    .disabled(!details.hasKey)
                if fog {
                    QuickButton(title: "Nebel beenden", symbol: "cloud.fog.fill", color: .gray, active: true) {
                        taps += 1
                        Task { await model.endFog() }
                    }
                } else {
                    QuickButton(title: "Nebel", symbol: "cloud.fog.fill", color: .gray) { open(.fog) }
                }
                QuickButton(
                    title: model.liveLink == nil ? "Live-Link" : "Link läuft", symbol: "link", color: .pink,
                    active: model.liveLink != nil
                ) { open(.liveLink) }
            }
            .padding(.horizontal, 36)
        }
        .padding(.vertical, 10)
        .sensoryFeedback(.impact(weight: .light), trigger: taps)
        .sensoryFeedback(.success, trigger: successes)
    }

    private func open(_ target: HomeSheet) {
        taps += 1
        sheet = target
    }

    /// Sends at once; the button shows that it worked.
    private func send(_ kind: CircleNote.Kind, as action: Sent) {
        taps += 1
        sending = action
        Task {
            let ok = await model.send(kind, in: details.ref)
            sending = nil
            guard ok else { return }
            sent = action
            successes += 1
            try? await Task.sleep(for: .seconds(3))
            if sent == action { sent = nil }
        }
    }
}

/// A coloured circle with a symbol and a title below.
private struct QuickButton: View {
    let title: LocalizedStringResource
    let symbol: String
    let color: Color
    var working = false
    var done = false
    /// Something is running (fog, live link): a ring around the circle.
    var active = false
    let action: () -> Void
    @ScaledMetric(relativeTo: .title2) private var size = 58

    var body: some View {
        let text = String(localized: title)
        Button(action: action) {
            VStack(spacing: 7) {
                ZStack {
                    Circle()
                        .fill((done ? Color.green : color).gradient)
                    if working {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: done ? "checkmark" : symbol)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.white)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: size, height: size)
                .overlay {
                    if active { Circle().stroke(color, lineWidth: 2.5).padding(-5) }
                }
                .shadow(color: color.opacity(0.3), radius: 5, y: 3)
                // One word shrinks instead of breaking ("Einche-cken"); several words may wrap.
                Text(text)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(text.contains(" ") ? 2 : 1)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.opacity)
            }
            .frame(maxWidth: .infinity)
            .animation(.snappy, value: done)
            .animation(.snappy, value: working)
        }
        .buttonStyle(QuickButtonStyle())
        .disabled(working)
    }
}

/// Gives way while pressed; grey when it cannot be used.
private struct QuickButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .brightness(configuration.isPressed ? -0.1 : 0)
            .saturation(isEnabled ? 1 : 0)
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(.rect)
            .hoverEffect(.lift)
            .animation(.snappy(duration: 0.16), value: configuration.isPressed)
    }
}

/// While this device is on a journey: where to and when, with "end".
struct JourneyBanner: View {
    @Environment(AppModel.self) private var model
    let journey: Journey

    var body: some View {
        HStack {
            Image(systemName: journey.isWalkHome ? "house.and.flag.fill" : "figure.walk.motion").foregroundStyle(.tint)
            VStack(alignment: .leading) {
                Text(journey.isWalkHome ? "Heimweg zu \(journey.destination)" : "Auf dem Weg zu \(journey.destination)").font(.headline)
                Text(journey.isWalkHome
                     ? "Spätestens \(journey.deadline.formatted(date: .omitted, time: .shortened)) da, sonst wird dein Leuchtturm benachrichtigt"
                     : "Ankunft ca. \(journey.deadline.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Beenden") { Task { await model.cancelJourney() } }.buttonStyle(.glass)
        }
    }
}

/// Choose a destination; "Bin auf dem Weg" shows the expected arrival,
/// "Heimweg" a latest arrival.
struct JourneySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let ref: CircleRef
    let walkHome: Bool

    enum Transport: String, CaseIterable { case car, walk, bike }
    @State private var targetID = ""
    @State private var transport = Transport.car
    @State private var eta: TimeInterval?
    @State private var minutes = 30
    @State private var working = false

    private var targets: [(id: String, name: String, emoji: String, coordinate: CLLocationCoordinate2D)] {
        let details = model.latestCircle(ref.circleID)
        let places = model.places(inCircle: ref.circleID).map { (id: $0.id, name: $0.name, emoji: $0.emoji, coordinate: $0.coordinate) }
        let people = (details?.members ?? []).filter { !$0.isMe }.compactMap { m -> (id: String, name: String, emoji: String, coordinate: CLLocationCoordinate2D)? in
            guard let l = m.location, l.fogRadius == nil else { return nil }
            return (id: m.id, name: m.name ?? String(localized: "Mitglied"), emoji: "👤", coordinate: l.coordinate)
        }
        return places + (walkHome ? [] : people)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Wohin?") {
                    if targets.isEmpty {
                        Text("Lege zuerst einen Ort an, z. B. Zuhause.").foregroundStyle(.secondary)
                    }
                    Picker("Ziel", selection: $targetID) {
                        ForEach(targets, id: \.id) { Text("\($0.emoji) \($0.name)").tag($0.id) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                if walkHome {
                    Section {
                        Picker("Spätestens in", selection: $minutes) {
                            ForEach([15, 30, 45, 60, 90], id: \.self) { Text("\($0) Min.").tag($0) }
                        }
                    } footer: {
                        Text("Bist du bis dahin nicht angekommen, bekommt dein Leuchtturm einen Hinweis. Kommst du an, endet die Begleitung von selbst.")
                    }
                } else {
                    Section {
                        Picker("Unterwegs mit", selection: $transport) {
                            Label("Auto", systemImage: "car").tag(Transport.car)
                            Label("Zu Fuß", systemImage: "figure.walk").tag(Transport.walk)
                            Label("Rad", systemImage: "bicycle").tag(Transport.bike)
                        }
                        .pickerStyle(.segmented)
                        if let eta {
                            LabeledContent("Ankunft ca.", value: Date().addingTimeInterval(eta).formatted(date: .omitted, time: .shortened))
                        }
                    } footer: {
                        Text("Die Ankunftszeit berechnet Apple Karten; dafür sieht Apple Start und Ziel. Dein Leuchtturm sieht nur Ziel und Uhrzeit, Ende-zu-Ende-verschlüsselt.")
                    }
                }
            }
            .navigationTitle(walkHome ? "Heimweg-Begleitung" : "Bin auf dem Weg")
            .navigationBarTitleDisplayMode(.inline)
            .errorAlert()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen", role: .cancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Starten", action: start).disabled(working || targetID.isEmpty)
                }
            }
            .onAppear { if targetID.isEmpty { targetID = targets.first?.id ?? "" } }
            .task(id: "\(targetID)|\(transport)") { await computeETA() }
        }
        .presentationDetents([.medium, .large])
    }

    private func computeETA() async {
        guard !walkHome, let target = targets.first(where: { $0.id == targetID }), let here = model.tracker.location else { eta = nil; return }
        let request = MKDirections.Request()
        request.source = MKMapItem(location: here, address: nil)
        request.destination = MKMapItem(location: CLLocation(latitude: target.coordinate.latitude, longitude: target.coordinate.longitude), address: nil)
        request.transportType = transport == .car ? .automobile : .walking
        let seconds = try? await MKDirections(request: request).calculateETA().expectedTravelTime
        // Cycling: about 2.5 times faster than walking.
        eta = seconds.map { transport == .bike ? $0 / 2.5 : $0 }
            ?? here.distance(from: CLLocation(latitude: target.coordinate.latitude, longitude: target.coordinate.longitude)) / (transport == .car ? 9 : transport == .bike ? 4 : 1.4)
    }

    private func start() {
        guard let target = targets.first(where: { $0.id == targetID }) else { return }
        working = true
        let deadline = walkHome ? Date().addingTimeInterval(Double(minutes) * 60) : Date().addingTimeInterval(eta ?? 900)
        let journey = Journey(isWalkHome: walkHome, circleID: ref.circleID, destination: target.name,
                              latitude: target.coordinate.latitude, longitude: target.coordinate.longitude, deadline: deadline)
        Task {
            if await model.startJourney(journey) { dismiss() }
            working = false
        }
    }
}

/// A place roughly in the middle of everyone.
struct MeetingPointSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let ref: CircleRef
    @State private var category = "Café"
    @State private var results: [MKMapItem] = []
    @State private var middle: CLLocationCoordinate2D?

    static let categories: [(query: String, label: LocalizedStringResource)] = [
        ("Café", "Café"), ("Restaurant", "Restaurant"), ("Park", "Park"), ("Bahnhof", "Bahnhof"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                if let middle {
                    Section {
                        Map(initialPosition: .region(MKCoordinateRegion(center: middle, latitudinalMeters: 3000, longitudinalMeters: 3000))) {
                            Annotation("Mitte", coordinate: middle) { Image(systemName: "scope").font(.title2).foregroundStyle(.tint) }
                            ForEach(results, id: \.self) { item in
                                Marker(item.name ?? "", coordinate: item.location.coordinate)
                            }
                        }
                        .frame(height: 220)
                        .listRowInsets(EdgeInsets())
                        Picker("Was?", selection: $category) {
                            ForEach(Self.categories, id: \.query) { Text($0.label).tag($0.query) }
                        }
                        .pickerStyle(.segmented)
                    }
                    Section {
                        Button("Genau die Mitte", systemImage: "scope") { send(name: String(localized: "Treffpunkt"), coordinate: middle) }
                        ForEach(results, id: \.self) { item in
                            Button {
                                send(name: item.name ?? String(localized: "Treffpunkt"), coordinate: item.location.coordinate)
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(item.name ?? "").foregroundStyle(.primary)
                                    Text(CLLocation(latitude: middle.latitude, longitude: middle.longitude).distance(from: item.location)
                                        .formatted(.number.precision(.fractionLength(0))) + " m von der Mitte")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } footer: {
                        Text("Die Suche läuft über Apple Karten mit der Mitte als Ort. Wer im Nebel ist, zählt nicht mit.")
                    }
                } else {
                    Text("Es teilen noch zu wenige ihren Standort.").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Treffpunkt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen", role: .cancel) { dismiss() } } }
            .onAppear { middle = computeMiddle() }
            .task(id: category) { await search() }
        }
        .presentationDetents([.large])
    }

    private func computeMiddle() -> CLLocationCoordinate2D? {
        var points = (model.latestCircle(ref.circleID)?.members ?? []).filter { !$0.isMe }
            .compactMap { $0.location?.fogRadius == nil ? $0.location?.coordinate : nil }
        if let me = model.tracker.location?.coordinate { points.append(me) }
        guard points.count >= 2 else { return nil }
        return CLLocationCoordinate2D(latitude: points.map(\.latitude).reduce(0, +) / Double(points.count),
                                      longitude: points.map(\.longitude).reduce(0, +) / Double(points.count))
    }

    private func search() async {
        guard let middle else { return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = category
        request.region = MKCoordinateRegion(center: middle, latitudinalMeters: 2000, longitudinalMeters: 2000)
        results = Array(((try? await MKLocalSearch(request: request).start())?.mapItems ?? []).prefix(6))
    }

    private func send(name: String, coordinate: CLLocationCoordinate2D) {
        Task {
            if await model.sendMeetingPoint(name: name, coordinate: coordinate, in: ref) { dismiss() }
        }
    }
}
