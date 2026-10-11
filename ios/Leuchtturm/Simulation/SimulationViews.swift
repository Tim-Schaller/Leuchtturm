#if DEBUG
import LeuchtturmCore
import SwiftUI

/// Controls for the made-up people.
struct SimulationView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Called with an invite from one of the people; shown after this sheet closes.
    let onInvite: (InviteLink) -> Void
    @State private var memberships: [String: [SimulatedWorld.Membership]] = [:]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Anna, Ben und Clara sind erfunden, rechnen aber mit echter Verschlüsselung wie ein zweites iPhone. Nichts geht an iCloud, deine echten Daten bleiben unberührt. Beendest du die App, ist alles weg.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let world = model.simulation, model.client != nil {
                    Section {
                        Button("Beispielkreis „Familie“ mit allen anlegen", systemImage: "person.3.fill") {
                            Task {
                                await model.createDemoCircle()
                                dismiss()
                            }
                        }
                    }

                    Section {
                        let me = model.client?.deviceID
                        Button("Anna schickt dir ❤️", systemImage: "heart") {
                            Task { await model.simulate { try await $0.send(.reaction, text: "❤️", from: world.people[0], to: me) } }
                        }
                        Button("Ben checkt ein", systemImage: "mappin.and.ellipse") {
                            Task { await model.simulate { try await $0.send(.checkIn, from: world.people[1]) } }
                        }
                        Button("Clara sagt Guten Morgen", systemImage: "sun.max") {
                            Task { await model.simulate { try await $0.send(.morning, from: world.people[2]) } }
                        }
                        Button("Anna: Blase an/aus", systemImage: "circle.dashed") {
                            Task {
                                await model.simulate { world in
                                    let anna = world.people[0].id
                                    if world.inBubble.remove(anna) == nil { world.inBubble.insert(anna) }
                                }
                            }
                        }
                    } header: {
                        Text("Nachrichten")
                    } footer: {
                        Text("Schickst du jemandem eine Reaktion, antwortet die Person kurz darauf.")
                    }

                    Section {
                        ForEach(world.people) { person in
                            Button("\(person.name) lädt dich ein", systemImage: "envelope") {
                                invite(from: person)
                            }
                        }
                    } header: {
                        Text("Einladungen")
                    } footer: {
                        Text("Die Person lädt dich in ihren eigenen Kreis ein. Damit jemand deinem Kreis beitritt: Kreis öffnen, „Jemanden einladen“, Einladung erstellen.")
                    }

                    ForEach(model.circles) { circle in
                        Section {
                            ForEach(memberships[circle.id] ?? []) { membership in
                                let name = membership.person.name
                                Button(
                                    membership.isOwner ? "\(name) löscht den Kreis" : "\(name) verlässt den Kreis",
                                    systemImage: membership.isOwner ? "trash" : "rectangle.portrait.and.arrow.right"
                                ) {
                                    Task { await model.simulate { try await $0.leave(membership.person, circleID: circle.id) } }
                                }
                            }
                            if circle.isOwner {
                                Button("Fremder öffnet den iCloud-Link", systemImage: "person.fill.questionmark") {
                                    Task { await model.simulate { try await $0.strangerOpensShareLink(of: circle.ref) } }
                                }
                            }
                        } header: {
                            Text(circle.name ?? "Unbekannter Kreis")
                        } footer: {
                            if circle.isOwner {
                                Text("Der Fremde hat den iCloud-Freigabelink, aber nicht den Schlüssel aus der Einladung. Er erscheint bei dir unter „Nicht bestätigt“ und sieht nur verschlüsselte Daten.")
                            }
                        }
                    }
                } else {
                    Section {
                        Text("Gib zuerst deinen Namen ein, dann geht es hier los.")
                    }
                }
            }
            .navigationTitle("Simulation")
            .navigationBarTitleDisplayMode(.inline)
            .errorAlert()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
            .task(id: model.externalChanges) {
                memberships = await model.simulation?.memberships() ?? [:]
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func invite(from person: SimulatedWorld.Person) {
        Task {
            if let link = await model.simulate({ try await $0.invitation(from: person) }) {
                onInvite(link)
                dismiss()
            }
        }
    }
}

/// In the invite sheet: lets a made-up person use the invite just created.
struct SimulatedRecipients: View {
    @Environment(AppModel.self) private var model
    let circleID: String
    let link: InviteLink
    @State private var candidates: [SimulatedWorld.Person]?

    var body: some View {
        Section {
            if let candidates {
                ForEach(candidates) { person in
                    Button("\(person.name) öffnet den Link", systemImage: "person.badge.plus") {
                        Task { await model.simulate { try await $0.join(person, using: link) } }
                    }
                }
                if candidates.isEmpty {
                    Text("Alle erfundenen Personen sind schon im Kreis.")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Simulation")
        } footer: {
            Text("Spielt durch, dass die Person diesen Link bekommt und damit beitritt.")
        }
        .task(id: model.externalChanges) {
            candidates = await model.simulation?.people(notIn: circleID)
        }
    }
}
#endif
