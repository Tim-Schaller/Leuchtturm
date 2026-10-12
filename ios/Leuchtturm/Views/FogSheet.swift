import SwiftUI

/// Starts fog mode: only an approximate area is shared for a while.
struct FogSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var radius = Fog.sizes[0].radius
    @State private var hours = 3.0

    var body: some View {
        NavigationStack {
            Form {
                Section("Wie ungenau?") {
                    Picker("Größe", selection: $radius) {
                        ForEach(Fog.sizes, id: \.radius) { size in
                            Text(size.label).tag(size.radius)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section {
                    Picker("Wie lange?", selection: $hours) {
                        Text("1 Std.").tag(1.0)
                        Text("3 Std.").tag(3.0)
                        Text("8 Std.").tag(8.0)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Wie lange?")
                } footer: {
                    Text("Solange der Nebel aktiv ist, verlässt dein genauer Standort dein iPhone nicht. Dein Leuchtturm sieht nur die Gegend und deinen Akkustand. Check-ins sind so lange aus. Danach wird automatisch wieder genau geteilt.")
                }
            }
            .navigationTitle("Nebel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Starten") {
                        Task {
                            await model.startFog(radius: radius, hours: hours)
                            dismiss()
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
