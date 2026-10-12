#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// A circle as shown in the circle list.
public struct CircleSummary: Sendable, Identifiable, Hashable {
    public var id: String { ref.circleID }
    public let ref: CircleRef
    /// nil if the name cannot be decrypted (yet).
    public let name: String?
    public let isOwner: Bool
    /// When a temporary circle ends.
    public var expiresAt: Date? = nil
    /// A friendship (two people, added by friend code), not a Leuchtturm.
    public var isFriendship = false
}

/// A member device, decrypted where possible.
public struct CircleMember: Sendable, Identifiable, Hashable {
    /// Device ID.
    public let id: String
    /// Backend (iCloud) user that wrote the record; used to remove the member.
    public let userID: String?
    public let name: String?
    public let isOwner: Bool
    public let isMe: Bool
    /// Joined with a valid invite, not yet confirmed by the owner's device.
    public let isPending: Bool
    /// Compare in person to detect key substitution.
    public let safetyCode: String
    /// Latest verified position; nil if none is shared (or not yet admitted).
    public let location: SharedLocation?
    public var isAdmin = false
    /// Picture, pin and status, if the member set them.
    public var profile: Profile? = nil

    public init(
        id: String, userID: String?, name: String?, isOwner: Bool, isMe: Bool, isPending: Bool, safetyCode: String,
        location: SharedLocation?, isAdmin: Bool = false, profile: Profile? = nil
    ) {
        self.id = id
        self.userID = userID
        self.name = name
        self.isOwner = isOwner
        self.isMe = isMe
        self.isPending = isPending
        self.safetyCode = safetyCode
        self.location = location
        self.isAdmin = isAdmin
        self.profile = profile
    }
}

public struct CircleDetails: Sendable, Identifiable, Hashable {
    public var id: String { ref.circleID }
    public let ref: CircleRef
    public let name: String?
    public let epoch: Int64
    public let isOwner: Bool
    /// False until this device has the circle key (e.g. waiting for the owner).
    public let hasKey: Bool
    public let members: [CircleMember]
    /// Owner only: iCloud participants without a valid membership, e.g.
    /// someone who obtained the share link but not the invite secret.
    public let unverifiedUserIDs: [String]
    /// Reactions, notes and check-ins of the last 7 days, newest first.
    public let notes: [CircleNote]
    /// Places of the circle, by name.
    public let places: [CirclePlace]
    /// When a temporary circle ends.
    public var expiresAt: Date? = nil
    /// A friendship, not a Leuchtturm.
    public var isFriendship = false
    /// This device is an admin.
    public var isAdmin = false
    /// The owner's last sign of life (position or message), if known.
    public var ownerLastSeen: Date? = nil
    /// The owner offered this circle to this device.
    public var handoverOffered = false
    /// This device may take the circle over now.
    public var canTakeOver = false
    /// Chat of the last 30 days, oldest first (reactions included).
    public var messages: [ChatMessage] = []
}

public enum ClientError: Error, Sendable, Equatable {
    /// No usable key for the circle's current epoch on this device.
    case missingCircleKey
    case notOwner
    case unknownMember
    case invalidName
    case invalidDuration
    case inviteInvalid
    case inviteExpired
    /// This device has no trust anchor for the circle (e.g. after reinstalling).
    case untrustedCircle
    /// The circle record is missing or not signed by the owner.
    case tampered
    /// Owners cannot leave; they delete the circle instead.
    case ownerMustDelete
    /// A note is too long.
    case invalidNote
    /// A place has no name, a bad emoji or an unsupported radius.
    case invalidPlace
    /// Only admins can do this.
    case notAdmin
    /// Taking over is only possible for admins once the owner was away for
    /// three days, or after the owner offered it.
    case takeoverNotAllowed
    /// A picture is too large, or a colour or status is not valid.
    case invalidProfile
}

enum RecordType {
    static let circle = "Circle"
    static let member = "Member"
    static let keyWrap = "KeyWrap"
    static let invite = "Invite"
    static let location = "Location"
    static let note = "Note"
    static let place = "Place"
    static let history = "History"
    static let trip = "Trip"
    static let move = "Move"
    static let profile = "Profile"
    static let message = "Message"
}

enum RecordName {
    static let circle = "circle"
    static func wrap(epoch: Int64, deviceID: String) -> String { "wrap-\(epoch)-\(deviceID)" }
    static func invite(_ id: String) -> String { "invite-\(id)" }
    static let invitePrefix = "invite-"
    static func location(_ deviceID: String) -> String { "loc-\(deviceID)" }
    static let locationPrefix = "loc-"
    static func note(_ id: String) -> String { "note-\(id)" }
    static let notePrefix = "note-"
    static func place(_ id: String) -> String { "place-\(id)" }
    static let placePrefix = "place-"
    static func history(_ deviceID: String, _ day: String) -> String { "hist-\(deviceID)-\(day)" }
    static func trip(_ id: String) -> String { "trip-\(id)" }
    static let tripPrefix = "trip-"
    static func move(_ signer: String) -> String { "move-\(signer)" }
    static func profile(_ deviceID: String) -> String { "profile-\(deviceID)" }
    static let profilePrefix = "profile-"
    static func message(_ id: String) -> String { "msg-\(id)" }
    static let messagePrefix = "msg-"
}

