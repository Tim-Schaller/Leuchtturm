import LeuchtturmCore
import SwiftUI

struct CircleDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let circleID: String

    @State private var details: CircleDetails?
    @State private var showInvite = false
    @State private var showRename = false
    @State private var newName = ""
    @State private var memberToRemove: CircleMember?
    @State private var confirmLeave = false

    var body: some View {
        List {
            if let details {
                Section {
                    ForEach(details.members) { member in
                        MemberRow(member: member)
                            .swipeActions {
                                if details.isOwner && !member.isMe {
                                    Button("Entfernen", role: .destructive) { memberToRemove = member }
                                }
                            }
                    }
                } header: {
                    Text("Mitglieder (\(details.members.count))")
                } footer: {
                    Text("Vergleicht den Sicherheitscode unter jedem Namen persönlich mit dem Gerät der Person. Stimmt er überein, kann der Server niemanden unbemerkt einschleusen.")
                }

                Section {
                    Button("Jemanden einladen", systemImage: "person.badge.plus") { showInvite = true }
                    if details.isOwner {
                        Button("Umbenennen", systemImage: "pencil") {
                            newName = details.name ?? ""
                            showRename = true
                        }
                    }
                    Button("Kreis verlassen", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                        confirmLeave = true
                    }
                } footer: {
                    Label("Ende-zu-Ende-verschlüsselt · Schlüsselversion \(details.epoch)", systemImage: "lock.fill")
                        .font(.caption)
                }
            } else {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle(details?.name ?? "Kreis")
        .refreshable { await load() }
        .task { await load() }
        .sheet(isPresented: $showInvite) {
            InviteSheet(circleID: circleID, circleName: details?.name)
        }
        .alert("Kreis umbenennen", isPresented: $showRename) {
            TextField("Name", text: $newName)
            Button("Abbrechen", role: .cancel) {}
            Button("Speichern") {
                let name = newName
                let id = circleID
                Task {
                    await model.run { try await $0.rename(circleID: id, to: name) }
                    await load()
                    await model.refresh()
                }
            }
        }
        .confirmationDialog(
            "\(memberToRemove?.name ?? "Mitglied") entfernen?",
            isPresented: Binding(get: { memberToRemove != nil }, set: { if !$0 { memberToRemove = nil } }),
            titleVisibility: .visible,
            presenting: memberToRemove
        ) { member in
            Button("Entfernen", role: .destructive) {
                let id = circleID
                Task {
                    await model.run { try await $0.remove(memberID: member.id, from: id) }
                    await load()
                }
            }
        } message: { _ in
            Text("Der Kreis bekommt einen neuen Schlüssel. Die Person kann danach nichts mehr aus diesem Kreis lesen.")
        }
        .confirmationDialog("Kreis verlassen?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Verlassen", role: .destructive) {
                let id = circleID
                Task {
                    if await model.run({ try await $0.leave(circleID: id) }) != nil {
                        await model.refresh()
                        dismiss()
                    }
                }
            }
        } message: {
            Text("Du kannst nur über eine neue Einladung zurückkommen.")
        }
    }

    private func load() async {
        let id = circleID
        if let loaded = await model.run({ try await $0.circle(id) }) {
            details = loaded
        }
    }
}

private struct MemberRow: View {
    let member: CircleMember

    var body: some View {
        HStack(spacing: 12) {
            Text(initials)
                .font(.subheadline.bold())
                .frame(width: 36, height: 36)
                .glassEffect(.regular.tint(.accentColor.opacity(0.35)), in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(member.name ?? "Unbekannt")
                        .font(.body)
                        .foregroundStyle(member.name == nil ? .secondary : .primary)
                    if member.isMe {
                        Text("Du").font(.caption).foregroundStyle(.secondary)
                    }
                    if member.isOwner {
                        Image(systemName: "crown.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                            .accessibilityLabel("Besitzer")
                    }
                }
                Text(member.safetyCode)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Sicherheitscode \(member.safetyCode)")
            }
        }
        .padding(.vertical, 2)
    }

    private var initials: String {
        let parts = (member.name ?? "?").split(separator: " ").prefix(2)
        return parts.compactMap(\.first).map(String.init).joined().uppercased()
    }
}
