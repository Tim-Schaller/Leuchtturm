import LeuchtturmCore
import SwiftUI
import UIKit

/// One person across all your Leuchttürme and friendships.
struct Friend: Identifiable {
    let member: CircleMember
    /// Leuchttürme you share with them: (circle ID, name).
    let circles: [(id: String, name: String)]
    /// The friendship with them, if added by friend code.
    let friendship: CircleSummary?
    var id: String { member.id }
}

extension AppModel {
    /// Everyone in your Leuchttürme and friendships, once each, with the newest position.
    var friends: [Friend] {
        var byID: [String: (member: CircleMember, circles: [(id: String, name: String)], friendship: CircleSummary?)] = [:]
        for details in latestCircles {
            let friendship = details.isFriendship ? circles.first { $0.id == details.id } : nil
            for member in details.members where !member.isMe && !member.isPending {
                var entry = byID[member.id] ?? (member, [], nil)
                if let friendship {
                    entry.friendship = friendship
                } else {
                    entry.circles.append((details.id, details.name ?? String(localized: "Leuchtturm")))
                }
                if (member.location?.timestamp ?? .distantPast) > (entry.member.location?.timestamp ?? .distantPast) { entry.member = member }
                byID[member.id] = entry
            }
        }
        return byID.values.map { Friend(member: $0.member, circles: $0.circles, friendship: $0.friendship) }
            .sorted { ($0.member.name ?? "~").localizedCaseInsensitiveCompare($1.member.name ?? "~") == .orderedAscending }
    }
}

