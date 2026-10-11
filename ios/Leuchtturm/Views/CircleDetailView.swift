import LeuchtturmCore
import SwiftUI

struct CircleDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let ref: CircleRef

    @State private var details: CircleDetails?
    @State private var showInvite = false
    @State private var showRename = false
    @State private var newName = ""
    @State private var removal: Removal?
    @State private var confirmLeave = false

    /// Someone the owner is about to remove (a member or an unverified participant).
    struct Removal: Identifiable {
        let userID: String
        let label: String
        var id: String { userID }
    }

    var body: some View {
        List {
            if let details {
                if !details.hasKey {
                    Section {
                        Label("Warte auf den Schlüssel vom Besitzer. Er wird übertragen, sobald der Besitzer die App öffnet.", systemImage: "key")
                            .font(.callout)
                    }
                }

                Section {
                    ForEach(details.members) { member in
                        MemberRow(member: member)
                            .swipeActions {
                                if details.isOwner, !member.isMe, let userID = member.userID {
                                    Button("Entfernen", role: .destructive) {
                                        removal = Removal(userID: userID, label: member.name ?? "Mitglied")
                                    }
                                }
                            }
                    }
                } header: {
                    Text("Mitglieder (\(details.members.count))")
                } footer: {
                    Text("Vergleicht den Sicherheitscode unter jedem Namen persönlich mit dem Gerät der Person. Stimmt er überein, kann niemand unbemerkt einen fremden Schlüssel unterschieben.")
                }

                if details.isOwner && !details.unverifiedUserIDs.isEmpty {
                    Section {
                        ForEach(details.unverifiedUserIDs, id: \.self) { userID in
                            HStack {
                                Label("Unbekannter Teilnehmer", systemImage: "person.fill.questionmark")
                                Spacer()
                                Button("Entfernen", role: .destructive) {
                                    removal = Removal(userID: userID, label: "Unbekannten Teilnehmer")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    } header: {
                        Text("Nicht bestätigt")
                    } footer: {
                        Text("Diese iCloud-Konten haben den Freigabelink geöffnet, aber keine gültige Einladung. Sie sehen nur verschlüsselte Daten.")
                    }
                }

                Section {
                    Button("Jemanden einladen", systemImage: "person.badge.plus") { showInvite = true }
                        .disabled(!details.hasKey)
                    if details.isOwner {
                        Button("Umbenennen", systemImage: "pencil") {
                            newName = details.name ?? ""
                            showRename = true
                        }
                    }
                    Button(
                        ref.isOwned ? "Kreis löschen" : "Kreis verlassen",
                        systemImage: ref.isOwned ? "trash" : "rectangle.portrait.and.arrow.right",
                        role: .destructive
                    ) {
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
        .task(id: model.externalChanges) { await load() }
        .sheet(isPresented: $showInvite) {
            InviteSheet(ref: ref, circleName: details?.name)
        }
        .alert("Kreis umbenennen", isPresented: $showRename) {
            TextField("Name", text: $newName)
            Button("Abbrechen", role: .cancel) {}
            Button("Speichern") {
                let name = newName
                let ref = ref
                Task {
                    await model.run { try await $0.rename(ref, to: name) }
                    await load()
                    await model.refresh()
                }
            }
        }
        .confirmationDialog(
            "\(removal?.label ?? "Mitglied") entfernen?",
            isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }),
            titleVisibility: .visible,
            presenting: removal
        ) { target in
            Button("Entfernen", role: .destructive) {
                let ref = ref
                let userID = target.userID
                Task {
                    await model.run { try await $0.remove(userID: userID, from: ref) }
                    await load()
                }
            }
        } message: { _ in
            Text("Der Kreis bekommt einen neuen Schlüssel. Die Person verliert den Zugriff und kann nichts mehr lesen, was danach geteilt wird.")
        }
        .confirmationDialog(
            ref.isOwned ? "Kreis für alle löschen?" : "Kreis verlassen?",
            isPresented: $confirmLeave,
            titleVisibility: .visible
        ) {
            Button(ref.isOwned ? "Löschen" : "Verlassen", role: .destructive) {
                let ref = ref
                Task {
                    let done: Void?
                    if ref.isOwned {
                        done = await model.run { try await $0.deleteCircle(ref) }
                    } else {
                        done = await model.run { try await $0.leave(ref) }
                    }
                    if done != nil {
                        await model.refresh()
                        dismiss()
                    }
                }
            }
        } message: {
            Text(ref.isOwned
                ? "Der Kreis liegt in deiner iCloud. Löschst du ihn, ist er für alle Mitglieder weg."
                : "Du kannst nur über eine neue Einladung zurückkommen.")
        }
    }

    private func load() async {
        let ref = ref
        if let loaded = await model.run({ try await $0.circle(ref) }) {
            details = loaded
        }
    }
}

private struct MemberRow: View {
    let member: CircleMember

    var body: some View {
        HStack(spacing: 12) {
            Avatar(name: member.name, id: member.id, size: 36)
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
                    if member.isPending {
                        Text("neu")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .accessibilityLabel("Neu beigetreten, noch nicht vom Besitzer bestätigt")
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
}
