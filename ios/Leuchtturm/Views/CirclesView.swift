import LeuchtturmCore
import SwiftUI
import UIKit

struct CirclesView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [CircleRef] = []
    @State private var showCreate = false
    @State private var showJoin = false
    @State private var showSettings = false

    var body: some View {
        @Bindable var bindable = model
        NavigationStack(path: $path) {
            List {
                ForEach(model.circles) { circle in
                    NavigationLink(value: circle.ref) {
                        CircleRow(circle: circle)
                    }
                }
            }
            .overlay {
                if model.circles.isEmpty && model.hasLoadedCircles {
                    ContentUnavailableView {
                        Label("Noch keine Kreise", systemImage: "person.3")
                    } description: {
                        Text("Erstelle einen Kreis für deine Familie oder Freunde, oder tritt über eine Einladung bei.")
                    } actions: {
                        Button("Kreis erstellen") { showCreate = true }
                            .buttonStyle(.glassProminent)
                        Button("Einladung einfügen") { showJoin = true }
                            .buttonStyle(.glass)
                    }
                }
            }
            .navigationTitle("Kreise")
            .navigationDestination(for: CircleRef.self) { ref in
                CircleDetailView(ref: ref)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Einstellungen", systemImage: "gearshape") { showSettings = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("Hinzufügen", systemImage: "plus") {
                        Button("Kreis erstellen", systemImage: "plus.circle") { showCreate = true }
                        Button("Einladung einfügen", systemImage: "link") { showJoin = true }
                    }
                }
            }
            .refreshable { await model.refresh() }
            .task { await model.refresh() }
            .sheet(isPresented: $showCreate) {
                CreateCircleSheet { ref in path.append(ref) }
            }
            .sheet(isPresented: $showJoin) {
                JoinSheet(link: nil) { ref in path.append(ref) }
            }
            .sheet(item: $bindable.pendingInvite) { link in
                JoinSheet(link: link) { ref in path.append(ref) }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
        }
    }
}

private struct CircleRow: View {
    let circle: CircleSummary

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.3.fill")
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(circle.name ?? "Unbekannter Kreis")
                    .font(.headline)
                if circle.isOwner {
                    Text("Besitzer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

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
                        Text("Nach dem Beitritt sehen die Mitglieder deinen Namen. Standortfreigabe kommt in einem späteren Update.")
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