/// High-level client. Everything is encrypted or signed here, before it
/// reaches the backend (iCloud).
public actor LeuchtturmClient {
    public nonisolated let identity: DeviceIdentity
    let backend: any CircleBackend
    private let secrets: any SecretStore
    let now: @Sendable () -> Date
    private var displayName: String?
    var currentDisplayName: String? { displayName }
    /// Newest location seen per circle and device, so a replayed older
    /// record cannot move someone back in time.
    private var newestLocations: [String: SharedLocation] = [:]

    public static let maxNameLength = 40
    public static let inviteDurations: ClosedRange<Int64> = 60 ... 7 * 24 * 3600

    public init(
        backend: any CircleBackend, secrets: any SecretStore, displayName: String? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        identity = try DeviceIdentity.loadOrCreate(in: secrets)
        self.backend = backend
        self.secrets = secrets
        self.displayName = displayName
        self.now = now
    }

    public nonisolated var deviceID: String { identity.deviceID }

    public nonisolated var safetyCode: String {
        DeviceID.safetyCode(signingPublicKey: identity.signingPublicKey, agreementPublicKey: identity.agreementPublicKey)
    }

    /// Checks that the backend is usable (iCloud signed in).
    public func start() async throws {
        _ = try await backend.currentUserID()
    }

    /// Silent pushes for changes in any circle; see `CircleBackend.subscribeToChanges`.
    public func subscribeToChanges() async throws {
        try await backend.subscribeToChanges()
    }

    /// Sets the name shown to others and updates it in every circle.
    public func setDisplayName(_ name: String) async throws {
        displayName = try Self.validated(name)
        for ref in try await backend.listCircles() {
            _ = try? await load(ref, forceCardUpdate: true)
        }
    }

    // MARK: Circles

    /// Creates a circle; with `expiresAt` it ends by itself at that time.
    public func createCircle(name: String, expiresAt: Date? = nil, isFriendship: Bool = false) async throws -> CircleRef {
        let circleName = try Self.validated(name)
        let myName = try Self.validated(displayName ?? "")
        let circleID = CircleCrypto.newCircleID()
        let key = CircleCrypto.newCircleKey()
        try storeOwner(circleID, signingKey: identity.signingPublicKey, agreementKey: identity.agreementPublicKey)
        try storeKey(key, circleID: circleID, epoch: 1)
        let records = [
            try circleRecord(circleID, epoch: 1, meta: CircleMeta(
                name: circleName, members: [deviceID], expires: expiresAt.map { Int64($0.timeIntervalSince1970) },
                kind: isFriendship ? CircleMeta.friendKind : nil
            ), key: key),
            try memberRecord(circleID, epoch: 1, key: key, name: myName, admission: nil),
        ]
        return try await backend.createCircle(id: circleID, records: records)
    }

    public func circles() async throws -> [CircleSummary] {
        var out: [CircleSummary] = []
        var moved = false
        for ref in try await backend.listCircles() {
            var name: String?
            var isOwner = false
            var expiresAt: Date?
            var isFriendship = false
            if let snapshot = try? await backend.snapshot(of: ref), let p = try? parse(snapshot) {
                _ = ensureKey(p)
                let meta = (try? CircleCrypto.openCircleMeta(p.metaBlob, circleID: p.circleID, keyForEpoch: keyLookup(p.circleID)))?.meta
                name = meta?.name
                isOwner = p.ownerDeviceID == deviceID
                expiresAt = meta?.expires.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                isFriendship = meta?.isFriendship ?? false
                // A temporary circle that ended: the owner deletes it, the others leave.
                if let expiresAt, expiresAt <= now() {
                    if ref.isOwned { try? await deleteCircle(ref) } else { try? await leave(ref) }
                    continue
                }
                // Someone took it over: follow to the new one.
                if let movedAt = movedAt(ref.circleID) {
                    if now().timeIntervalSince(movedAt) >= Self.moveGrace { try? await deleteCircle(ref) }
                    continue
                }
                if let meta = openMeta(p), await followMove(ref, p, meta: meta) {
                    moved = true
                    continue
                }
            }
            out.append(CircleSummary(ref: ref, name: name, isOwner: isOwner, expiresAt: expiresAt, isFriendship: isFriendship))
        }
        // Followed a move: list again, now with the new circle.
        if moved { return try await circles() }
        return out.sorted { ($0.name ?? "~").localizedCaseInsensitiveCompare($1.name ?? "~") == .orderedAscending }
    }

    public func circle(_ ref: CircleRef) async throws -> CircleDetails {
        let details = try await load(ref)
        guard details.isOwner, ref.isOwned, try await carryOutAdminRequests(ref) else { return details }
        return try await load(ref)
    }

    public func rename(_ ref: CircleRef, to name: String) async throws {
        let name = try Self.validated(name)
        let p = try parse(try await backend.snapshot(of: ref))
        guard p.ownerDeviceID == deviceID else { throw ClientError.notOwner }
        guard let key = ensureKey(p),
              let meta = (try? CircleCrypto.openCircleMeta(p.metaBlob, circleID: p.circleID, keyForEpoch: keyLookup(p.circleID)))?.meta
        else { throw ClientError.missingCircleKey }
        let record = try circleRecord(p.circleID, epoch: p.epoch, meta: CircleMeta(name: name, members: meta.members, expires: meta.expires, admins: meta.admins, kind: meta.kind), key: key)
        try await backend.modify(ref, save: [record], delete: [], removeParticipants: [])
    }

    /// Leaves a circle you do not own. Your location, history and trips go with you.
    public func leave(_ ref: CircleRef) async throws {
        guard !ref.isOwned else { throw ClientError.ownerMustDelete }
        let history = (try? await backend.snapshot(of: ref))?.records
            .filter { [RecordType.history, RecordType.trip, RecordType.message].contains($0.type) && $0.string("from") == deviceID }.map(\.name) ?? []
        try? await backend.modify(ref, save: [], delete: [RecordName.location(deviceID), RecordName.profile(deviceID)] + history, removeParticipants: [])
        try await backend.leave(ref)
        try? secrets.deleteAll(prefix: Self.prefix(ref.circleID))
    }

    /// Deletes a circle you own, for everyone.
    public func deleteCircle(_ ref: CircleRef) async throws {
        guard ref.isOwned else { throw ClientError.notOwner }
        try await backend.deleteCircle(ref)
        try? secrets.deleteAll(prefix: Self.prefix(ref.circleID))
    }

    /// Removes a user (all of their devices) and rotates the circle key, so
    /// they cannot read anything shared afterwards. Owner only.
    public func remove(userID: String, from ref: CircleRef) async throws {
        let snapshot = try await backend.snapshot(of: ref)
        let p = try parse(snapshot)
        guard ref.isOwned, p.ownerDeviceID == deviceID else { throw ClientError.notOwner }
        guard userID != ref.ownerUserID, snapshot.participants.contains(where: { $0.userID == userID }) else {
            throw ClientError.unknownMember
        }
        guard ensureKey(p) != nil,
              let meta = (try? CircleCrypto.openCircleMeta(p.metaBlob, circleID: p.circleID, keyForEpoch: keyLookup(p.circleID)))?.meta
        else { throw ClientError.missingCircleKey }

        let remaining = Set(snapshot.participants.filter { !$0.isOwner && $0.userID != userID }.map(\.userID))
        var roster = Set(meta.members)
        var delete = Set<String>()
        for m in p.members.values where m.deviceID != p.ownerDeviceID {
            if let creator = m.creator, !remaining.contains(creator) {
                roster.remove(m.deviceID)
                delete.insert(m.deviceID)
            } else if hasValidInvite(m, p) {
                roster.insert(m.deviceID)
            }
        }
        roster.insert(p.ownerDeviceID)

        let newEpoch = p.epoch + 1
        let newKey = CircleCrypto.newCircleKey()
        var save = [try circleRecord(p.circleID, epoch: newEpoch, meta: CircleMeta(
            name: meta.name, members: roster.sorted(), expires: meta.expires, admins: meta.admins?.filter(roster.contains), kind: meta.kind
        ), key: newKey)]
        for id in roster.sorted() where id != deviceID {
            guard let m = p.members[id] else { continue }
            let blob = try CircleCrypto.wrap(
                circleKey: newKey, circleID: p.circleID, epoch: newEpoch,
                recipientDeviceID: id, recipientAgreementKey: m.agreementKey, sender: identity
            )
            save.append(StoredRecord(type: RecordType.keyWrap, name: RecordName.wrap(epoch: newEpoch, deviceID: id), fields: [
                "epoch": .int(newEpoch), "device": .string(id), "blob": .bytes(blob),
            ]))
        }
        // Old wraps and all invites go: invites carry the old key.
        for r in snapshot.records where r.type == RecordType.keyWrap || r.type == RecordType.invite || r.creatorUserID == userID {
            delete.insert(r.name)
        }
        delete.remove(RecordName.circle)

        try storeKey(newKey, circleID: p.circleID, epoch: newEpoch)
        try await backend.modify(ref, save: save, delete: delete.sorted(), removeParticipants: [userID])
        // Re-encrypt my own card under the new key.
        _ = try? await load(ref)
    }

    // MARK: Chat

    /// Sends a chat message, reply, picture or sticker; deletes own messages
    /// older than 30 days on the way.
    @discardableResult
    public func sendMessage(
        _ text: String, replyTo: String? = nil, reactsTo: String? = nil, image: Data? = nil, isSticker: Bool = false,
        in ref: CircleRef
    ) async throws -> ChatMessage {
        let message = ChatMessage(
            id: CircleCrypto.newCircleID(), senderID: deviceID, text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            replyTo: replyTo, reactsTo: reactsTo, image: image, isSticker: isSticker, timestamp: now()
        )
        guard message.isValid else { throw ClientError.invalidNote }
        let p = try parse(try await backend.snapshot(of: ref))
        guard let key = ensureKey(p) else { throw ClientError.missingCircleKey }
        let sealed = try CircleCrypto.sealMessage(message, key: key, epoch: p.epoch, circleID: p.circleID)
        let sig = try identity.sign(CircleCrypto.messageRecordStatement(
            circleID: p.circleID, id: message.id, senderID: deviceID, blob: sealed.blob, image: sealed.image
        ))
        let record = StoredRecord(type: RecordType.message, name: RecordName.message(message.id), fields: [
            "from": .string(deviceID), "blob": .bytes(sealed.blob), "image": .bytes(sealed.image), "sig": .bytes(sig),
        ])
        let cutoff = now().addingTimeInterval(-ChatMessage.lifetime)
        let expired = p.messages.filter { r in
            guard r.string("from") == deviceID else { return false }
            guard let mine = try? openMessageRecord(r, p) else { return true }
            return mine.timestamp < cutoff
        }.map(\.name)
        try await backend.modify(ref, save: [record], delete: expired, removeParticipants: [])
        return message
    }

    /// Deletes one of this device's messages (and reactions to nothing else).
    public func deleteMessage(_ id: String, in ref: CircleRef) async throws {
        let p = try parse(try await backend.snapshot(of: ref))
        guard p.messages.contains(where: { $0.name == RecordName.message(id) && $0.string("from") == deviceID }) else {
            throw ClientError.unknownMember
        }
        try await backend.modify(ref, save: [], delete: [RecordName.message(id)], removeParticipants: [])
    }

    nonisolated func openMessageRecord(_ r: StoredRecord, _ p: Parsed) throws -> ChatMessage? {
        try CircleCrypto.openMessage(
            blob: r.bytes("blob"), image: r.bytes("image"), id: String(r.name.dropFirst(RecordName.messagePrefix.count)),
            senderID: r.string("from"), circleID: p.circleID, keyForEpoch: keyLookup(p.circleID)
        )
    }

    nonisolated func verifiedMessages(_ p: Parsed, roster: Set<String>) -> [ChatMessage] {
        let cutoff = now().addingTimeInterval(-ChatMessage.lifetime)
        return p.messages.compactMap { r -> ChatMessage? in
            let sender = r.string("from")
            let id = String(r.name.dropFirst(RecordName.messagePrefix.count))
            guard let m = p.members[sender], roster.contains(sender) || sender == deviceID,
                  CircleCrypto.verifySignature(
                      r.bytes("sig"), publicKey: m.signingKey,
                      message: CircleCrypto.messageRecordStatement(circleID: p.circleID, id: id, senderID: sender, blob: r.bytes("blob"), image: r.bytes("image"))
                  ),
                  let message = try? openMessageRecord(r, p), message.timestamp > cutoff
            else { return nil }
            return message
        }
        .sorted { ($0.timestamp, $0.id) < ($1.timestamp, $1.id) }
    }

    // MARK: Profile

    /// Writes this device's profile to all circles (or the given ones).
    public func setProfile(_ profile: Profile, in refs: [CircleRef]? = nil) async throws {
        guard profile.isValid else { throw ClientError.invalidProfile }
        let targets: [CircleRef]
        if let refs { targets = refs } else { targets = try await backend.listCircles() }
        for ref in targets {
            let p = try parse(try await backend.snapshot(of: ref))
            guard let key = ensureKey(p) else { continue }
            try await backend.modify(ref, save: [try profileRecord(profile, circleID: p.circleID, epoch: p.epoch, key: key)], delete: [], removeParticipants: [])
        }
    }

    private nonisolated func profileRecord(_ profile: Profile, circleID: String, epoch: Int64, key: SymmetricKey) throws -> StoredRecord {
        let sealed = try CircleCrypto.sealProfile(profile, key: key, epoch: epoch, circleID: circleID, deviceID: deviceID)
        let sig = try identity.sign(CircleCrypto.profileRecordStatement(circleID: circleID, deviceID: deviceID, sealed: sealed))
        return StoredRecord(type: RecordType.profile, name: RecordName.profile(deviceID), fields: [
            "blob": .bytes(sealed.blob), "photo": .bytes(sealed.photo), "banner": .bytes(sealed.banner), "sig": .bytes(sig),
        ])
    }

    /// A member's profile, signed by that member's device.
    nonisolated func verifiedProfile(_ deviceID: String, _ p: Parsed) -> Profile? {
        guard let r = p.profiles[deviceID], let m = p.members[deviceID] else { return nil }
        let sealed = SealedProfile(blob: r.bytes("blob"), photo: r.bytes("photo"), banner: r.bytes("banner"))
        guard CircleCrypto.verifySignature(
            r.bytes("sig"), publicKey: m.signingKey,
            message: CircleCrypto.profileRecordStatement(circleID: p.circleID, deviceID: deviceID, sealed: sealed)
        ) else { return nil }
        return try? CircleCrypto.openProfile(sealed, circleID: p.circleID, deviceID: deviceID, keyForEpoch: keyLookup(p.circleID))
    }

    // MARK: Roles and takeover

    /// How long the owner must be away before an admin may take over, and
    /// how long the old owner keeps a circle that moved before deleting it.
    public static let takeoverAfter: TimeInterval = 3 * 86400
    static let moveGrace: TimeInterval = 3 * 86400

    nonisolated func openMeta(_ p: Parsed) -> CircleMeta? {
        (try? CircleCrypto.openCircleMeta(p.metaBlob, circleID: p.circleID, keyForEpoch: keyLookup(p.circleID)))?.meta
    }

    /// Owner only: makes a member an admin, or a member again.
    public func setAdmin(_ memberID: String, _ isAdmin: Bool, in ref: CircleRef) async throws {
        let p = try parse(try await backend.snapshot(of: ref))
        guard ref.isOwned, p.ownerDeviceID == deviceID else { throw ClientError.notOwner }
        guard let key = ensureKey(p), var meta = openMeta(p) else { throw ClientError.missingCircleKey }
        guard meta.members.contains(memberID), memberID != deviceID else { throw ClientError.unknownMember }
        var admins = Set(meta.admins ?? [])
        if isAdmin { admins.insert(memberID) } else { admins.remove(memberID) }
        meta.admins = admins.sorted()
        try await backend.modify(ref, save: [try circleRecord(p.circleID, epoch: p.epoch, meta: meta, key: key)], delete: [], removeParticipants: [])
    }

    /// Owner only: offers the circle to a member, who becomes an admin and
    /// can take it over right away.
    public func offerOwnership(to memberID: String, in ref: CircleRef) async throws {
        try await setAdmin(memberID, true, in: ref)
        try await send(.handoverOffer, to: memberID, in: ref)
    }

    /// Admins: asks the owner's device to remove a member (not the owner or
    /// another admin). It does so, with a new key, when it next opens the circle.
    public func requestRemoval(of memberID: String, in ref: CircleRef) async throws {
        let p = try parse(try await backend.snapshot(of: ref))
        guard let meta = openMeta(p), (meta.admins ?? []).contains(deviceID) else { throw ClientError.notAdmin }
        guard memberID != p.ownerDeviceID, !(meta.admins ?? []).contains(memberID), p.members[memberID] != nil else {
            throw ClientError.unknownMember
        }
        try await send(.removeRequest, text: memberID, to: p.ownerDeviceID, in: ref)
    }

    /// Admins: asks the owner's device to rename the circle.
    public func requestRename(_ ref: CircleRef, to name: String) async throws {
        let name = try Self.validated(name)
        let p = try parse(try await backend.snapshot(of: ref))
        guard let meta = openMeta(p), (meta.admins ?? []).contains(deviceID) else { throw ClientError.notAdmin }
        try await send(.renameRequest, text: name, to: p.ownerDeviceID, in: ref)
    }

    /// The owner's device: carries out what admins asked for, then deletes
    /// the requests. Returns true if there were any.
    private func carryOutAdminRequests(_ ref: CircleRef) async throws -> Bool {
        let p = try parse(try await backend.snapshot(of: ref))
        guard let meta = openMeta(p) else { return false }
        let admins = Set(meta.admins ?? [])
        let requests = verifiedNotes(p, roster: Set(meta.members))
            .filter { admins.contains($0.senderID) && ($0.kind == .removeRequest || $0.kind == .renameRequest) }
            .sorted { $0.timestamp < $1.timestamp }
        guard !requests.isEmpty else { return false }
        try? await backend.modify(ref, save: [], delete: requests.map { RecordName.note($0.id) }, removeParticipants: [])
        for request in requests {
            switch request.kind {
            case .renameRequest:
                try? await rename(ref, to: request.text)
            case .removeRequest:
                let target = request.text
                guard target != p.ownerDeviceID, !admins.contains(target), let userID = p.members[target]?.creator else { continue }
                try? await remove(userID: userID, from: ref)
            default:
                break
            }
        }
        return true
    }

    /// The owner's last sign of life: their position or newest message.
    nonisolated func ownerLastSeen(_ p: Parsed, notes: [CircleNote]) -> Date? {
        var seen = notes.filter { $0.senderID == p.ownerDeviceID }.map(\.timestamp)
        if let owner = p.members[p.ownerDeviceID], let record = p.locations[owner.deviceID],
           CircleCrypto.verifySignature(
               record.bytes("sig"), publicKey: owner.signingKey,
               message: CircleCrypto.locationRecordStatement(circleID: p.circleID, deviceID: owner.deviceID, blob: record.bytes("blob"))
           ),
           let (location, _) = try? CircleCrypto.openLocation(record.bytes("blob"), circleID: p.circleID, deviceID: owner.deviceID, keyForEpoch: keyLookup(p.circleID)) {
            seen.append(location.timestamp)
        }
        return seen.max()
    }

    /// Starts a new circle with everyone in it, owned by this device, and
    /// leaves a signed move notice in the old one so the others follow.
    /// Allowed for admins once the owner was away for three days, or right
    /// away after the owner offered it.
    @discardableResult
    public func takeOver(_ ref: CircleRef) async throws -> CircleRef {
        let p = try parse(try await backend.snapshot(of: ref))
        guard let key = ensureKey(p), let meta = openMeta(p) else { throw ClientError.missingCircleKey }
        guard p.ownerDeviceID != deviceID, (meta.admins ?? []).contains(deviceID) else { throw ClientError.takeoverNotAllowed }
        let notes = verifiedNotes(p, roster: Set(meta.members))
        let offered = notes.contains { $0.kind == .handoverOffer && $0.senderID == p.ownerDeviceID && $0.recipientID == deviceID }
        let away = ownerLastSeen(p, notes: notes).map { now().timeIntervalSince($0) >= Self.takeoverAfter } ?? true
        guard offered || away else { throw ClientError.takeoverNotAllowed }
        let myName = try Self.validated(displayName ?? "")

        // The new circle: same name, people, roles and places.
        let newID = CircleCrypto.newCircleID()
        let newKey = CircleCrypto.newCircleKey()
        let roster = Set(meta.members).union([p.ownerDeviceID, deviceID]).filter { p.members[$0] != nil || $0 == deviceID }
        let admins = Set(meta.admins ?? []).subtracting([deviceID]).union([p.ownerDeviceID]).intersection(roster)
        try storeOwner(newID, signingKey: identity.signingPublicKey, agreementKey: identity.agreementPublicKey)
        try storeKey(newKey, circleID: newID, epoch: 1)
        var records = [
            try circleRecord(newID, epoch: 1, meta: CircleMeta(name: meta.name, members: roster.sorted(), expires: meta.expires, admins: admins.sorted(), kind: meta.kind), key: newKey),
            try memberRecord(newID, epoch: 1, key: newKey, name: myName, admission: nil),
        ]
        for id in roster.sorted() where id != deviceID {
            guard let m = p.members[id] else { continue }
            let blob = try CircleCrypto.wrap(
                circleKey: newKey, circleID: newID, epoch: 1, recipientDeviceID: id, recipientAgreementKey: m.agreementKey, sender: identity
            )
            records.append(StoredRecord(type: RecordType.keyWrap, name: RecordName.wrap(epoch: 1, deviceID: id), fields: [
                "epoch": .int(1), "device": .string(id), "blob": .bytes(blob),
            ]))
        }
        for (place, _) in verifiedPlaces(p, roster: roster) {
            guard let copy = CirclePlace(
                id: CircleCrypto.newCircleID(), creatorID: deviceID, name: place.name, emoji: place.emoji,
                latitude: place.latitude, longitude: place.longitude, radius: place.radius
            ) else { continue }
            records.append(try placeRecord(copy, circleID: newID, epoch: 1, key: newKey))
        }
        let newRef = try await backend.createCircle(id: newID, records: records)
        let url = try await backend.inviteURL(for: newRef)

        let notice = MoveNotice(
            newCircleID: newID, shareURL: url, ownerSigningKey: identity.signingPublicKey,
            ownerAgreementKey: identity.agreementPublicKey, timestamp: now()
        )
        let blob = try CircleCrypto.sealMove(notice, key: key, epoch: p.epoch, circleID: p.circleID, signer: deviceID)
        let sig = try identity.sign(CircleCrypto.moveRecordStatement(circleID: p.circleID, signer: deviceID, blob: blob))
        try await backend.modify(ref, save: [StoredRecord(type: RecordType.move, name: RecordName.move(deviceID), fields: [
            "from": .string(deviceID), "blob": .bytes(blob), "sig": .bytes(sig),
        ])], delete: [], removeParticipants: [])
        // The notice stays in the old circle for the others; this device leaves it.
        try? await leave(ref)
        _ = try? await send(.tookOver, in: newRef)
        return newRef
    }

    /// The move notice to follow: signed by an admin with that admin's own
    /// keys. The earliest one wins if two admins took over at once.
    nonisolated func validMove(_ p: Parsed, meta: CircleMeta) -> MoveNotice? {
        let admins = Set(meta.admins ?? [])
        let candidates = p.moves.compactMap { r -> (MoveNotice, String)? in
            let signer = r.string("from")
            guard admins.contains(signer), signer != p.ownerDeviceID, r.name == RecordName.move(signer), let m = p.members[signer],
                  CircleCrypto.verifySignature(
                      r.bytes("sig"), publicKey: m.signingKey,
                      message: CircleCrypto.moveRecordStatement(circleID: p.circleID, signer: signer, blob: r.bytes("blob"))
                  ),
                  let move = try? CircleCrypto.openMove(r.bytes("blob"), circleID: p.circleID, signer: signer, keyForEpoch: keyLookup(p.circleID)),
                  move.ownerSigningKey == m.signingKey, move.ownerAgreementKey == m.agreementKey,
                  move.newCircleID != p.circleID
            else { return nil }
            return (move, signer)
        }
        return candidates.min { ($0.0.timestamp, $0.1) < ($1.0.timestamp, $1.1) }?.0
    }

    /// Joins the new circle of a valid move notice and trusts its new owner;
    /// leaves the old one (the old owner deletes theirs a few days later).
    private func followMove(_ ref: CircleRef, _ p: Parsed, meta: CircleMeta) async -> Bool {
        guard let move = validMove(p, meta: meta) else { return false }
        if let pinned = loadOwner(move.newCircleID), pinned != (move.ownerSigningKey, move.ownerAgreementKey) { return false }
        let already = (try? await backend.listCircles())?.contains { $0.circleID == move.newCircleID } ?? false
        if !already {
            guard let newRef = try? await backend.accept(inviteURL: move.shareURL) else { return false }
            guard newRef.circleID == move.newCircleID else {
                if !newRef.isOwned { try? await backend.leave(newRef) }
                return false
            }
            do {
                try storeOwner(move.newCircleID, signingKey: move.ownerSigningKey, agreementKey: move.ownerAgreementKey)
            } catch {
                return false
            }
            _ = try? await load(newRef)
        }
        if ref.isOwned {
            try? secrets.save(Data(String(Int64(now().timeIntervalSince1970)).utf8), for: Self.prefix(ref.circleID) + "moved")
        } else {
            try? await leave(ref)
        }
        return true
    }

    nonisolated func movedAt(_ circleID: String) -> Date? {
        guard let data = try? secrets.load(Self.prefix(circleID) + "moved"), let seconds = Int64(String(decoding: data, as: UTF8.self)) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    // MARK: Invites

    /// Creates an invite link. Share it privately: whoever has it can join.
    public func createInvite(for ref: CircleRef, validFor seconds: Int64 = 24 * 3600) async throws -> InviteLink {
        guard Self.inviteDurations.contains(seconds) else { throw ClientError.invalidDuration }
        let p = try parse(try await backend.snapshot(of: ref))
        guard let key = ensureKey(p) else { throw ClientError.missingCircleKey }
        let inviteID = CircleCrypto.newCircleID()
        let secret = randomBytes(32)
        let keys = CircleCrypto.inviteKeys(secret: secret)
        let expires = Int64(now().timeIntervalSince1970) + seconds
        let payload = InvitePayload(
            epoch: p.epoch, expiresAt: expires, circleKeyData: key.rawData,
            ownerSigningKey: p.ownerSigningKey, ownerAgreementKey: p.ownerAgreementKey
        )
        let record = StoredRecord(type: RecordType.invite, name: RecordName.invite(inviteID), fields: [
            "epoch": .int(p.epoch),
            "sealed": .bytes(try CircleCrypto.sealInvitePayload(payload, circleID: p.circleID, inviteID: inviteID, keys: keys)),
            "token": .bytes(try CircleCrypto.sealInviteToken(keys.authToken, key: key, epoch: p.epoch, circleID: p.circleID, inviteID: inviteID)),
            "expires": .int(expires),
        ])
        try await backend.modify(ref, save: [record], delete: [], removeParticipants: [])
        let url = try await backend.inviteURL(for: ref)
        return InviteLink(shareURL: url, inviteID: inviteID, secret: secret)
    }

    /// Joins the circle behind an invite link.
    public func join(_ link: InviteLink) async throws -> CircleRef {
        let before = Set(try await backend.listCircles().map(\.circleID))
        let ref = try await backend.accept(inviteURL: link.shareURL)
        do {
            let snapshot = try await backend.snapshot(of: ref)
            guard let record = snapshot.records.first(where: { $0.type == RecordType.invite && $0.name == RecordName.invite(link.inviteID) })
            else { throw ClientError.inviteInvalid }
            let keys = CircleCrypto.inviteKeys(secret: link.secret)
            guard let payload = try? CircleCrypto.openInvitePayload(record.bytes("sealed"), circleID: ref.circleID, inviteID: link.inviteID, keys: keys)
            else { throw ClientError.inviteInvalid }
            guard payload.expiresAt > Int64(now().timeIntervalSince1970) else { throw ClientError.inviteExpired }
            if let pinned = loadOwner(ref.circleID), pinned != (payload.ownerSigningKey, payload.ownerAgreementKey) {
                throw ClientError.untrustedCircle
            }
            try storeOwner(ref.circleID, signingKey: payload.ownerSigningKey, agreementKey: payload.ownerAgreementKey)
            try storeKey(payload.circleKey, circleID: ref.circleID, epoch: payload.epoch)
            let proof = CircleCrypto.admissionProof(
                authToken: keys.authToken, circleID: ref.circleID, deviceID: deviceID,
                signingKey: identity.signingPublicKey, agreementKey: identity.agreementPublicKey
            )
            try storeAdmission(ref.circleID, Admission(inviteID: link.inviteID, proof: proof))
        } catch {
            // Undo the iCloud join, unless we were a member already.
            if !ref.isOwned, !before.contains(ref.circleID) { try? await backend.leave(ref) }
            throw error
        }
        _ = try? await load(ref)
        return ref
    }

    // MARK: Location

    /// Shares this device's position with every circle it has a key for,
    /// and today's history if it is on (deleting days past the retention).
    /// Tries all circles and throws the first error afterwards.
    public func shareLocation(_ location: SharedLocation, history: HistoryUpdate? = nil) async throws {
        var firstError: (any Error)?
        for ref in try await backend.listCircles() {
            do {
                let p = try parse(try await backend.snapshot(of: ref))
                guard let key = ensureKey(p) else { throw ClientError.missingCircleKey }
                let blob = try CircleCrypto.sealLocation(location, key: key, epoch: p.epoch, circleID: p.circleID, deviceID: deviceID)
                let sig = try identity.sign(CircleCrypto.locationRecordStatement(circleID: p.circleID, deviceID: deviceID, blob: blob))
                var save = [StoredRecord(type: RecordType.location, name: RecordName.location(deviceID), fields: [
                    "blob": .bytes(blob), "sig": .bytes(sig),
                ])]
                var delete: [String] = []
                if let history {
                    save.append(try historyRecord(history.today, circleID: p.circleID, epoch: p.epoch, key: key))
                    let oldest = HistoryDay.dayKey(for: now().addingTimeInterval(-Double(history.keepDays - 1) * 86400))
                    delete = p.history.filter { $0.string("from") == deviceID && $0.string("day") < oldest }.map(\.name)
                }
                try await backend.modify(ref, save: save, delete: delete, removeParticipants: [])
                newestLocations[Self.locationKey(p.circleID, deviceID)] = location
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
    }

    /// Removes this device's position from every circle.
    public func stopSharingLocation() async throws {
        for ref in try await backend.listCircles() {
            try await backend.modify(ref, save: [], delete: [RecordName.location(deviceID)], removeParticipants: [])
            newestLocations[Self.locationKey(ref.circleID, deviceID)] = nil
        }
    }

    static func locationKey(_ circleID: String, _ deviceID: String) -> String { "\(circleID)/\(deviceID)" }

    // MARK: History

    /// Deletes this device's whole history from every circle.
    public func deleteHistory() async throws {
        for ref in try await backend.listCircles() {
            let p = try parse(try await backend.snapshot(of: ref))
            let mine = p.history.filter { $0.string("from") == deviceID }.map(\.name)
            if !mine.isEmpty { try await backend.modify(ref, save: [], delete: mine, removeParticipants: []) }
        }
    }

    /// The history a member shares in a circle, newest day first. Only from
    /// admitted members (or this device), with a valid signature.
    public func history(of memberID: String, in ref: CircleRef) async throws -> [HistoryDay] {
        let p = try parse(try await backend.snapshot(of: ref))
        _ = ensureKey(p)
        guard let m = p.members[memberID] else { return [] }
        if memberID != deviceID {
            let meta = try? CircleCrypto.openCircleMeta(p.metaBlob, circleID: p.circleID, keyForEpoch: keyLookup(p.circleID))
            guard meta?.meta.members.contains(memberID) == true || memberID == p.ownerDeviceID else { return [] }
        }
        return p.history.compactMap { r -> HistoryDay? in
            let day = r.string("day")
            guard r.string("from") == memberID, HistoryDay.isDayKey(day), r.name == RecordName.history(memberID, day),
                  CircleCrypto.verifySignature(
                      r.bytes("sig"), publicKey: m.signingKey,
                      message: CircleCrypto.historyRecordStatement(circleID: p.circleID, deviceID: memberID, day: day, blob: r.bytes("blob"))
                  )
            else { return nil }
            return try? CircleCrypto.openHistory(r.bytes("blob"), deviceID: memberID, day: day, circleID: p.circleID, keyForEpoch: keyLookup(p.circleID))
        }
        .sorted { $0.day > $1.day }
    }

    private nonisolated func historyRecord(_ day: HistoryDay, circleID: String, epoch: Int64, key: SymmetricKey) throws -> StoredRecord {
        let blob = try CircleCrypto.sealHistory(day, key: key, epoch: epoch, circleID: circleID)
        let sig = try identity.sign(CircleCrypto.historyRecordStatement(circleID: circleID, deviceID: deviceID, day: day.day, blob: blob))
        return StoredRecord(type: RecordType.history, name: RecordName.history(deviceID, day.day), fields: [
            "from": .string(deviceID), "day": .string(day.day), "blob": .bytes(blob), "sig": .bytes(sig),
        ])
    }

    /// Verifies and decrypts a member's location record. Records that are
    /// unsigned, signed by someone else or older than one seen before are
    /// ignored. A deleted record means the member stopped sharing.
    private func verifiedLocation(of m: Member, _ p: Parsed) -> SharedLocation? {
        let cacheKey = Self.locationKey(p.circleID, m.deviceID)
        guard let record = p.locations[m.deviceID] else {
            newestLocations[cacheKey] = nil
            return nil
        }
        let cached = newestLocations[cacheKey]
        guard CircleCrypto.verifySignature(
                  record.bytes("sig"), publicKey: m.signingKey,
                  message: CircleCrypto.locationRecordStatement(circleID: p.circleID, deviceID: m.deviceID, blob: record.bytes("blob"))
              ),
              let (location, _) = try? CircleCrypto.openLocation(record.bytes("blob"), circleID: p.circleID, deviceID: m.deviceID, keyForEpoch: keyLookup(p.circleID))
        else { return cached }
        if let cached, cached.timestamp > location.timestamp { return cached }
        newestLocations[cacheKey] = location
        return location
    }

    // MARK: Notes

    /// Sends a reaction, quick note, check-in or good-morning to a circle,
    /// optionally addressed to one member. Cleans up own notes older than two days.
    @discardableResult
    public func send(
        _ kind: CircleNote.Kind, text: String = "", to recipientID: String? = nil,
        location: SharedLocation? = nil, deadline: Date? = nil, in ref: CircleRef
    ) async throws -> CircleNote {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= CircleNote.maxTextLength else { throw ClientError.invalidNote }
        let p = try parse(try await backend.snapshot(of: ref))
        guard let key = ensureKey(p) else { throw ClientError.missingCircleKey }
        let timestamp = Date(timeIntervalSince1970: now().timeIntervalSince1970.rounded(.down))
        let note = CircleNote(
            id: CircleCrypto.newCircleID(), senderID: deviceID, recipientID: recipientID, kind: kind, text: text,
            // A check-in carries only the place, stamped with the note's time.
            location: location.flatMap {
                SharedLocation(latitude: $0.latitude, longitude: $0.longitude, accuracy: $0.accuracy, timestamp: timestamp)
            },
            timestamp: timestamp,
            deadline: deadline.map { Date(timeIntervalSince1970: $0.timeIntervalSince1970.rounded(.down)) }
        )
        let blob = try CircleCrypto.sealNote(note, key: key, epoch: p.epoch, circleID: p.circleID)
        let sig = try identity.sign(CircleCrypto.noteRecordStatement(circleID: p.circleID, noteID: note.id, senderID: deviceID, blob: blob))
        let record = StoredRecord(type: RecordType.note, name: RecordName.note(note.id), fields: [
            "from": .string(deviceID), "blob": .bytes(blob), "sig": .bytes(sig),
        ])
        let expired = p.notes.compactMap { r -> String? in
            guard r.string("from") == deviceID else { return nil }
            guard let mine = try? openNote(r, p) else { return r.name }
            return mine.timestamp < now().addingTimeInterval(-2 * 24 * 3600) ? r.name : nil
        }
        try await backend.modify(ref, save: [record], delete: expired, removeParticipants: [])
        return note
    }

    nonisolated func openNote(_ r: StoredRecord, _ p: Parsed) throws -> CircleNote? {
        try CircleCrypto.openNote(
            r.bytes("blob"), id: String(r.name.dropFirst(RecordName.notePrefix.count)), senderID: r.string("from"),
            circleID: p.circleID, keyForEpoch: keyLookup(p.circleID)
        )
    }

    /// Notes from admitted members (and this device) with a valid signature,
    /// newer than `CircleNote.lifetime`.
    nonisolated func verifiedNotes(_ p: Parsed, roster: Set<String>) -> [CircleNote] {
        let cutoff = now().addingTimeInterval(-CircleNote.lifetime)
        var notes: [CircleNote] = []
        for r in p.notes {
            let sender = r.string("from")
            let noteID = String(r.name.dropFirst(RecordName.notePrefix.count))
            guard let m = p.members[sender], roster.contains(sender) || sender == deviceID,
                  CircleCrypto.verifySignature(
                      r.bytes("sig"), publicKey: m.signingKey,
                      message: CircleCrypto.noteRecordStatement(circleID: p.circleID, noteID: noteID, senderID: sender, blob: r.bytes("blob"))
                  ),
                  let note = try? openNote(r, p), note.timestamp > cutoff
            else { continue }
            notes.append(note)
        }
        return notes.sorted { $0.timestamp > $1.timestamp }
    }

    // MARK: Places

    @discardableResult
    public func addPlace(
        name: String, emoji: String, latitude: Double, longitude: Double, radius: Int, in ref: CircleRef
    ) async throws -> CirclePlace {
        guard let place = CirclePlace(
            id: CircleCrypto.newCircleID(), creatorID: deviceID, name: name, emoji: emoji,
            latitude: latitude, longitude: longitude, radius: radius
        ) else { throw ClientError.invalidPlace }
        let p = try parse(try await backend.snapshot(of: ref))
        guard let key = ensureKey(p) else { throw ClientError.missingCircleKey }
        try await backend.modify(ref, save: [try placeRecord(place, circleID: p.circleID, epoch: p.epoch, key: key)], delete: [], removeParticipants: [])
        return place
    }

    /// Deletes a place. The app offers this to its creator and the owner;
    /// iCloud cannot enforce that (any member can delete records).
    public func deletePlace(_ id: String, in ref: CircleRef) async throws {
        try await backend.modify(ref, save: [], delete: [RecordName.place(id)], removeParticipants: [])
    }

    private nonisolated func placeRecord(_ place: CirclePlace, circleID: String, epoch: Int64, key: SymmetricKey) throws -> StoredRecord {
        let blob = try CircleCrypto.sealPlace(place, key: key, epoch: epoch, circleID: circleID)
        let sig = try identity.sign(CircleCrypto.placeRecordStatement(circleID: circleID, placeID: place.id, creatorID: deviceID, blob: blob))
        return StoredRecord(type: RecordType.place, name: RecordName.place(place.id), fields: [
            "from": .string(deviceID), "blob": .bytes(blob), "sig": .bytes(sig),
        ])
    }

    /// Places created by admitted members (or this device) with a valid signature.
    private nonisolated func verifiedPlaces(_ p: Parsed, roster: Set<String>) -> [(place: CirclePlace, record: StoredRecord)] {
        p.places.compactMap { r in
            let creator = r.string("from")
            let id = String(r.name.dropFirst(RecordName.placePrefix.count))
            guard let m = p.members[creator], roster.contains(creator) || creator == deviceID,
                  CircleCrypto.verifySignature(
                      r.bytes("sig"), publicKey: m.signingKey,
                      message: CircleCrypto.placeRecordStatement(circleID: p.circleID, placeID: id, creatorID: creator, blob: r.bytes("blob"))
                  ),
                  let place = try? CircleCrypto.openPlace(r.bytes("blob"), id: id, creatorID: creator, circleID: p.circleID, keyForEpoch: keyLookup(p.circleID))
            else { return nil }
            return (place, r)
        }
    }

    // MARK: Trips

    /// Shares a finished trip with every circle and deletes this device's
    /// trips that ended more than `keepDays` days ago.
    public func shareTrip(_ trip: Trip, keepDays: Int = 30) async throws {
        let cutoff = now().addingTimeInterval(-Double(keepDays) * 86400)
        for ref in try await backend.listCircles() {
            let p = try parse(try await backend.snapshot(of: ref))
            guard let key = ensureKey(p) else { continue }
            let blob = try CircleCrypto.sealTrip(trip, key: key, epoch: p.epoch, circleID: p.circleID)
            let sig = try identity.sign(CircleCrypto.tripRecordStatement(circleID: p.circleID, tripID: trip.id, deviceID: deviceID, blob: blob))
            let record = StoredRecord(type: RecordType.trip, name: RecordName.trip(trip.id), fields: [
                "from": .string(deviceID), "blob": .bytes(blob), "sig": .bytes(sig),
            ])
            let expired = p.trips.filter { r in
                guard r.string("from") == deviceID else { return false }
                guard let mine = try? openTrip(r, p) else { return true }
                return mine.end < cutoff
            }.map(\.name)
            try await backend.modify(ref, save: [record], delete: expired, removeParticipants: [])
        }
    }

    /// Deletes one of this device's trips everywhere, e.g. when the member
    /// was only a passenger.
    public func deleteTrip(_ id: String) async throws {
        for ref in try await backend.listCircles() {
            let p = try parse(try await backend.snapshot(of: ref))
            if p.trips.contains(where: { $0.name == RecordName.trip(id) && $0.string("from") == deviceID }) {
                try await backend.modify(ref, save: [], delete: [RecordName.trip(id)], removeParticipants: [])
            }
        }
    }

    /// Deletes all of this device's trips from every circle.
    public func deleteTrips() async throws {
        for ref in try await backend.listCircles() {
            let p = try parse(try await backend.snapshot(of: ref))
            let mine = p.trips.filter { $0.string("from") == deviceID }.map(\.name)
            if !mine.isEmpty { try await backend.modify(ref, save: [], delete: mine, removeParticipants: []) }
        }
    }

    /// Trips of admitted members (and this device) that ended after `since`,
    /// newest first.
    public func trips(in ref: CircleRef, since: Date) async throws -> [Trip] {
        let p = try parse(try await backend.snapshot(of: ref))
        _ = ensureKey(p)
        let meta = try? CircleCrypto.openCircleMeta(p.metaBlob, circleID: p.circleID, keyForEpoch: keyLookup(p.circleID))
        let roster = Set(meta?.meta.members ?? []).union([p.ownerDeviceID, deviceID])
        return p.trips.compactMap { r -> Trip? in
            let from = r.string("from")
            let id = String(r.name.dropFirst(RecordName.tripPrefix.count))
            guard roster.contains(from), let m = p.members[from],
                  CircleCrypto.verifySignature(
                      r.bytes("sig"), publicKey: m.signingKey,
                      message: CircleCrypto.tripRecordStatement(circleID: p.circleID, tripID: id, deviceID: from, blob: r.bytes("blob"))
                  ),
                  let trip = try? openTrip(r, p), trip.end > since
            else { return nil }
            return trip
        }
        .sorted { $0.end > $1.end }
    }

    nonisolated func openTrip(_ r: StoredRecord, _ p: Parsed) throws -> Trip? {
        try CircleCrypto.openTrip(
            r.bytes("blob"), id: String(r.name.dropFirst(RecordName.tripPrefix.count)), deviceID: r.string("from"),
            circleID: p.circleID, keyForEpoch: keyLookup(p.circleID)
        )
    }

    // MARK: Account

    /// Deletes owned circles, leaves all others and wipes local keys.
    public func deleteAllData() async throws {
        for ref in try await backend.listCircles() {
            if ref.isOwned {
                try await backend.deleteCircle(ref)
            } else {
                try? await backend.modify(ref, save: [], delete: [RecordName.location(deviceID)], removeParticipants: [])
                try await backend.leave(ref)
            }
        }
        for account in try secrets.accounts() {
            try secrets.delete(account)
        }
    }

    // MARK: Loading and verification

    struct Member {
        let deviceID: String
        let signingKey: Data
        let agreementKey: Data
        let card: Data
        let inviteID: String
        let proof: Data
        let creator: String?
    }

    struct Parsed {
        let snapshot: CircleSnapshot
        let ownerSigningKey: Data
        let ownerAgreementKey: Data
        let epoch: Int64
        let metaBlob: Data
        /// Members with a valid self-signature, by device ID.
        let members: [String: Member]
        let invites: [String: StoredRecord]
        /// Location records by device ID (not verified yet).
        let locations: [String: StoredRecord]
        /// Note records (not verified yet).
        let notes: [StoredRecord]
        /// Place records (not verified yet).
        let places: [StoredRecord]
        /// History records (not verified yet).
        let history: [StoredRecord]
        /// Trip records (not verified yet).
        let trips: [StoredRecord]
        /// Move notices (not verified yet).
        let moves: [StoredRecord]
        /// Profile records by device ID (not verified yet).
        let profiles: [String: StoredRecord]
        /// Chat message records (not verified yet).
        let messages: [StoredRecord]
        var circleID: String { snapshot.ref.circleID }
        var ownerDeviceID: String { DeviceID.derive(signingPublicKey: ownerSigningKey) }
    }

    /// Verifies a snapshot against the pinned owner keys. Records that fail
    /// verification are ignored; a bad circle record is fatal.
    nonisolated func parse(_ snapshot: CircleSnapshot) throws -> Parsed {
        let circleID = snapshot.ref.circleID
        guard let (ownerSigning, ownerAgreement) = loadOwner(circleID) else { throw ClientError.untrustedCircle }
        guard let record = snapshot.records.first(where: { $0.type == RecordType.circle && $0.name == RecordName.circle }),
              let epoch = record.int("epoch"), epoch > 0
        else { throw ClientError.tampered }
        let meta = record.bytes("meta")
        guard CircleCrypto.verifySignature(
            record.bytes("sig"), publicKey: ownerSigning,
            message: CircleCrypto.circleRecordStatement(circleID: circleID, epoch: epoch, meta: meta)
        ) else { throw ClientError.tampered }

        var members: [String: Member] = [:]
        for r in snapshot.records where r.type == RecordType.member {
            let m = Member(
                deviceID: r.name, signingKey: r.bytes("skey"), agreementKey: r.bytes("akey"), card: r.bytes("card"),
                inviteID: r.string("invite"), proof: r.bytes("proof"), creator: r.creatorUserID
            )
            guard m.signingKey.count == 32, m.agreementKey.count == 32,
                  DeviceID.derive(signingPublicKey: m.signingKey) == m.deviceID,
                  CircleCrypto.verifySignature(r.bytes("sig"), publicKey: m.signingKey, message: CircleCrypto.memberRecordStatement(
                      circleID: circleID, deviceID: m.deviceID, inviteID: m.inviteID,
                      signingKey: m.signingKey, agreementKey: m.agreementKey, card: m.card, proof: m.proof
                  ))
            else { continue }
            members[m.deviceID] = m
        }
        var invites: [String: StoredRecord] = [:]
        for r in snapshot.records where r.type == RecordType.invite && r.name.hasPrefix(RecordName.invitePrefix) {
            invites[String(r.name.dropFirst(RecordName.invitePrefix.count))] = r
        }
        var locations: [String: StoredRecord] = [:]
        for r in snapshot.records where r.type == RecordType.location && r.name.hasPrefix(RecordName.locationPrefix) {
            locations[String(r.name.dropFirst(RecordName.locationPrefix.count))] = r
        }
        let notes = snapshot.records.filter { $0.type == RecordType.note && $0.name.hasPrefix(RecordName.notePrefix) }
        let places = snapshot.records.filter { $0.type == RecordType.place && $0.name.hasPrefix(RecordName.placePrefix) }
        let history = snapshot.records.filter { $0.type == RecordType.history }
        let trips = snapshot.records.filter { $0.type == RecordType.trip && $0.name.hasPrefix(RecordName.tripPrefix) }
        let moves = snapshot.records.filter { $0.type == RecordType.move }
        let messages = snapshot.records.filter { $0.type == RecordType.message && $0.name.hasPrefix(RecordName.messagePrefix) }
        var profiles: [String: StoredRecord] = [:]
        for r in snapshot.records where r.type == RecordType.profile && r.name.hasPrefix(RecordName.profilePrefix) {
            profiles[String(r.name.dropFirst(RecordName.profilePrefix.count))] = r
        }
        return Parsed(
            snapshot: snapshot, ownerSigningKey: ownerSigning, ownerAgreementKey: ownerAgreement,
            epoch: epoch, metaBlob: meta, members: members, invites: invites, locations: locations, notes: notes,
            places: places, history: history, trips: trips, moves: moves, profiles: profiles, messages: messages
        )
    }

    /// Key for the current epoch: local, or unwrapped from the owner's wrap.
    nonisolated func ensureKey(_ p: Parsed) -> SymmetricKey? {
        if let key = loadKey(circleID: p.circleID, epoch: p.epoch) { return key }
        let name = RecordName.wrap(epoch: p.epoch, deviceID: deviceID)
        guard let wrap = p.snapshot.records.first(where: { $0.type == RecordType.keyWrap && $0.name == name }),
              let (key, _) = try? CircleCrypto.unwrap(wrap.bytes("blob"), circleID: p.circleID, epoch: p.epoch, recipient: identity, senderAgreementKey: { sender in
                  sender == p.ownerDeviceID ? p.ownerAgreementKey : nil
              })
        else { return nil }
        try? storeKey(key, circleID: p.circleID, epoch: p.epoch)
        return key
    }

    /// True if the member proved knowledge of an invite secret that is
    /// still on file.
    nonisolated func hasValidInvite(_ m: Member, _ p: Parsed) -> Bool {
        guard !m.inviteID.isEmpty, let invite = p.invites[m.inviteID],
              let token = try? CircleCrypto.openInviteToken(invite.bytes("token"), circleID: p.circleID, inviteID: m.inviteID, keyForEpoch: keyLookup(p.circleID))
        else { return false }
        return CircleCrypto.verifyAdmissionProof(
            m.proof, authToken: token, circleID: p.circleID, deviceID: m.deviceID,
            signingKey: m.signingKey, agreementKey: m.agreementKey
        )
    }

    /// Loads a circle, keeps this device's member card current and, on the
    /// owner's device, confirms invited members and cleans up departed ones.
    private func load(_ ref: CircleRef, forceCardUpdate: Bool = false) async throws -> CircleDetails {
        let snapshot = try await backend.snapshot(of: ref)
        let p = try parse(snapshot)
        let key = ensureKey(p)
        let keyFor = keyLookup(p.circleID)
        let meta = (try? CircleCrypto.openCircleMeta(p.metaBlob, circleID: p.circleID, keyForEpoch: keyFor))?.meta
        let iAmOwner = p.ownerDeviceID == deviceID

        var roster = Set(meta?.members ?? [])
        roster.insert(p.ownerDeviceID)
        var save: [StoredRecord] = []
        var delete: [String] = []
        var unverified: [String] = []

        if iAmOwner, ref.isOwned, let key, let meta, !snapshot.participants.isEmpty {
            let participants = Set(snapshot.participants.filter { !$0.isOwner }.map(\.userID))
            var newRoster = roster
            for m in p.members.values where m.deviceID != p.ownerDeviceID {
                if let creator = m.creator, !participants.contains(creator) {
                    // The user left or was removed in iCloud.
                    newRoster.remove(m.deviceID)
                    delete.append(m.deviceID)
                    if p.locations[m.deviceID] != nil { delete.append(RecordName.location(m.deviceID)) }
                    delete += (p.notes + p.places + p.history + p.trips + p.messages).filter { $0.string("from") == m.deviceID }.map(\.name)
                    if p.profiles[m.deviceID] != nil { delete.append(RecordName.profile(m.deviceID)) }
                } else if !newRoster.contains(m.deviceID), hasValidInvite(m, p) {
                    newRoster.insert(m.deviceID)
                }
            }
            let nowSeconds = Int64(now().timeIntervalSince1970)
            for (id, invite) in p.invites where (invite.int("expires") ?? 0) <= nowSeconds {
                delete.append(RecordName.invite(id))
            }
            let verifiedUsers = Set(p.members.values.filter { newRoster.contains($0.deviceID) }.compactMap(\.creator))
            unverified = snapshot.participants
                .filter { !$0.isOwner && $0.accepted && !verifiedUsers.contains($0.userID) }
                .map(\.userID)
            if newRoster != roster {
                save.append(try circleRecord(p.circleID, epoch: p.epoch, meta: CircleMeta(
                    name: meta.name, members: newRoster.sorted(), expires: meta.expires, admins: meta.admins?.filter(newRoster.contains), kind: meta.kind
                ), key: key))
                roster = newRoster
            }
        }

        // My own member record: present, current epoch, current name.
        var myName: String?
        if let key {
            let mine = p.members[deviceID]
            let card = mine.flatMap { try? CircleCrypto.openMemberCard($0.card, circleID: p.circleID, deviceID: deviceID, keyForEpoch: keyFor) }
            let admission = loadAdmission(p.circleID)
            myName = displayName ?? card?.card.name
            let stale = mine == nil || card == nil || card?.epoch != p.epoch || card?.card.name != myName
                || mine?.inviteID != (admission?.inviteID ?? "")
            if let name = myName, stale || forceCardUpdate {
                save.append(try memberRecord(p.circleID, epoch: p.epoch, key: key, name: name, admission: admission))
            }
        }

        // My profile under an older key: re-encrypt it too.
        if let key, let record = p.profiles[deviceID], CircleCrypto.contentEpoch(record.bytes("blob")) != p.epoch,
           let mine = verifiedProfile(deviceID, p) {
            save.append(try profileRecord(mine, circleID: p.circleID, epoch: p.epoch, key: key))
        }
        // My places under an older key: re-encrypt, so members who joined
        // after a key rotation can read them.
        let places = verifiedPlaces(p, roster: roster)
        if let key {
            for (place, record) in places where place.creatorID == deviceID && CircleCrypto.contentEpoch(record.bytes("blob")) != p.epoch {
                save.append(try placeRecord(place, circleID: p.circleID, epoch: p.epoch, key: key))
            }
        }

        if !save.isEmpty || !delete.isEmpty {
            try await backend.modify(ref, save: save, delete: delete, removeParticipants: [])
        }

        var members: [CircleMember] = []
        var sawMe = false
        for m in p.members.values where !delete.contains(m.deviceID) {
            let isMe = m.deviceID == deviceID
            let admitted = roster.contains(m.deviceID)
            let pending = !admitted && key != nil && hasValidInvite(m, p)
            guard admitted || pending || isMe else { continue }
            sawMe = sawMe || isMe
            let name = isMe ? (myName ?? nil) : (try? CircleCrypto.openMemberCard(m.card, circleID: p.circleID, deviceID: m.deviceID, keyForEpoch: keyFor))?.card.name
            members.append(CircleMember(
                id: m.deviceID, userID: m.creator, name: name, isOwner: m.deviceID == p.ownerDeviceID,
                isMe: isMe, isPending: pending && !isMe,
                safetyCode: DeviceID.safetyCode(signingPublicKey: m.signingKey, agreementPublicKey: m.agreementKey),
                // Only admitted members share a position with the circle.
                location: admitted || isMe ? verifiedLocation(of: m, p) : nil,
                isAdmin: (meta?.admins ?? []).contains(m.deviceID),
                profile: admitted || isMe ? verifiedProfile(m.deviceID, p) : nil
            ))
        }
        if !sawMe, key != nil, myName != nil {
            members.append(CircleMember(
                id: deviceID, userID: nil, name: myName, isOwner: iAmOwner, isMe: true, isPending: false, safetyCode: safetyCode,
                location: nil
            ))
        }
        let notes = verifiedNotes(p, roster: roster)
        let lastSeen = ownerLastSeen(p, notes: notes)
        let offered = notes.contains { $0.kind == .handoverOffer && $0.senderID == p.ownerDeviceID && $0.recipientID == deviceID }
        members.sort { a, b in
            if a.isOwner != b.isOwner { return a.isOwner }
            if a.isAdmin != b.isAdmin { return a.isAdmin }
            return (a.name ?? "~").localizedCaseInsensitiveCompare(b.name ?? "~") == .orderedAscending
        }
        return CircleDetails(
            ref: ref, name: meta?.name, epoch: p.epoch, isOwner: iAmOwner, hasKey: key != nil,
            members: members, unverifiedUserIDs: unverified,
            notes: notes.filter { ![.removeRequest, .renameRequest].contains($0.kind) },
            places: places.map(\.place).filter { !delete.contains(RecordName.place($0.id)) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            expiresAt: meta?.expires.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            isFriendship: meta?.isFriendship ?? false,
            isAdmin: (meta?.admins ?? []).contains(deviceID),
            ownerLastSeen: lastSeen,
            handoverOffered: offered,
            canTakeOver: !iAmOwner && (meta?.admins ?? []).contains(deviceID)
                && (offered || (lastSeen.map { now().timeIntervalSince($0) >= Self.takeoverAfter } ?? true)),
            messages: verifiedMessages(p, roster: roster)
        )
    }

    // MARK: Record builders

    private nonisolated func circleRecord(_ circleID: String, epoch: Int64, meta: CircleMeta, key: SymmetricKey) throws -> StoredRecord {
        let blob = try CircleCrypto.sealCircleMeta(meta, key: key, epoch: epoch, circleID: circleID)
        let sig = try identity.sign(CircleCrypto.circleRecordStatement(circleID: circleID, epoch: epoch, meta: blob))
        return StoredRecord(type: RecordType.circle, name: RecordName.circle, fields: [
            "epoch": .int(epoch), "meta": .bytes(blob), "sig": .bytes(sig),
        ])
    }

    private nonisolated func memberRecord(_ circleID: String, epoch: Int64, key: SymmetricKey, name: String, admission: Admission?) throws -> StoredRecord {
        let card = try CircleCrypto.sealMemberCard(MemberCard(name: name), key: key, epoch: epoch, circleID: circleID, deviceID: deviceID)
        let inviteID = admission?.inviteID ?? ""
        let proof = admission?.proof ?? Data()
        let sig = try identity.sign(CircleCrypto.memberRecordStatement(
            circleID: circleID, deviceID: deviceID, inviteID: inviteID,
            signingKey: identity.signingPublicKey, agreementKey: identity.agreementPublicKey, card: card, proof: proof
        ))
        return StoredRecord(type: RecordType.member, name: deviceID, fields: [
            "skey": .bytes(identity.signingPublicKey), "akey": .bytes(identity.agreementPublicKey),
            "card": .bytes(card), "invite": .string(inviteID), "proof": .bytes(proof), "sig": .bytes(sig),
        ])
    }

    // MARK: Local key material

    struct Admission {
        let inviteID: String
        let proof: Data
    }

    static func prefix(_ circleID: String) -> String { "circle.\(circleID)." }

    nonisolated func keyLookup(_ circleID: String) -> @Sendable (Int64) -> SymmetricKey? {
        { epoch in self.loadKey(circleID: circleID, epoch: epoch) }
    }

    nonisolated func storeKey(_ key: SymmetricKey, circleID: String, epoch: Int64) throws {
        try secrets.save(key.rawData, for: Self.prefix(circleID) + "key.\(epoch)")
    }

    nonisolated func loadKey(circleID: String, epoch: Int64) -> SymmetricKey? {
        guard let data = try? secrets.load(Self.prefix(circleID) + "key.\(epoch)"), data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    nonisolated func storeOwner(_ circleID: String, signingKey: Data, agreementKey: Data) throws {
        try secrets.save(signingKey + agreementKey, for: Self.prefix(circleID) + "owner")
    }

    nonisolated func loadOwner(_ circleID: String) -> (Data, Data)? {
        guard let data = try? secrets.load(Self.prefix(circleID) + "owner"), data.count == 64 else { return nil }
        return (Data(data.prefix(32)), Data(data.suffix(32)))
    }

    nonisolated func storeAdmission(_ circleID: String, _ admission: Admission) throws {
        try secrets.save(admission.proof + Data(admission.inviteID.utf8), for: Self.prefix(circleID) + "admission")
    }

    nonisolated func loadAdmission(_ circleID: String) -> Admission? {
        guard let data = try? secrets.load(Self.prefix(circleID) + "admission"), data.count > 32 else { return nil }
        return Admission(inviteID: String(decoding: data.dropFirst(32), as: UTF8.self), proof: Data(data.prefix(32)))
    }

    static func validated(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxNameLength else { throw ClientError.invalidName }
        return trimmed
    }
}
