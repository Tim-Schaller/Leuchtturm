import LeuchtturmCore
import SwiftUI

/// One person across all your Leuchttürme.
struct Friend: Identifiable {
    let member: CircleMember
    /// Leuchttürme you share with them: (circle ID, name).
    let circles: [(id: String, name: String)]
    var id: String { member.id }
}

extension AppModel {
    /// Everyone in your Leuchttürme, once each, with the newest position.
    var friends: [Friend] {
        var byID: [String: (member: CircleMember, circles: [(id: String, name: String)])] = [:]
        for details in latestCircles {
            for member in details.members where !member.isMe && !member.isPending {
                let name = details.name ?? String(localized: "Leuchtturm")
                if var entry = byID[member.id] {
                    entry.circles.append((details.id, name))
                    if (member.location?.timestamp ?? .distantPast) > (entry.member.location?.timestamp ?? .distantPast) { entry.member = member }
                    byID[member.id] = entry
                } else {
                    byID[member.id] = (member, [(details.id, name)])
                }
            }
        }
        return byID.values.map { Friend(member: $0.member, circles: $0.circles) }
            .sorted { ($0.member.name ?? "~").localizedCaseInsensitiveCompare($1.member.name ?? "~") == .orderedAscending }
    }
}

struct FriendsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Opens the person in one of their Leuchttürme.
    let onOpen: (Friend) -> Void

    var body: some View {
        NavigationStack {
            List {
                let friends = model.friends
                if friends.isEmpty {
                    ContentUnavailableView("Noch keine Freunde", systemImage: "person.2",
                                           description: Text("Lade Leute in einen Leuchtturm ein, dann erscheinen sie hier."))
                }
                ForEach(friends) { friend in
                    Button {
                        onOpen(friend)
                        dismiss()
                    } label: {
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
                                Text(friend.circles.map(\.name).joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.tint).lineLimit(1)
                            }
                        }
                    }
                    .tint(.primary)
                }
            }
            .navigationTitle("Freunde")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
            .task { await model.checkForNews() }
        }
    }
}
