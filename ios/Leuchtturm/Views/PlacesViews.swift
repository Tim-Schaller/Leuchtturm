import CoreLocation
import LeuchtturmCore
import MapKit
import SwiftUI

extension CirclePlace {
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// For showing the place on the map.
    var center: SharedLocation? {
        SharedLocation(latitude: latitude, longitude: longitude, accuracy: Double(radius), timestamp: Date())
    }

    /// Members whose (exact) position is inside the place.
    func members(in details: CircleDetails, me: CLLocation?) -> [CircleMember] {
        details.members.filter { member in
            if member.isMe, let me {
                return distance(toLatitude: me.coordinate.latitude, longitude: me.coordinate.longitude) <= Double(radius)
            }
            guard let location = member.location, location.fogRadius == nil else { return false }
            return distance(toLatitude: location.latitude, longitude: location.longitude) <= Double(radius)
        }
    }
}

/// A place's emoji on the map.
struct PlaceBadge: View {
    let emoji: String

    var body: some View {
        Text(emoji)
            .font(.title3)
            .frame(width: 36, height: 36)
            .background(.white, in: .rect(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 2) }
            .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
            .accessibilityHidden(true)
    }
}

/// The circle's places in the drawer, with who is there right now.
struct PlacesSection: View {
    @Environment(AppModel.self) private var model
    let details: CircleDetails
    @Binding var sheet: HomeSheet?
    let onShowPlace: (SharedLocation) -> Void

