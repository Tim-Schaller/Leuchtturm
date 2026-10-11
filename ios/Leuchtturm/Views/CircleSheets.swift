import LeuchtturmCore
import SwiftUI
import UIKit

struct CreateCircleSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var working = false
    let onCreated: (CircleRef) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("z. B. Familie", text: $name)
                        .submitLabel(.done)
                        .onSubmit(create)
                } footer: {
                    Text("Der Name ist verschlüsselt und nur für Mitglieder sichtbar.")
                }
            }
            .navigationTitle("Neuer Kreis")
            .navigationBarTitleDisplayMode(.inline)
            .errorAlert()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Erstellen", action: create)
                        .disabled(working || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func create() {
        guard !working else { return }
        working = true
        Task {
            if let ref = await model.createCircle(name: name) {
                dismiss()
                onCreated(ref)
            }
            working = false
        }
    }
}

struct JoinSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var working = false
    let link: InviteLink?
    let onJoined: (CircleRef) -> Void

    private var parsed: InviteLink? { link ?? InviteLink(string: text) }

    var body: some View {
        NavigationStack {
            Form {
                if link == nil {
                    Section {
                        TextField("leuchtturm://join?…", text: $text, axis: .vertical)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.footnote.monospaced())
                        Button("Aus Zwischenablage einfügen", systemImage: "doc.on.clipboard") {
                            text = UIPasteboard.general.string ?? ""
                        }
                    } header: {
                        Text("Einladungslink")
                    } footer: {
                        if !text.isEmpty && parsed == nil {
                            Text("Das ist kein gültiger Leuchtturm-Einladungslink.")
                                .foregroundStyle(.red)
                        }
                    }
                } else {
                    Section {
                        Label("Du wurdest in einen Kreis eingeladen.", systemImage: "envelope.open")
                    } footer: {
                        Text("Nach dem Beitritt sehen die Mitglieder deinen Namen und deinen Standort, Ende-zu-Ende-verschlüsselt. Das Teilen kannst du in den Einstellungen jederzeit pausieren.")
                    }
                }
                Section {
                    Label("Der Kreis liegt verschlüsselt in der iCloud des Besitzers. Mit dem Beitritt sieht Apple, dass dein iCloud-Konto dazugehört.", systemImage: "icloud")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Kreis beitreten")
            .navigationBarTitleDisplayMode(.inline)
            .errorAlert()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Beitreten", action: join)
                        .disabled(working || parsed == nil)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func join() {
        guard let parsed, !working else { return }
        working = true
        Task {
            if let ref = await model.join(parsed) {
                dismiss()
                onJoined(ref)
            }
            working = false
        }
    }
}