/// Your friend code, adding friends by code, requests and everyone you know.
struct FriendsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Opens the person on the map.
    let onOpen: (Friend) -> Void

    @State private var codeText = ""
    @State private var found: FriendCard?
    @State private var searching = false
    @State private var sending = false
    @State private var showQR = false
    @State private var confirmNewCode = false
    @State private var ending: Friend?
    @State private var copied = false

    var body: some View {
        NavigationStack {
            List {
                codeSection
                addSection
                if !model.incomingFriendRequests.isEmpty { incomingSection }
                if !model.outgoingFriendRequests.isEmpty { outgoingSection }
                friendsSection
            }
            .navigationTitle("Freunde")
            .navigationBarTitleDisplayMode(.inline)
            .errorAlert()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("Neuen Code erstellen", systemImage: "arrow.triangle.2.circlepath") { confirmNewCode = true }
                    } label: {
                        Label("Mehr", systemImage: "ellipsis")
                    }
                }
            }
            .refreshable {
                await model.refreshFriendRequests(force: true)
                await model.checkForNews()
            }
            .task {
                if model.friendSetup == nil { await model.prepareFriendCode() }
                if let pending = model.pendingFriendCode {
                    model.pendingFriendCode = nil
                    codeText = pending.description
                    await search()
                }
                await model.refreshFriendRequests(force: true)
                await model.checkForNews()
            }
            .sheet(isPresented: $showQR) { FriendCodeQR() }
            .confirmationDialog("Neuen Freundescode erstellen?", isPresented: $confirmNewCode, titleVisibility: .visible) {
                Button("Neuer Code") { Task { await model.newFriendCode() } }
            } message: {
                Text("Der alte Code funktioniert dann nicht mehr. Deine Freunde bleiben.")
            }
            .confirmationDialog("Freundschaft beenden?", isPresented: Binding(get: { ending != nil }, set: { if !$0 { ending = nil } }),
                                titleVisibility: .visible, presenting: ending) { friend in
                Button("Beenden", role: .destructive) {
                    if let friendship = friend.friendship { Task { await model.endFriendship(friendship) } }
                }
            } message: { friend in
                Text("Ihr seht euch dann nicht mehr, auch euer Chat ist weg. In gemeinsamen Leuchttürmen bleibt \(friend.member.name ?? String(localized: "die Person")).")
            }
        }
    }

    // MARK: Sections

    private var codeSection: some View {
        Section {
            if let code = model.friendSetup?.friendCode {
                VStack(spacing: 12) {
                    Text(code.description)
                        .font(.title.monospaced().weight(.semibold))
                        .textSelection(.enabled)
                        .accessibilityLabel("Dein Freundescode \(code.description.map(String.init).joined(separator: " "))")
                    HStack(spacing: 10) {
                        CodeAction(title: copied ? "Kopiert" : "Kopieren", symbol: copied ? "checkmark" : "doc.on.doc") {
                            UIPasteboard.general.string = code.description
                            copied = true
                        }
                        ShareLink(item: code.url, message: Text("Füge mich in Leuchtturm hinzu: \(code.description)")) {
                            CodeActionLabel(title: "Teilen", symbol: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)
                        CodeAction(title: "QR-Code", symbol: "qrcode") { showQR = true }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            } else {
                HStack {
                    ProgressView()
                    Text("Code wird erstellt …").foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Dein Freundescode")
        } footer: {
            Text("Wer deinen Code hat, kann dir eine Anfrage schicken. Nimmst du sie an, seht ihr euch gegenseitig auf der Karte und könnt chatten, Ende-zu-Ende-verschlüsselt.")
        }
    }

    private var addSection: some View {
        Section("Freund hinzufügen") {
            HStack {
                TextField("Code eingeben", text: $codeText)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                    .submitLabel(.search)
                    .onSubmit { Task { await search() } }
                    .onChange(of: codeText) { found = nil }
                if searching {
                    ProgressView()
                } else {
                    Button("Suchen") { Task { await search() } }
                        .disabled(FriendCode(codeText) == nil)
                }
            }
            if let found {
                HStack(spacing: 12) {
                    Avatar(name: found.name, id: found.mailbox, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(found.name).font(.headline)
                        Text("Sicherheitscode \(found.safetyCode)").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(sending ? "Sendet …" : "Anfrage senden") {
                        Task {
                            sending = true
                            if await model.sendFriendRequest(to: found) {
                                self.found = nil
                                codeText = ""
                            }
                            sending = false
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(sending)
                }
            }
        }
    }

    private var incomingSection: some View {
        Section {
            ForEach(model.incomingFriendRequests) { incoming in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Avatar(name: incoming.request.name, id: incoming.id, size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(incoming.request.name).font(.headline)
                            Text("Sicherheitscode \(incoming.request.safetyCode)").font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Button("Annehmen") { Task { await model.accept(incoming) } }
                            .buttonStyle(.borderedProminent)
                        Button("Ablehnen", role: .destructive) { model.decline(incoming) }
                            .buttonStyle(.bordered)
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("Anfragen")
        } footer: {
            Text("Nimm nur Anfragen von Leuten an, die du kennst: Ihr teilt dann euren Standort miteinander. Den Sicherheitscode könnt ihr vergleichen, wenn ihr euch seht.")
        }
    }

    private var outgoingSection: some View {
        Section("Gesendet") {
            ForEach(model.outgoingFriendRequests) { request in
                LabeledContent {
                    Text("wartet").foregroundStyle(.secondary)
                } label: {
                    Label(request.name, systemImage: "paperplane")
                }
                .swipeActions {
                    Button("Zurückziehen", role: .destructive) { Task { await model.withdraw(request) } }
                }
            }
        }
    }

    private var friendsSection: some View {
        Section {
            let friends = model.friends
            if friends.isEmpty {
                Text("Noch keine Freunde. Schick jemandem deinen Code oder lade Leute in einen Leuchtturm ein.")
                    .foregroundStyle(.secondary)
            }
            ForEach(friends) { friend in
                Button {
                    onOpen(friend)
                    dismiss()
                } label: {
                    FriendRow(friend: friend)
                }
                .tint(.primary)
                .swipeActions {
                    if friend.friendship != nil {
                        Button("Beenden", role: .destructive) { ending = friend }
                    }
                }
            }
        } header: {
            Text("Freunde")
        }
    }

    private func search() async {
        guard let code = FriendCode(codeText) else { return }
        searching = true
        found = await model.lookUpFriend(code)
        searching = false
    }
}

/// A small button with the icon above its title.
private struct CodeAction: View {
    let title: LocalizedStringResource
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { CodeActionLabel(title: title, symbol: symbol) }
            .buttonStyle(.bordered)
    }
}

private struct CodeActionLabel: View {
    let title: LocalizedStringResource
    let symbol: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.title3)
            Text(title).font(.caption).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
    }
}

private struct FriendRow: View {
    @Environment(AppModel.self) private var model
    let friend: Friend

    var body: some View {
        HStack(spacing: 12) {
            Avatar(name: friend.member.name, id: friend.id, size: 48)
                .environment(\.memberProfiles, friend.member.profile.map { [friend.id: $0] } ?? [:])
            VStack(alignment: .leading, spacing: 3) {
                Text(friend.member.name ?? String(localized: "Unbekannt")).font(.headline)
                if let status = friend.member.profile?.status(at: Date()) {
                    Text([status.emoji, status.text].compactMap { $0 }.joined(separator: " ")).font(.subheadline)
                }
                Text(LocationStatus.text(for: friend.member, model: model))
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                Text(places)
                    .font(.caption).foregroundStyle(.tint).lineLimit(1)
            }
        }
    }

    private var places: String {
        var parts: [String] = []
        if friend.friendship != nil { parts.append(String(localized: "Freund")) }
        parts += friend.circles.map(\.name)
        return parts.joined(separator: " · ")
    }
}

/// The friend code as a QR code, for scanning with the camera.
private struct FriendCodeQR: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let code = model.friendSetup?.friendCode, let image = QRCode.image(for: code.url.absoluteString) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 260)
                        .padding(20)
                        .background(.white, in: .rect(cornerRadius: 24))
                        .accessibilityLabel("QR-Code mit deinem Freundescode")
                    Text(code.description).font(.title2.monospaced().weight(.semibold))
                    Text("Mit der Kamera scannen, dann öffnet sich Leuchtturm mit deinem Code.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
            .padding()
            .navigationTitle("Freundescode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}