    var body: some View {
        Section {
            ForEach(details.places) { place in
                Button {
                    if let center = place.center { onShowPlace(center) }
                } label: {
                    HStack(spacing: 12) {
                        Text(place.emoji)
                            .font(.title3)
                            .frame(width: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(place.name).font(.headline)
                            Text(presence(place))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                .tint(.primary)
                .swipeActions {
                    if place.creatorID == model.client?.deviceID || details.isOwner {
                        Button("Löschen", role: .destructive) {
                            let ref = details.ref
                            Task {
                                await model.run { try await $0.deletePlace(place.id, in: ref) }
                                model.noteRemoteChange()
                            }
                        }
                    }
                }
            }
            ForEach(model.placeSuggestions(inCircle: details.id)) { suggestion in
                Button {
                    sheet = .addPlace(details.ref, suggestion)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "sparkles").frame(width: 36).foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Vorschlag: Hier bist du oft").font(.headline)
                            Text("\(suggestion.visits) Besuche · zusammen \(Duration.seconds(suggestion.totalTime).formatted(.units(allowed: [.hours, .minutes], width: .narrow)))")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .tint(.primary)
                .disabled(!details.hasKey)
            }
            Button("Ort hinzufügen", systemImage: "plus.circle") { sheet = .addPlace(details.ref, nil) }
                .disabled(!details.hasKey)
        } header: {
            Text("Orte")
        } footer: {
            Text("Kommt jemand an oder geht, bekommt der Leuchtturm Bescheid. Das prüft jedes iPhone selbst; die Orte liegen verschlüsselt in iCloud, Apple kann sie nicht lesen. Vorschläge entstehen aus deinen Aufenthalten, die nur auf diesem iPhone gespeichert sind.")
        }
    }

    private func presence(_ place: CirclePlace) -> String {
        let here = place.members(in: details, me: model.tracker.location)
        if here.isEmpty { return String(localized: "Gerade niemand da") }
        let names = here.map { $0.isMe ? String(localized: "Du") : $0.name ?? String(localized: "Jemand") }
        return String(localized: "Da: \(names.formatted(.list(type: .and)))")
    }
}

/// "Tell me if … has not arrived by …" for one member.
struct ArrivalWatchSection: View {
    @Environment(AppModel.self) private var model
    let member: CircleMember
    let circleID: String
    @State private var adding = false

    var body: some View {
        let places = model.places(inCircle: circleID)
        Section {
            ForEach(model.arrivalWatches.filter { $0.memberID == member.id && $0.circleID == circleID }) { watch in
                let place = places.first { $0.id == watch.placeID }
                HStack {
                    Text(place?.emoji ?? "📍")
                    Text("\(place?.name ?? String(localized: "Ort")) bis \(String(format: "%02d:%02d", watch.hour, watch.minute))")
                    Spacer()
                    Text(Self.label(watch.repeats)).foregroundStyle(.secondary)
                }
                .swipeActions {
                    Button("Löschen", role: .destructive) { Task { await model.removeArrivalWatch(watch.id) } }
                }
            }
            Button("Melden, wenn nicht angekommen", systemImage: "alarm") { adding = true }
                .disabled(places.isEmpty)
        } header: {
            Text("Ankunft")
        } footer: {
            Text(places.isEmpty
                ? "Lege zuerst einen Ort an, z. B. die Schule."
                : "Nur auf deinem iPhone gespeichert. Kommt die Meldung über die Ankunft zu spät an, kann der Hinweis auch einmal zu Unrecht kommen.")
        }
        .sheet(isPresented: $adding) {
            ArrivalWatchSheet(member: member, circleID: circleID, places: places)
        }
    }

    static func label(_ repeats: ArrivalWatch.Repeat) -> String {
        switch repeats {
        case .once: String(localized: "einmal")
        case .weekdays: String(localized: "werktags")
        case .daily: String(localized: "täglich")
        }
    }
}

private struct ArrivalWatchSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let member: CircleMember
    let circleID: String
    let places: [CirclePlace]

    @State private var placeID = ""
    @State private var time = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var repeats = ArrivalWatch.Repeat.weekdays

    var body: some View {
        NavigationStack {
            Form {
                Picker("Ort", selection: $placeID) {
                    ForEach(places) { Text("\($0.emoji) \($0.name)").tag($0.id) }
                }
                DatePicker("Bis", selection: $time, displayedComponents: .hourAndMinute)
                Picker("Wiederholen", selection: $repeats) {
                    ForEach(ArrivalWatch.Repeat.allCases, id: \.self) { Text(ArrivalWatchSection.label($0)).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            .navigationTitle("Ankunft von \(member.name ?? "Mitglied")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        guard let place = places.first(where: { $0.id == placeID }) else { return }
                        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
                        Task {
                            await model.addArrivalWatch(
                                member: member, place: place, circleID: circleID,
                                hour: parts.hour ?? 8, minute: parts.minute ?? 0, repeats: repeats
                            )
                            dismiss()
                        }
                    }
                    .disabled(placeID.isEmpty)
                }
            }
            .onAppear { if placeID.isEmpty { placeID = places.first?.id ?? "" } }
        }
        .presentationDetents([.medium])
    }
}

/// Creates a place: move the map until the pin sits on the right spot.
struct AddPlaceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let ref: CircleRef
    /// Starts the map at a suggested spot.
    var suggestion: PlaceSuggestion?

    static let emojis = ["🏠", "🏫", "💼", "🏋️", "🛒", "☕️", "⚽️", "❤️"]

    @State private var name = ""
    @State private var emoji = "🏠"
    @State private var radius = 150
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var center: CLLocationCoordinate2D?
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Map(position: $camera) {
                        if let center {
                            MapCircle(center: center, radius: Double(radius))
                                .foregroundStyle(Color.accentColor.opacity(0.18))
                                .stroke(Color.accentColor, lineWidth: 2)
                        }
                    }
                    .overlay { PlaceBadge(emoji: emoji).allowsHitTesting(false) }
                    .onMapCameraChange(frequency: .continuous) { center = $0.region.center }
                    .frame(height: 240)
                    .listRowInsets(EdgeInsets())
                } footer: {
                    Text("Verschiebe die Karte, bis der Ort in der Mitte liegt.")
                }
                Section {
                    TextField("Name, z. B. Zuhause", text: $name)
                    Picker("Symbol", selection: $emoji) {
                        ForEach(Self.emojis, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.palette)
                    Picker("Größe", selection: $radius) {
                        Text("Klein").tag(100)
                        Text("Mittel").tag(150)
                        Text("Groß").tag(300)
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text("Ort, Name und Symbol sind Ende-zu-Ende-verschlüsselt.")
                }
            }
            .onAppear {
                if let suggestion {
                    camera = .region(MKCoordinateRegion(
                        center: CLLocationCoordinate2D(latitude: suggestion.latitude, longitude: suggestion.longitude),
                        latitudinalMeters: 600, longitudinalMeters: 600
                    ))
                }
            }
            .navigationTitle("Neuer Ort")
            .navigationBarTitleDisplayMode(.inline)
            .errorAlert()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern", action: save)
                        .disabled(saving || center == nil || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.large])
    }

    private func save() {
        guard let center, !saving else { return }
        saving = true
        let (name, emoji, radius, ref) = (name, emoji, radius, ref)
        Task {
            let added = await model.run {
                try await $0.addPlace(name: name, emoji: emoji, latitude: center.latitude, longitude: center.longitude, radius: radius, in: ref)
            }
            saving = false
            if added != nil {
                model.noteRemoteChange()
                dismiss()
            }
        }
    }
}
