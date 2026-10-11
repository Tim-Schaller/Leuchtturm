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
                    if let host = model.serverURL?.host {
                        LabeledContent("Server", value: host)
                    }
                } header: {
                    Text("Dieses Gerät")
                } footer: {
                    Text("Deine Schlüssel liegen nur auf diesem iPhone. Es gibt kein Passwort und kein Konto beim Server.")
                }

                Section {
                    Button("Gerät beim Server löschen", role: .destructive) { confirmDelete = true }
                    Button("Nur lokal zurücksetzen", role: .destructive) { confirmReset = true }
                } footer: {
                    Text("Löschen entfernt dich aus allen Kreisen und löscht deine Schlüssel. Das lässt sich nicht rückgängig machen.")
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
            .confirmationDialog("Gerät wirklich löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Löschen", role: .destructive) {
                    Task {
                        await model.deleteDevice()
                        if model.phase == .onboarding { dismiss() }
                    }
                }
            }
            .confirmationDialog("Nur lokal zurücksetzen?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Zurücksetzen", role: .destructive) {
                    model.resetLocal()
                    dismiss()
                }
            } message: {
                Text("Für den Fall, dass der Server nicht mehr existiert. Deine Mitgliedschaften bleiben auf dem Server bestehen, bis jemand dich entfernt.")
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
