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
            Button("Ort hinzufügen", systemImage: "plus.circle") { sheet = .addPlace(details.ref) }
                .disabled(!details.hasKey)
        } header: {
            Text("Orte")
        } footer: {
            Text("Kommt jemand an oder geht, bekommt der Kreis Bescheid. Das prüft jedes iPhone selbst, kein Server kennt eure Orte.")
        }
    }

    private func presence(_ place: CirclePlace) -> String {
        let here = place.members(in: details, me: model.tracker.location)
        if here.isEmpty { return String(localized: "Gerade niemand da") }
        let names = here.map { $0.isMe ? String(localized: "Du") : $0.name ?? String(localized: "Jemand") }
        return String(localized: "Da: \(names.formatted(.list(type: .and)))")
    }
}

/// Creates a place: move the map until the pin sits on the right spot.
struct AddPlaceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let ref: CircleRef

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
