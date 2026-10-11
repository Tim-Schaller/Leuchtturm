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
}

enum RecordType {
    static let circle = "Circle"
    static let member = "Member"
    static let keyWrap = "KeyWrap"
    static let invite = "Invite"
    static let location = "Location"
    static let note = "Note"
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
}

/// High-level client. Everything is encrypted or signed here, before it
/// reaches the backend (iCloud).
public actor LeuchtturmClient {
    public nonisolated let identity: DeviceIdentity
    private let backend: any CircleBackend
    private let secrets: any SecretStore
    private let now: @Sendable () -> Date
    private var displayName: String?
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

    public func createCircle(name: String) async throws -> CircleRef {
        let circleName = try Self.validated(name)
        let myName = try Self.validated(displayName ?? "")
        let circleID = CircleCrypto.newCircleID()
        let key = CircleCrypto.newCircleKey()
        try storeOwner(circleID, signingKey: identity.signingPublicKey, agreementKey: identity.agreementPublicKey)
        try storeKey(key, circleID: circleID, epoch: 1)
        let records = [
            try circleRecord(circleID, epoch: 1, meta: CircleMeta(name: circleName, members: [deviceID]), key: key),
            try memberRecord(circleID, epoch: 1, key: key, name: myName, admission: nil),
        ]
        return try await backend.createCircle(id: circleID, records: records)
    }

    public func circles() async throws -> [CircleSummary] {
        var out: [CircleSummary] = []
        for ref in try await backend.listCircles() {
            var name: String?
            var isOwner = false
            if let snapshot = try? await backend.snapshot(of: ref), let p = try? parse(snapshot) {
                _ = ensureKey(p)
                name = (try? CircleCrypto.openCircleMeta(p.metaBlob, circleID: p.circleID, keyForEpoch: keyLookup(p.circleID)))?.meta.name
                isOwner = p.ownerDeviceID == deviceID
            }
            out.append(CircleSummary(ref: ref, name: name, isOwner: isOwner))
        }
        return out.sorted { ($0.name ?? "~").localizedCaseInsensitiveCompare($1.name ?? "~") == .orderedAscending }
    }

    public func circle(_ ref: CircleRef) async throws -> CircleDetails {
        try await load(ref)
    }

    public func rename(_ ref: CircleRef, to name: String) async throws {
        let name = try Self.validated(name)
        let p = try parse(try await backend.snapshot(of: ref))
        guard p.ownerDeviceID == deviceID else { throw ClientError.notOwner }
        guard let key = ensureKey(p),
              let meta = (try? CircleCrypto.openCircleMeta(p.metaBlob, circleID: p.circleID, keyForEpoch: keyLookup(p.circleID)))?.meta
        else { throw ClientError.missingCircleKey }
        let record = try circleRecord(p.circleID, epoch: p.epoch, meta: CircleMeta(name: name, members: meta.members), key: key)
        try await backend.modify(ref, save: [record], delete: [], removeParticipants: [])
    }

    /// Leaves a circle you do not own. Your location goes with you.
    public func leave(_ ref: CircleRef) async throws {
        guard !ref.isOwned else { throw ClientError.ownerMustDelete }
        try? await backend.modify(ref, save: [], delete: [RecordName.location(deviceID)], removeParticipants: [])
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
        var save = [try circleRecord(p.circleID, epoch: newEpoch, meta: CircleMeta(name: meta.name, members: roster.sorted()), key: newKey)]
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

    /// Shares this device's position with every circle it has a key for.
    /// Tries all circles and throws the first error afterwards.
    public func shareLocation(_ location: SharedLocation) async throws {
        var firstError: (any Error)?
        for ref in try await backend.listCircles() {
            do {
                let p = try parse(try await backend.snapshot(of: ref))
                guard let key = ensureKey(p) else { throw ClientError.missingCircleKey }
                let blob = try CircleCrypto.sealLocation(location, key: key, epoch: p.epoch, circleID: p.circleID, deviceID: deviceID)
                let sig = try identity.sign(CircleCrypto.locationRecordStatement(circleID: p.circleID, deviceID: deviceID, blob: blob))
                let record = StoredRecord(type: RecordType.location, name: RecordName.location(deviceID), fields: [
                    "blob": .bytes(blob), "sig": .bytes(sig),
                ])
                try await backend.modify(ref, save: [record], delete: [], removeParticipants: [])
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
        location: SharedLocation? = nil, in ref: CircleRef
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
            timestamp: timestamp
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
    private func verifiedNotes(_ p: Parsed, roster: Set<String>) -> [CircleNote] {
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
        return Parsed(
            snapshot: snapshot, ownerSigningKey: ownerSigning, ownerAgreementKey: ownerAgreement,
            epoch: epoch, metaBlob: meta, members: members, invites: invites, locations: locations, notes: notes
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
                    delete += p.notes.filter { $0.string("from") == m.deviceID }.map(\.name)
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
                save.append(try circleRecord(p.circleID, epoch: p.epoch, meta: CircleMeta(name: meta.name, members: newRoster.sorted()), key: key))
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
                location: admitted || isMe ? verifiedLocation(of: m, p) : nil
            ))
        }
        if !sawMe, key != nil, myName != nil {
            members.append(CircleMember(
                id: deviceID, userID: nil, name: myName, isOwner: iAmOwner, isMe: true, isPending: false, safetyCode: safetyCode,
                location: nil
            ))
        }
        members.sort { a, b in
            if a.isOwner != b.isOwner { return a.isOwner }
            return (a.name ?? "~").localizedCaseInsensitiveCompare(b.name ?? "~") == .orderedAscending
        }
        return CircleDetails(
            ref: ref, name: meta?.name, epoch: p.epoch, isOwner: iAmOwner, hasKey: key != nil,
            members: members, unverifiedUserIDs: unverified, notes: verifiedNotes(p, roster: roster)
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
