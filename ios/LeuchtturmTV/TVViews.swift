import CoreImage.CIFilterBuiltins
import MapKit
import SwiftUI

struct TVRootView: View {
    @Environment(TVModel.self) private var model

    var body: some View {
        Group {
            switch model.phase {
            case .showing:
                if let snapshot = model.snapshot { FamilyMapView(snapshot: snapshot) }
            case .pairing:
                PairingView().environment(\.colorScheme, .light)
            case .noAccount:
                NoAccountView().environment(\.colorScheme, .light)
            }
        }
        .tint(Color(widgetHex: "#2F8F5B"))
        .task { await model.run() }
    }
}

// MARK: Pairing

private struct PairingView: View {
    @Environment(TVModel.self) private var model

    var body: some View {
        HStack(spacing: 100) {
            VStack(alignment: .leading, spacing: 36) {
                Label("Leuchtturm", systemImage: "light.beacon.max")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.tint)
                Text("Deine Leute auf dem Fernseher")
                    .font(.largeTitle.bold())
                VStack(alignment: .leading, spacing: 22) {
                    Step(number: 1, text: "Öffne die Kamera auf deinem iPhone.")
                    Step(number: 2, text: "Scanne den Code und tippe auf den Link.")
                    Step(number: 3, text: "Tippe in Leuchtturm auf „Verbinden“.")
                }
                Text("Das Apple TV braucht dieselbe iCloud wie dein iPhone. Es bekommt keine Schlüssel deiner Leuchttürme und sieht nur die Karte, die dein iPhone ihm verschlüsselt schickt.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Vorschau ansehen", systemImage: "play.rectangle") { model.showDemo() }
            }
            .frame(maxWidth: 900, alignment: .leading)
            if let pairing = model.pairing, let qr = QRCode.image(for: pairing.url.absoluteString) {
                Image(uiImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 560, height: 560)
                    .padding(36)
                    .background(.white, in: .rect(cornerRadius: 40))
                    .accessibilityLabel("Code zum Verbinden")
            }
        }
        .padding(80)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Landscape())
    }
}

private struct Step: View {
    let number: Int
    let text: LocalizedStringKey

    var body: some View {
        HStack(spacing: 20) {
            Text("\(number)")
                .font(.title3.bold())
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(.tint, in: .circle)
            Text(text).font(.title3)
        }
    }
}

private struct NoAccountView: View {
    @Environment(TVModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label("Nicht bei iCloud angemeldet", systemImage: "icloud.slash")
        } description: {
            Text("Melde dich in den Einstellungen des Apple TV mit derselben iCloud wie auf deinem iPhone an.")
        } actions: {
            Button("Vorschau ansehen", systemImage: "play.rectangle") { model.showDemo() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Landscape())
    }
}

private struct Landscape: View {
    var body: some View {
        LinearGradient(
            colors: [Color(widgetHex: "#BFE8EA"), Color(widgetHex: "#DDF3EC"), Color(widgetHex: "#A9DA9F")],
            startPoint: .top, endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

// MARK: Map

private struct FamilyMapView: View {
    @Environment(TVModel.self) private var model
    let snapshot: WidgetSnapshot
    @State private var position: MapCameraPosition = .automatic
    @State private var selected: String?

    private var located: [WidgetSnapshot.Person] {
        snapshot.people.filter { $0.latitude != nil && $0.longitude != nil }
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            Map(position: $position) {
                ForEach(located) { person in
                    Annotation(person.name, coordinate: CLLocationCoordinate2D(latitude: person.latitude!, longitude: person.longitude!), anchor: .bottom) {
                        Pin(person: person, highlighted: selected == person.id)
                    }
                    .annotationTitles(.hidden)
                }
            }
            .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .excludingAll))
            // Keeps everyone clear of the list when the map frames them.
            .safeAreaPadding(EdgeInsets(top: 140, leading: 120, bottom: 120, trailing: 780))
            .focusable(false)
            .ignoresSafeArea()

            sidebar
                .frame(width: 620)
                .padding(48)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Label(snapshot.circleName, systemImage: "light.beacon.max")
                    .font(.title3.bold())
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text("Stand: \(snapshot.written, format: .relative(presentation: .named))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if model.isDemo {
                    Text("Vorschau mit erfundenen Personen").font(.caption).foregroundStyle(.orange)
                }
            }
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(snapshot.people) { person in
                        Button {
                            focus(on: person)
                        } label: {
                            PersonCard(person: person)
                        }
                        .buttonStyle(.card)
                    }
                }
                .padding(.vertical, 8)
            }
            .scrollClipDisabled()
            HStack {
                Button("Alle", systemImage: "person.3") {
                    selected = nil
                    withAnimation { position = .automatic }
                }
                if model.isDemo {
                    Button("Vorschau beenden", systemImage: "xmark") { model.endDemo() }
                } else {
                    Button("Neuer Code", systemImage: "qrcode") { model.newCode() }
                }
            }
            .font(.caption)
        }
        .padding(32)
        .frame(maxHeight: .infinity, alignment: .top)
        .glassEffect(in: .rect(cornerRadius: 40))
    }

    private func focus(on person: WidgetSnapshot.Person) {
        selected = person.id
        guard let latitude = person.latitude, let longitude = person.longitude else { return }
        withAnimation {
            position = .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude), latitudinalMeters: 1500, longitudinalMeters: 1500
            ))
        }
    }
}

private struct Pin: View {
    let person: WidgetSnapshot.Person
    let highlighted: Bool

    var body: some View {
        VStack(spacing: 6) {
            WidgetAvatar(person: person, size: highlighted ? 92 : 72)
                .overlay(Circle().stroke(.white, lineWidth: 5))
                .shadow(radius: 8, y: 4)
            Text(person.name)
                .font(.caption.bold())
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .background(.regularMaterial, in: .capsule)
        }
        .animation(.spring, value: highlighted)
    }
}

private struct PersonCard: View {
    let person: WidgetSnapshot.Person

    var body: some View {
        HStack(spacing: 20) {
            WidgetAvatar(person: person, size: 72)
            VStack(alignment: .leading, spacing: 4) {
                Text(person.name).font(.headline)
                if let status = person.status {
                    Text(status).font(.caption).lineLimit(1)
                }
                Text(person.place).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 4) {
                if let battery = person.battery {
                    Label("\(battery) %", systemImage: battery <= 10 ? "battery.0percent" : battery <= 35 ? "battery.25percent" : battery <= 60 ? "battery.50percent" : battery <= 85 ? "battery.75percent" : "battery.100percent")
                        .foregroundStyle(battery <= 15 ? .red : .secondary)
                }
                if let updated = person.updated {
                    Text(updated, format: .relative(presentation: .named)).foregroundStyle(.secondary)
                }
            }
            .font(.caption2)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum QRCode {
    static func image(for string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cgImage = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
