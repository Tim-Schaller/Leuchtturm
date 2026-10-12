import Foundation
import LeuchtturmCore
import UserNotifications

/// Friends added by friend code: each friendship is a hidden circle of two.
/// Codes and requests go through the public iCloud database (see Friends.swift
/// in LeuchtturmCore and docs/ARCHITECTURE.md).
extension AppModel {
    private static let setupAccount = "friend.setup.v1"
    private static let outgoingAccount = "friend.outgoing.v1"
    private static let handledAccount = "friend.handled.v1"

    /// Leuchttürme, without friendships.
    var leuchttuerme: [CircleSummary] { circles.filter { !$0.isFriendship } }
    var friendships: [CircleSummary] { circles.filter(\.isFriendship) }

    /// How a circle is called: a friendship by the friend's name.
    func title(of circle: CircleSummary) -> String {
        if circle.isFriendship {
            return latestDetails[circle.id]?.members.first { !$0.isMe }?.name ?? String(localized: "Freund")
        }
        return circle.name ?? String(localized: "Unbekannter Leuchtturm")
    }

    var publicDatabase: any PublicDatabase {
        #if DEBUG
        if let simulation { return simulation.publicDatabase }
        #endif
        return CloudKitPublicDatabase(containerIdentifier: AppInfo.cloudKitContainer)
    }

    func restoreFriends() {
        friendSetup = (try? secrets.load(Self.setupAccount)).flatMap { try? JSONDecoder().decode(FriendSetup.self, from: $0) }
        outgoingFriendRequests = (try? secrets.load(Self.outgoingAccount))
            .flatMap { try? JSONDecoder().decode([OutgoingFriendRequest].self, from: $0) } ?? []
        handledFriendRequests = (try? secrets.load(Self.handledAccount))
            .flatMap { try? JSONDecoder().decode(Set<String>.self, from: $0) } ?? []
        incomingFriendRequests = []
    }

    private func saveFriends() {
        if let friendSetup, let data = try? JSONEncoder().encode(friendSetup) { try? secrets.save(data, for: Self.setupAccount) }
        if let data = try? JSONEncoder().encode(outgoingFriendRequests) { try? secrets.save(data, for: Self.outgoingAccount) }
        if let data = try? JSONEncoder().encode(handledFriendRequests) { try? secrets.save(data, for: Self.handledAccount) }
    }

    /// Creates the friend code on first use and keeps the card's name current.
    func prepareFriendCode() async {
        let setup = friendSetup ?? FriendSetup.generate()
        let db = publicDatabase
        guard await run({ try await $0.publishFriendCard(setup, in: db) }) != nil else { return }
        friendSetup = setup
        saveFriends()
    }

    /// A new code; the old one stops working, open requests to it are lost.
    func newFriendCode() async {
        let db = publicDatabase
        if let old = friendSetup { await run { try await $0.withdrawFriendCard(old, in: db) } }
        friendSetup = nil
        await prepareFriendCode()
    }

    func lookUpFriend(_ code: FriendCode) async -> FriendCard? {
        if code == friendSetup?.friendCode {
            errorMessage = String(localized: "Das ist dein eigener Code.")
            return nil
        }
        let db = publicDatabase
        guard let card = await run({ try await $0.lookUpFriend(code, in: db) }) else { return nil }
        if card == nil { errorMessage = String(localized: "Zu diesem Code gibt es niemanden. Prüf ihn noch einmal.") }
        return card
    }

    func sendFriendRequest(to card: FriendCard) async -> Bool {
        let db = publicDatabase
        let tag = isSimulation ? nil : AppInfo.cloudTag
        guard let sent = await run({ try await $0.sendFriendRequest(to: card, tag: tag, in: db) }) else { return false }
        outgoingFriendRequests.append(sent)
        saveFriends()
        await refresh()
        await pushProfile(toCircle: sent.circleID)
        return true
    }

    /// New requests, and cleaning up sent ones. At most once a minute unless forced.
    func refreshFriendRequests(force: Bool = false) async {
        guard let client, force || Date().timeIntervalSince(lastFriendCheck) > 60 else { return }
        lastFriendCheck = Date()
        let db = publicDatabase
        if let setup = friendSetup, let incoming = try? await client.friendRequests(for: setup, in: db) {
            let fresh = incoming.filter { !handledFriendRequests.contains($0.id) }
            let new = fresh.filter { r in !incomingFriendRequests.contains { $0.id == r.id } }
            incomingFriendRequests = fresh
            if usesDeviceServices { for request in new { notify(request) } }
        }
        if !outgoingFriendRequests.isEmpty, let waiting = try? await client.tidyFriendRequests(outgoingFriendRequests, in: db),
           waiting != outgoingFriendRequests {
            outgoingFriendRequests = waiting
            saveFriends()
            await refresh()
            await checkForNews()
        }
    }

    func accept(_ request: IncomingFriendRequest) async {
        if !isSimulation, let link = InviteLink(url: request.request.invite), let env = link.environment, env != AppInfo.cloudTag {
            _ = await join(link) // shows why it cannot work
            return
        }
        guard let ref = await run({ try await $0.accept(request) }) else { return }
        handledFriendRequests.insert(request.id)
        incomingFriendRequests.removeAll { $0.id == request.id }
        saveFriends()
        await pushProfile(to: ref)
        await shareLocationNow()
        await refresh()
        await checkForNews()
    }

    func decline(_ request: IncomingFriendRequest) {
        handledFriendRequests.insert(request.id)
        incomingFriendRequests.removeAll { $0.id == request.id }
        saveFriends()
    }

    func withdraw(_ request: OutgoingFriendRequest) async {
        let db = publicDatabase
        guard await run({ try await $0.withdraw(request, in: db) }) != nil else { return }
        outgoingFriendRequests.removeAll { $0.id == request.id }
        saveFriends()
        await refresh()
    }

    /// Ends a friendship for both: the creator deletes it, the other leaves.
    func endFriendship(_ circle: CircleSummary) async {
        if circle.ref.isOwned {
            await run { try await $0.deleteCircle(circle.ref) }
        } else {
            await run { try await $0.leave(circle.ref) }
        }
        await refresh()
    }

    private func pushProfile(toCircle circleID: String) async {
        if let ref = circles.first(where: { $0.id == circleID })?.ref { await pushProfile(to: ref) }
        else if let ref = try? await client?.circles().first(where: { $0.id == circleID })?.ref { await pushProfile(to: ref) }
    }

    private func notify(_ request: IncomingFriendRequest) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Freundschaftsanfrage")
        content.body = String(localized: "\(request.request.name) möchte mit dir befreundet sein.")
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: request.id, content: content, trigger: nil))
    }
}
