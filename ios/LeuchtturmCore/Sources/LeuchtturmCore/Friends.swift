import Foundation

/// The device's friend code and the mailbox its requests go to. Kept with
/// the keys; a new code (after a reset) gets a new mailbox.
public struct FriendSetup: Sendable, Equatable, Codable {
    public let code: String
    public let mailbox: String

    public var friendCode: FriendCode? { FriendCode(code) }

    public static func generate() -> FriendSetup {
        FriendSetup(code: FriendCode.generate().value, mailbox: CircleCrypto.newCircleID())
    }
}

/// A request someone sent this device.
public struct IncomingFriendRequest: Sendable, Equatable, Identifiable {
    /// Record name in the public database.
    public let id: String
    public let request: FriendRequest
}

/// A request this device sent; remembered until the friend joined.
public struct OutgoingFriendRequest: Sendable, Equatable, Codable, Identifiable {
    /// Record name in the public database.
    public let id: String
    public let name: String
    public let circleID: String
    public let sent: Date
}

enum FriendRecord {
    static let card = "FriendCode"
    static let request = "FriendRequest"
}

extension LeuchtturmClient {
    /// Publishes (or refreshes) the card behind the device's friend code.
    public func publishFriendCard(_ setup: FriendSetup, in db: any PublicDatabase) async throws {
        guard let code = setup.friendCode else { throw ProtocolError.malformed }
        let card = FriendCard(
            mailbox: setup.mailbox, name: try Self.validated(currentDisplayName ?? ""),
            agreementKey: identity.agreementPublicKey, signingKey: identity.signingPublicKey
        )
        try await db.save(StoredRecord(type: FriendRecord.card, name: code.recordName, fields: [
            "blob": .bytes(try CircleCrypto.sealFriendCard(card, code: code)),
        ]))
    }

    /// Removes the card, e.g. before a new code. Requests to the old mailbox are then ignored.
    public func withdrawFriendCard(_ setup: FriendSetup, in db: any PublicDatabase) async throws {
        guard let code = setup.friendCode else { return }
        try await db.delete(code.recordName)
    }

    /// The person behind a code, or nil if nobody has it.
    public func lookUpFriend(_ code: FriendCode, in db: any PublicDatabase) async throws -> FriendCard? {
        guard let record = try await db.fetch(code.recordName) else { return nil }
        return try CircleCrypto.openFriendCard(record.bytes("blob"), code: code)
    }

    /// Starts a friendship: a circle of two with an invite for the other
    /// person, sent encrypted to their device. `tag` marks the iCloud
    /// environment in the invite (see `InviteLink.environment`).
    public func sendFriendRequest(to card: FriendCard, tag: String? = nil, in db: any PublicDatabase) async throws -> OutgoingFriendRequest {
        guard card.signingKey != identity.signingPublicKey else { throw ClientError.invalidName }
        let ref = try await createCircle(name: card.name, isFriendship: true)
        var invite = try await createInvite(for: ref, validFor: Int64(FriendRequest.lifetime))
        invite.environment = tag
        let request = FriendRequest(
            name: try Self.validated(currentDisplayName ?? ""), invite: invite.url,
            agreementKey: identity.agreementPublicKey, signingKey: identity.signingPublicKey, timestamp: now()
        )
        let id = "fr-" + CircleCrypto.newCircleID()
        try await db.save(StoredRecord(type: FriendRecord.request, name: id, fields: [
            "to": .string(card.mailbox), "blob": .bytes(try CircleCrypto.sealFriendRequest(request, to: card)),
        ]))
        return OutgoingFriendRequest(id: id, name: card.name, circleID: ref.circleID, sent: now())
    }

    /// Requests to this device's mailbox that can be opened and are recent.
    public func friendRequests(for setup: FriendSetup, in db: any PublicDatabase) async throws -> [IncomingFriendRequest] {
        let cutoff = now().addingTimeInterval(-FriendRequest.lifetime)
        return try await db.query(type: FriendRecord.request, field: "to", equals: setup.mailbox).compactMap { record in
            guard let request = try? CircleCrypto.openFriendRequest(record.bytes("blob"), mailbox: setup.mailbox, recipient: identity),
                  request.timestamp > cutoff, request.signingKey != identity.signingPublicKey
            else { return nil }
            return IncomingFriendRequest(id: record.name, request: request)
        }
        .sorted { $0.request.timestamp > $1.request.timestamp }
    }

    /// Joins the friendship the request invites to.
    public func accept(_ incoming: IncomingFriendRequest) async throws -> CircleRef {
        guard let link = InviteLink(url: incoming.request.invite) else { throw ProtocolError.malformed }
        return try await join(link)
    }

    /// Deletes requests whose friend has joined (or that ran out, together
    /// with their empty friendship) and returns the ones still waiting.
    public func tidyFriendRequests(_ outgoing: [OutgoingFriendRequest], in db: any PublicDatabase) async throws -> [OutgoingFriendRequest] {
        let refs = try await backend.listCircles()
        var waiting: [OutgoingFriendRequest] = []
        for request in outgoing {
            guard let ref = refs.first(where: { $0.circleID == request.circleID }) else {
                try? await db.delete(request.id)
                continue
            }
            let details = try? await circle(ref)
            let joined = details?.members.contains { !$0.isMe } ?? false
            if joined {
                try? await db.delete(request.id)
            } else if now().timeIntervalSince(request.sent) > FriendRequest.lifetime {
                try? await db.delete(request.id)
                try? await deleteCircle(ref)
            } else {
                waiting.append(request)
            }
        }
        return waiting
    }

    /// Takes a request back and deletes the friendship it started.
    public func withdraw(_ request: OutgoingFriendRequest, in db: any PublicDatabase) async throws {
        try await db.delete(request.id)
        if let ref = try await backend.listCircles().first(where: { $0.circleID == request.circleID }) {
            try await deleteCircle(ref)
        }
    }
}
