import LeuchtturmCore
import SwiftUI
import UserNotifications

/// Shows notifications as banners while the app is open, too, and passes
/// on answers like "Mir geht's gut".
@MainActor
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    var onAction: ((String) -> Void)?

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        await MainActor.run { onAction?(action) }
    }
}

/// How a note reads in the news list and in notifications.
enum NoteText {
    static func body(_ note: CircleNote, members: [CircleMember], myID: String) -> String {
        switch note.kind {
        case .reaction:
            return "\(note.text) \(recipient(note, members: members, myID: myID))".trimmingCharacters(in: .whitespaces)
        case .text:
            return "„\(note.text)“ \(recipient(note, members: members, myID: myID))".trimmingCharacters(in: .whitespaces)
        case .checkIn:
            return String(localized: "hat eingecheckt 📍")
        case .morning:
            return String(localized: "hat den Tag begonnen ☀️")
        case .arrival:
            return String(localized: "ist bei „\(note.text)“ angekommen")
        case .departure:
            return String(localized: "hat „\(note.text)“ verlassen")
        case .sos:
            return note.text.isEmpty ? String(localized: "🆘 braucht Hilfe!") : String(localized: "🆘 braucht Hilfe: \(note.text)")
        case .safe:
            return String(localized: "✅ ist in Sicherheit")
        case .lowBattery:
            return String(localized: "hat nur noch \(note.text) % Akku 🪫")
        }
    }

    private static func recipient(_ note: CircleNote, members: [CircleMember], myID: String) -> String {
        guard let to = note.recipientID else { return "" }
        if to == myID { return String(localized: "an dich") }
        let name = members.first { $0.id == to }?.name ?? String(localized: "jemanden")
        return String(localized: "an \(name)")
    }
}

/// Latest notes of the circle, in the people drawer.
struct NewsSection: View {
    @Environment(AppModel.self) private var model
    let details: CircleDetails
    /// Shows a check-in's place on the map.
    let onShowPlace: (SharedLocation) -> Void

    var body: some View {
        if !details.notes.isEmpty {
            Section("Neuigkeiten") {
                ForEach(details.notes.prefix(5)) { note in
                    if let place = note.location {
                        Button { onShowPlace(place) } label: { row(note) }
                            .tint(.primary)
                    } else {
                        row(note)
                    }
                }
            }
        }
    }

    private func row(_ note: CircleNote) -> some View {
        let sender = details.members.first { $0.id == note.senderID }
        return HStack(spacing: 12) {
            Avatar(name: sender?.name, id: note.senderID, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(sender?.isMe == true ? String(localized: "Du") : sender?.name ?? String(localized: "Jemand")) \(NoteText.body(note, members: details.members, myID: model.client?.deviceID ?? ""))")
                    .font(.subheadline)
                    .lineLimit(2)
                Text(note.timestamp, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if note.location != nil {
                Image(systemName: "mappin.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel("Auf der Karte zeigen")
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Emoji reactions and quick notes for one person.
struct ReactionPicker: View {
    @Environment(AppModel.self) private var model
    let member: CircleMember
    let ref: CircleRef
    @State private var sent: String?

    static let emojis = ["👋", "❤️", "👍", "😂", "🙏", "🤗"]
    static let phrases = [
        "Bin auf dem Weg", "Komme etwas später", "Bin gut angekommen", "Ruf mich bitte an", "Alles okay bei dir?",
    ]

    var body: some View {
        Section {
            HStack {
                ForEach(Self.emojis, id: \.self) { emoji in
                    Button(emoji) { send(.reaction, emoji) }
                        .font(.title2)
                        .frame(maxWidth: .infinity)
                        .buttonStyle(.borderless)
                }
            }
            ForEach(Self.phrases, id: \.self) { phrase in
                Button(phrase) { send(.text, phrase) }
            }
        } header: {
            Text("An \(member.name ?? String(localized: "Mitglied")) senden")
        } footer: {
            if let sent {
                Label("„\(sent)“ gesendet", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
            } else {
                Text("Ende-zu-Ende-verschlüsselt. Alle im Leuchtturm können es lesen.")
            }
        }
        .sensoryFeedback(.success, trigger: sent)
    }

    private func send(_ kind: CircleNote.Kind, _ text: String) {
        Task {
            if await model.send(kind, text: text, to: member.id, in: ref) { sent = text }
        }
    }
}
