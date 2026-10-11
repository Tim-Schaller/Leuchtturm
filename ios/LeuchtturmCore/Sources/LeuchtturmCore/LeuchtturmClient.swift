#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A circle as shown in the circle list.
public struct CircleSummary: Sendable, Identifiable, Hashable {
    public let id: String
    /// nil if the name cannot be decrypted (yet).
    public let name: String?
    public let epoch: Int64
    public let isOwner: Bool
}

/// A circle member, decrypted where possible.
public struct CircleMember: Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String?
    public let isOwner: Bool
    public let isMe: Bool
    public let joinedAt: Date
    /// Compare in person to detect key substitution by the server.
    public let safetyCode: String
}

public struct CircleDetails: Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String?
    public let epoch: Int64
    public let isOwner: Bool
    public let members: [CircleMember]
}

public enum ClientError: Error, Sendable, Equatable {
    /// No usable key for the circle's current epoch on this device.
    case missingCircleKey
    case notOwner
    case unknownMember
    /// The invite belongs to another server than the one this app uses.
    case differentServer
    case invalidName
}

/// High-level client: everything the app needs for circles, with all
/// encryption done before anything leaves the device.
public actor LeuchtturmClient {
    public nonisolated let identity: DeviceIdentity
    public nonisolated let serverURL: URL
    private let api: APIClient
    private let secrets: any SecretStore
    private var displayName: String?

    public static let maxNameLength = 40

    public init(serverURL: URL, secrets: any SecretStore, displayName: String? = nil, session: URLSession = .shared) throws {
        let identity = try DeviceIdentity.loadOrCreate(in: secrets)
        self.identity = identity
        self.serverURL = serverURL
        self.secrets = secrets
        self.displayName = displayName
        api = APIClient(baseURL: serverURL, identity: identity, session: session)
    }

    public nonisolated var deviceID: String { identity.deviceID }

    public nonisolated var safetyCode: String {
        DeviceID.safetyCode(signingPublicKey: identity.signingPublicKey, agreementPublicKey: identity.agreementPublicKey)
    }

    /// Registers the device's public keys. Safe to call repeatedly.
    public func register() async throws {
        _ = try await api.registerDevice()
    }

    /// Sets the name shown to others and updates it in every circle.
    public func setDisplayName(_ name: String) async throws {
        let name = try Self.validated(name)
        displayName = name
        for summary in try await api.listCircles() {
            _ = try? await load(summary.circleID, forceCardUpdate: true)
        }
    }

    // MARK: Circles

    public func createCircle(name: String) async throws -> String {
        let circleName = try Self.validated(name)
        let myName = try Self.validated(displayName ?? "")
        let circleID = CircleCrypto.newCircleID()
        let key = CircleCrypto.newCircleKey()
        let request = CreateCircleRequest(
            circleID: circleID,
            metaBlob: B64Data(try CircleCrypto.sealCircleMeta(CircleMeta(name: circleName), key: key, epoch: 1, circleID: circleID)),
            memberBlob: B64Data(try CircleCrypto.sealMemberCard(MemberCard(name: myName), key: key, epoch: 1, circleID: circleID, deviceID: deviceID)),
            wrappedKey: B64Data(try CircleCrypto.wrap(
                circleKey: key, circleID: circleID, epoch: 1,
                recipientDeviceID: deviceID, recipientAgreementKey: identity.agreementPublicKey, sender: identity
            ))
        )
        // Store the key first: a lost response must not lose the key.
        try storeKey(key, circleID: circleID, epoch: 1)
        _ = try await api.createCircle(request)
        return circleID
    }

    public func circles() async throws -> [CircleSummary] {
        var out: [CircleSummary] = []
        for dto in try await api.listCircles() {
            if loadKey(circleID: dto.circleID, epoch: dto.epoch) == nil, dto.wrappedKey != nil {
                // A rotation happened: fetch the member list to verify the wrapper.
                _ = try? await load(dto.circleID)
            }
            let meta = try? CircleCrypto.openCircleMeta(dto.metaBlob.bytes, circleID: dto.circleID) {
                self.loadKey(circleID: dto.circleID, epoch: $0)
            }
            out.append(CircleSummary(id: dto.circleID, name: meta?.meta.name, epoch: dto.epoch, isOwner: dto.role == "owner"))
        }
        return out
    }

    public func circle(_ circleID: String) async throws -> CircleDetails {
        try await load(circleID)
    }

    public func rename(circleID: String, to name: String) async throws {
        let name = try Self.validated(name)
        let (dto, members) = try await fetch(circleID)
        guard members.first(where: { $0.deviceID == deviceID })?.role == "owner" else { throw ClientError.notOwner }
        guard let key = try ensureCurrentKey(dto, members: members) else { throw ClientError.missingCircleKey }
        let blob = try CircleCrypto.sealCircleMeta(CircleMeta(name: name), key: key, epoch: dto.epoch, circleID: circleID)
        try await api.updateMeta(circleID: circleID, blob: blob)
    }

    public func leave(circleID: String) async throws {
        try await api.leave(circleID: circleID)
        try? secrets.deleteAll(prefix: Self.keyPrefix(circleID))
    }

    /// Removes a member (owner only) and rotates the circle key, so the
    /// removed device cannot read anything shared afterwards.
    public func remove(memberID: String, from circleID: String) async throws {
        let (dto, members) = try await fetch(circleID)
        guard members.first(where: { $0.deviceID == deviceID })?.role == "owner" else { throw ClientError.notOwner }
        guard memberID != deviceID, members.contains(where: { $0.deviceID == memberID }) else { throw ClientError.unknownMember }
        guard try ensureCurrentKey(dto, members: members) != nil else { throw ClientError.missingCircleKey }

        let meta = (try? CircleCrypto.openCircleMeta(dto.metaBlob.bytes, circleID: circleID) {
            self.loadKey(circleID: circleID, epoch: $0)
        })?.meta ?? CircleMeta(name: "")
        let newEpoch = dto.epoch + 1
        let newKey = CircleCrypto.newCircleKey()
        let wrapped = try members.filter { $0.deviceID != memberID }.map { member in
            WrappedKeyEntry(deviceID: member.deviceID, wrappedKey: B64Data(try CircleCrypto.wrap(
                circleKey: newKey, circleID: circleID, epoch: newEpoch,
                recipientDeviceID: member.deviceID, recipientAgreementKey: member.agreementKey, sender: identity
            )))
        }
        let request = RemoveMemberRequest(
            epoch: newEpoch,
            metaBlob: B64Data(try CircleCrypto.sealCircleMeta(meta, key: newKey, epoch: newEpoch, circleID: circleID)),
            wrappedKeys: wrapped
        )
        try storeKey(newKey, circleID: circleID, epoch: newEpoch)
        _ = try await api.removeMember(circleID: circleID, deviceID: memberID, request: request)
        // Re-encrypt my own card under the new key.
        _ = try? await load(circleID)
    }

    // MARK: Invites

    /// Creates an invite link. Share it privately: whoever has it can join.
    public func createInvite(circleID: String, validFor seconds: Int64 = 24 * 3600, maxUses: Int = 1) async throws -> InviteLink {
        let (dto, members) = try await fetch(circleID)
        guard let key = try ensureCurrentKey(dto, members: members) else { throw ClientError.missingCircleKey }
        let secret = randomBytes(32)
        let keys = CircleCrypto.inviteKeys(secret: secret)
        let request = CreateInviteRequest(
            epoch: dto.epoch,
            authTokenHash: B64Data(keys.authTokenHash),
            sealedCircleKey: B64Data(try CircleCrypto.sealInvitePayload(circleKey: key, epoch: dto.epoch, circleID: circleID, keys: keys)),
            expiresInSeconds: seconds,
            maxUses: maxUses
        )
        let response = try await api.createInvite(circleID: circleID, request: request)
        return InviteLink(server: serverURL, inviteID: response.inviteID, secret: secret)
    }

    public func revokeInvite(circleID: String, inviteID: String) async throws {
        try await api.revokeInvite(circleID: circleID, inviteID: inviteID)
    }

    /// Joins the circle behind an invite link. Returns the circle ID.
    public func join(_ link: InviteLink) async throws -> String {
        guard Self.sameServer(link.server, serverURL) else { throw ClientError.differentServer }
        let keys = CircleCrypto.inviteKeys(secret: link.secret)
        // The circle key is only revealed by joining, so every holder of the
        // key shows up in the member list. The card follows right after.
        let response = try await api.redeemInvite(
            inviteID: link.inviteID,
            request: RedeemInviteRequest(authToken: B64Data(keys.authToken), memberBlob: B64Data(CircleCrypto.emptyCard))
        )
        let (key, epoch) = try CircleCrypto.openInvitePayload(response.sealedCircleKey.bytes, circleID: response.circleID, keys: keys)
        guard epoch == response.epoch else { throw ProtocolError.epochMismatch }
        try storeKey(key, circleID: response.circleID, epoch: epoch)
        _ = try? await load(response.circleID)
        return response.circleID
    }

    // MARK: Account

    /// Deletes this device on the server and all local key material.
    public func deleteDevice() async throws {
        try await api.deleteDevice()
        for account in try secrets.accounts() {
            try secrets.delete(account)
        }
    }

    // MARK: Internals

    struct VerifiedMember {
        let deviceID: String
        let signingKey: Data
        let agreementKey: Data
        let role: String
        let memberBlob: Data
        let joinedAt: Int64
    }

    /// Fetches a circle and keeps only members whose device ID matches their
    /// signing key (the server cannot relabel keys).
    private func fetch(_ circleID: String) async throws -> (CircleDetailDTO, [VerifiedMember]) {
        let dto = try await api.circle(circleID)
        let members = dto.members.compactMap { m -> VerifiedMember? in
            guard m.signingKey.bytes.count == 32, m.agreementKey.bytes.count == 32,
                  DeviceID.derive(signingPublicKey: m.signingKey.bytes) == m.deviceID
            else { return nil }
            return VerifiedMember(
                deviceID: m.deviceID, signingKey: m.signingKey.bytes, agreementKey: m.agreementKey.bytes,
                role: m.role, memberBlob: m.memberBlob.bytes, joinedAt: m.joinedAt
            )
        }
        return (dto, members)
    }

    /// Returns the key for the current epoch, unwrapping a rotated key if needed.
    private func ensureCurrentKey(_ dto: CircleDetailDTO, members: [VerifiedMember]) throws -> SymmetricKey? {
        if let key = loadKey(circleID: dto.circleID, epoch: dto.epoch) { return key }
        guard let wrapped = dto.myWrappedKey?.bytes else { return nil }
        let (key, _) = try CircleCrypto.unwrap(wrapped, circleID: dto.circleID, epoch: dto.epoch, recipient: identity) { sender in
            members.first { $0.deviceID == sender }?.agreementKey
        }
        try storeKey(key, circleID: dto.circleID, epoch: dto.epoch)
        return key
    }

    /// Loads and decrypts a circle. Also keeps my own member card current:
    /// after a key rotation (or a join) it is re-encrypted under the new key.
    private func load(_ circleID: String, forceCardUpdate: Bool = false) async throws -> CircleDetails {
        let (dto, members) = try await fetch(circleID)
        let currentKey = try ensureCurrentKey(dto, members: members)
        let keyFor: (Int64) -> SymmetricKey? = { self.loadKey(circleID: circleID, epoch: $0) }

        var result: [CircleMember] = []
        for m in members {
            let card = try? CircleCrypto.openMemberCard(m.memberBlob, circleID: circleID, deviceID: m.deviceID, keyForEpoch: keyFor)
            var name = card?.card.name
            if m.deviceID == deviceID, let currentKey {
                let stale = card == nil || card!.epoch != dto.epoch
                let wanted = displayName ?? card?.card.name
                if let wanted, stale || forceCardUpdate || wanted != card?.card.name {
                    let blob = try CircleCrypto.sealMemberCard(MemberCard(name: wanted), key: currentKey, epoch: dto.epoch, circleID: circleID, deviceID: deviceID)
                    try await api.updateMemberBlob(circleID: circleID, blob: blob)
                    name = wanted
                }
            }
            result.append(CircleMember(
                id: m.deviceID, name: name, isOwner: m.role == "owner", isMe: m.deviceID == deviceID,
                joinedAt: Date(timeIntervalSince1970: TimeInterval(m.joinedAt)),
                safetyCode: DeviceID.safetyCode(signingPublicKey: m.signingKey, agreementPublicKey: m.agreementKey)
            ))
        }
        let meta = try? CircleCrypto.openCircleMeta(dto.metaBlob.bytes, circleID: circleID, keyForEpoch: keyFor)
        return CircleDetails(
            id: circleID, name: meta?.meta.name, epoch: dto.epoch,
            isOwner: members.first { $0.deviceID == deviceID }?.role == "owner",
            members: result
        )
    }

    static func keyPrefix(_ circleID: String) -> String { "circle.\(circleID)." }

    private func storeKey(_ key: SymmetricKey, circleID: String, epoch: Int64) throws {
        try secrets.save(key.rawData, for: Self.keyPrefix(circleID) + String(epoch))
    }

    private func loadKey(circleID: String, epoch: Int64) -> SymmetricKey? {
        guard let data = try? secrets.load(Self.keyPrefix(circleID) + String(epoch)), data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    static func validated(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxNameLength else { throw ClientError.invalidName }
        return trimmed
    }

    static func sameServer(_ a: URL, _ b: URL) -> Bool {
        func norm(_ u: URL) -> String {
            var s = u.absoluteString.lowercased()
            while s.hasSuffix("/") { s.removeLast() }
            return s
        }
        return norm(a) == norm(b)
    }
}
