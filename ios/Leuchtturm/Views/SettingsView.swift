import LeuchtturmCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var confirmDelete = false
    @State private var confirmReset = false
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Dein Name", text: $name)
                        .submitLabel(.done)
                        .onSubmit(saveName)
                    if name.trimmingCharacters(in: .whitespaces) != model.displayName {
                        Button("Name speichern", action: saveName)
                            .disabled(saving)
                    }
                } header: {
                    Text("Name")
                } footer: {
                    Text("Wird in allen deinen Kreisen verschlüsselt aktualisiert.")
                }

                Section {
                    if let client = model.client {
                        LabeledContent("Sicherheitscode") {
                            Text(client.safetyCode).font(.body.monospaced())
                        }
                    }
                } header: {
                    Text("Dieses Gerät")
                } footer: {
                    Text("Deine Schlüssel liegen nur auf diesem iPhone und werden nicht mit iCloud synchronisiert.")
                }

                Section {
                    Text("Leuchtturm speichert in iCloud (Apple). Kreisnamen, Namen und Standorte werden vorher auf dem iPhone verschlüsselt, Apple kann sie nicht lesen. Apple sieht aber, welche iCloud-Konten zusammen in einem Kreis sind und wann Daten geschrieben werden. Die Daten liegen in Apples Rechenzentren, nicht zwingend in der EU.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Wo liegen meine Daten?")
                }

                Section {
                    Button("Alle meine Daten löschen", role: .destructive) { confirmDelete = true }
                    Button("Nur dieses Gerät zurücksetzen", role: .destructive) { confirmReset = true }
                } footer: {
                    Text("Löschen entfernt deine eigenen Kreise für alle, verlässt alle anderen und löscht deine Schlüssel. Das lässt sich nicht rückgängig machen.")
                }

                Section {
                    Link(destination: URL(string: "https://github.com/Tim-Schaller/leuchtturm")!) {
                        Label("Quellcode auf GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                }
            }
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .errorAlert()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
            .onAppear { name = model.displayName }
            .confirmationDialog("Wirklich alles löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Alles löschen", role: .destructive) {
                    Task {
                        await model.deleteAllData()
                        if model.phase == .onboarding { dismiss() }
                    }
                }
            }
            .confirmationDialog("Nur dieses Gerät zurücksetzen?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Zurücksetzen", role: .destructive) {
                    model.resetLocal()
                    dismiss()
                }
            } message: {
                Text("Löscht die Schlüssel auf diesem iPhone. Deine Kreise in iCloud bleiben bestehen, du kannst sie danach aber nicht mehr lesen und brauchst neue Einladungen.")
            }
        }
    }

    private func saveName() {
        guard !saving else { return }
        saving = true
        let value = name
        Task {
            _ = await model.changeDisplayName(value)
            saving = false
        }
    }
}
