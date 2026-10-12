import SwiftUI

/// The extras besides sharing the location, each with a switch. Shown once
/// after the first Leuchtturm and from Settings, so nobody has to find them.
struct FeaturesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 10) {
                        Image("Logo")
                            .resizable()
                            .scaledToFit()
                            .frame(height: 84)
                            .accessibilityHidden(true)
                        Text("Was soll Leuchtturm noch können?")
                            .font(.title2.bold())
                            .multilineTextAlignment(.center)
                        Text("Schalte ein, was du möchtest. Du kannst alles jederzeit in den Einstellungen ändern.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .listRowBackground(Color.clear)

                Section {
                    FeatureRow(
                        title: "Fahrten", symbol: "car.fill", color: .blue,
                        text: "Erkennt Autofahrten mit Strecke und Tempo, für deinen Wochenrückblick und die Bestenliste.",
                        isOn: Binding(get: { model.sharesTrips }, set: { on in Task { await model.setSharesTrips(on) } })
                    )
                    FeatureRow(
                        title: "Unfallerkennung", symbol: "car.side.rear.and.collision.and.car.side.front", color: .red,
                        text: "Hält das Auto schlagartig an, fragt die App „Alles okay?“. Ohne Antwort geht nach 60 Sekunden ein SOS raus.",
                        isOn: Binding(get: { model.detectsCrashes }, set: { model.setDetectsCrashes($0) })
                    )
                    FeatureRow(
                        title: "Verlauf", symbol: "point.topleft.down.to.point.bottomright.curvepath.fill", color: .purple,
                        text: "Deine Wege der letzten Tage, für deine Leuchttürme sichtbar.",
                        isOn: Binding(get: { model.sharesHistory }, set: { on in Task { await model.setSharesHistory(on) } })
                    )
                    if StepsMonitor.isAvailable {
                        FeatureRow(
                            title: "Schritte", symbol: "figure.walk", color: .orange,
                            text: "Deine Schritte aus Apple Health in der Bestenliste.",
                            isOn: Binding(get: { model.sharesSteps }, set: { on in Task { await model.setSharesSteps(on) } })
                        )
                    }
                    FeatureRow(
                        title: "Erinnerungen", symbol: "sparkles", color: .pink,
                        text: "„Heute vor einem Jahr“ mit deinen eigenen Wegen. Bleibt nur auf diesem iPhone.",
                        isOn: Binding(get: { model.keepsMemories }, set: { model.setKeepsMemories($0) })
                    )
                    FeatureRow(
                        title: "Wetter", symbol: "cloud.sun.fill", color: .cyan,
                        text: "Das Wetter dort, wo die anderen gerade sind.",
                        isOn: Binding(get: { model.showsWeather }, set: { model.setShowsWeather($0) })
                    )
                } footer: {
                    Text("Was du teilst, ist Ende-zu-Ende-verschlüsselt und nur für deine Leuchttürme. Mehr dazu in den Einstellungen.")
                }
            }
            .navigationTitle("Funktionen")
            .navigationBarTitleDisplayMode(.inline)
            .errorAlert()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } }
            }
        }
    }
}

private struct FeatureRow: View {
    let title: LocalizedStringResource
    let symbol: String
    let color: Color
    let text: LocalizedStringResource
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: symbol)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(color.gradient, in: .rect(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(text).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }
}
