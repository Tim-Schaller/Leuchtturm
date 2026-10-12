import MapKit
import SwiftUI

struct WatchHomeView: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        NavigationStack {
            if let snapshot = model.snapshot {
                List {
                    ForEach(snapshot.people) { person in
                        NavigationLink(value: person.id) { PersonRow(person: person) }
                    }
                    Section {
                        ActionButtons()
                    } footer: {
                        Text("Stand: \(snapshot.written, format: .relative(presentation: .named))")
                    }
                }
                .navigationTitle(snapshot.circleName)
                .navigationDestination(for: String.self) { id in
                    if let person = snapshot.people.first(where: { $0.id == id }) {
                        PersonDetail(person: person)
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("Leuchtturm", systemImage: "light.beacon.max")
                } description: {
                    Text("Öffne Leuchtturm auf deinem iPhone. Die Uhr zeigt dann deinen Leuchtturm.")
                }
            }
        }
        .tint(Color(widgetHex: "#2F8F5B"))
    }
}

private struct PersonRow: View {
    let person: WidgetSnapshot.Person

    var body: some View {
        HStack(spacing: 8) {
            WidgetAvatar(person: person, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline) {
                    Text(person.name).font(.headline).lineLimit(1)
                    Spacer(minLength: 2)
                    if let battery = person.battery {
                        Text("\(battery) %")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(battery <= 15 ? .red : .secondary)
                            .fixedSize()
                            .accessibilityLabel("Akku \(battery) Prozent")
                    }
                }
                Text(person.status ?? person.place)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct PersonDetail: View {
    let person: WidgetSnapshot.Person

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let latitude = person.latitude, let longitude = person.longitude {
                    let center = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
                    Map(initialPosition: .region(MKCoordinateRegion(center: center, latitudinalMeters: 900, longitudinalMeters: 900))) {
                        Annotation(person.name, coordinate: center) {
                            WidgetAvatar(person: person, size: 28)
                                .overlay(Circle().stroke(.white, lineWidth: 2))
                        }
                    }
                    .frame(height: 120)
                    .clipShape(.rect(cornerRadius: 12))
                }
                Text(person.place).font(.headline)
                if let status = person.status {
                    Text(status).font(.footnote)
                }
                HStack {
                    if let updated = person.updated {
                        Text(updated, format: .relative(presentation: .named))
                    }
                    Spacer()
                    if let battery = person.battery { BatteryLabel(level: battery) }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(person.name)
    }
}

private struct ActionButtons: View {
    @Environment(WatchModel.self) private var model
    @State private var confirmSOS = false

    var body: some View {
        @Bindable var model = model
        // Sends a check-in with the position: "alles gut" to everyone.
        Button("Alles gut", systemImage: "hand.thumbsup.fill") {
            Task { await model.checkIn() }
        }
        .disabled(model.busy)
        Button("SOS", systemImage: "sos", role: .destructive) { confirmSOS = true }
            .disabled(model.busy)
            .confirmationDialog("SOS an alle senden?", isPresented: $confirmSOS) {
                Button("SOS senden", role: .destructive) { Task { await model.sendSOS() } }
            } message: {
                Text("Dein iPhone schickt allen in deinen Leuchttürmen ein SOS mit deinem Ort.")
            }
            .alert(model.feedback ?? "", isPresented: Binding(get: { model.feedback != nil }, set: { if !$0 { model.feedback = nil } })) {
                Button("OK") {}
            }
    }
}

struct BatteryLabel: View {
    let level: Int

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: level <= 10 ? "battery.0percent" : level <= 35 ? "battery.25percent" : level <= 60 ? "battery.50percent" : level <= 85 ? "battery.75percent" : "battery.100percent")
            Text("\(level) %")
        }
        .foregroundStyle(level <= 15 ? .red : .secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Akku \(level) Prozent")
    }
}
