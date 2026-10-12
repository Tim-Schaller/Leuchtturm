import LeuchtturmCore
import SwiftUI

/// On a member's page, for the owner: make admin, hand over.
struct RoleSection: View {
    @Environment(AppModel.self) private var model
    let member: CircleMember
    let ref: CircleRef
    @State private var confirmHandover = false

    var body: some View {
        if model.latestCircle(ref.circleID)?.isOwner == true {
            Section {
                Toggle("Admin", isOn: Binding(
                    get: { member.isAdmin },
                    set: { on in
                        let (id, ref) = (member.id, ref)
                        Task {
                            await model.run { try await $0.setAdmin(id, on, in: ref) }
                            model.noteRemoteChange()
                        }
                    }
                ))
                Button("Leuchtturm an \(member.name ?? String(localized: "Mitglied")) übergeben", systemImage: "crown") {
                    confirmHandover = true
                }
            } header: {
                Text("Rolle")
            } footer: {
                Text("Admins können Leute einladen, Entfernen und Umbenennen beantragen und den Leuchtturm übernehmen, wenn du drei Tage nicht aktiv warst.")
            }
            .confirmationDialog("Leuchtturm übergeben?", isPresented: $confirmHandover, titleVisibility: .visible) {
                Button("Übergeben") {
                    let (id, ref) = (member.id, ref)
                    Task {
                        await model.run { try await $0.offerOwnership(to: id, in: ref) }
                        model.noteRemoteChange()
                    }
                }
            } message: {
                Text("\(member.name ?? String(localized: "Die Person")) wird Admin und kann den Leuchtturm übernehmen. Dann ziehen alle in einen neuen Leuchtturm um, den sie besitzt; du bleibst Admin.")
            }
        }
    }
}

/// In the drawer, for admins who may take over.
struct TakeOverSection: View {
    @Environment(AppModel.self) private var model
    let details: CircleDetails
    let onTakenOver: (CircleRef) -> Void
    @State private var working = false

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    details.handoverOffered
                        ? "\(owner) möchte dir den Leuchtturm übergeben."
                        : "\(owner) war seit drei Tagen nicht aktiv.",
                    systemImage: "crown"
                )
                .font(.headline)
                Text("Übernimmst du, ziehen alle mit Orten und Rollen in einen neuen Leuchtturm in deiner iCloud um. Die anderen folgen automatisch.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button {
                working = true
                let ref = details.ref
                Task {
                    if let newRef = await model.takeOver(ref) { onTakenOver(newRef) }
                    working = false
                }
            } label: {
                if working { ProgressView() } else { Text("Leuchtturm übernehmen") }
            }
            .disabled(working)
        }
    }

    private var owner: String {
        details.members.first { $0.isOwner }?.name ?? String(localized: "Der Besitzer")
    }
}
