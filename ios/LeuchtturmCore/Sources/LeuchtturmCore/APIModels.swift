import Foundation

// Wire types of the v1 HTTP API (docs/API.md). Field names are explicit so
// they never depend on a key-coding strategy.

struct RegisterDeviceRequest: Encodable {
    let signingKey: B64Data
    let agreementKey: B64Data
    enum CodingKeys: String, CodingKey {
        case signingKey = "signing_key", agreementKey = "agreement_key"
    }
}

struct RegisterDeviceResponse: Decodable {
    let deviceID: String
    enum CodingKeys: String, CodingKey { case deviceID = "device_id" }
}

struct CreateCircleRequest: Encodable {
    let circleID: String
    let metaBlob: B64Data
    let memberBlob: B64Data
    let wrappedKey: B64Data
    enum CodingKeys: String, CodingKey {
        case circleID = "circle_id", metaBlob = "meta_blob", memberBlob = "member_blob", wrappedKey = "wrapped_key"
    }
}

struct CreateCircleResponse: Decodable {
    let circleID: String
    let epoch: Int64
    enum CodingKeys: String, CodingKey { case circleID = "circle_id", epoch }
}

public struct CircleSummaryDTO: Decodable, Sendable {
    public let circleID: String
    public let epoch: Int64
    public let role: String
    public let metaBlob: B64Data
    public let wrappedKey: B64Data?
    enum CodingKeys: String, CodingKey {
        case circleID = "circle_id", epoch, role, metaBlob = "meta_blob", wrappedKey = "wrapped_key"
    }
}

struct ListCirclesResponse: Decodable {
    let circles: [CircleSummaryDTO]
}

public struct MemberDTO: Decodable, Sendable {
    public let deviceID: String
    public let signingKey: B64Data
    public let agreementKey: B64Data
    public let role: String
    public let memberBlob: B64Data
    public let joinedAt: Int64
    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id", signingKey = "signing_key", agreementKey = "agreement_key"
        case role, memberBlob = "member_blob", joinedAt = "joined_at"
    }
}

public struct CircleDetailDTO: Decodable, Sendable {
    public let circleID: String
    public let epoch: Int64
    public let metaBlob: B64Data
    public let myWrappedKey: B64Data?
    public let members: [MemberDTO]
    enum CodingKeys: String, CodingKey {
        case circleID = "circle_id", epoch, metaBlob = "meta_blob", myWrappedKey = "my_wrapped_key", members
    }
}

struct MemberBlobRequest: Encodable {
    let memberBlob: B64Data
    enum CodingKeys: String, CodingKey { case memberBlob = "member_blob" }
}

struct MetaBlobRequest: Encodable {
    let metaBlob: B64Data
    enum CodingKeys: String, CodingKey { case metaBlob = "meta_blob" }
}

struct WrappedKeyEntry: Encodable {
    let deviceID: String
    let wrappedKey: B64Data
    enum CodingKeys: String, CodingKey { case deviceID = "device_id", wrappedKey = "wrapped_key" }
}

struct RemoveMemberRequest: Encodable {
    let epoch: Int64
    let metaBlob: B64Data
    let wrappedKeys: [WrappedKeyEntry]
    enum CodingKeys: String, CodingKey { case epoch, metaBlob = "meta_blob", wrappedKeys = "wrapped_keys" }
}

struct EpochResponse: Decodable {
    let epoch: Int64
}

struct CreateInviteRequest: Encodable {
    let epoch: Int64
    let authTokenHash: B64Data
    let sealedCircleKey: B64Data
    let expiresInSeconds: Int64
    let maxUses: Int
    enum CodingKeys: String, CodingKey {
        case epoch, authTokenHash = "auth_token_hash", sealedCircleKey = "sealed_circle_key"
        case expiresInSeconds = "expires_in_seconds", maxUses = "max_uses"
    }
}

struct CreateInviteResponse: Decodable {
    let inviteID: String
    let expiresAt: Int64
    enum CodingKeys: String, CodingKey { case inviteID = "invite_id", expiresAt = "expires_at" }
}

struct RedeemInviteRequest: Encodable {
    let authToken: B64Data
    let memberBlob: B64Data
    enum CodingKeys: String, CodingKey { case authToken = "auth_token", memberBlob = "member_blob" }
}

struct RedeemInviteResponse: Decodable {
    let circleID: String
    let epoch: Int64
    let role: String
    let sealedCircleKey: B64Data
    enum CodingKeys: String, CodingKey {
        case circleID = "circle_id", epoch, role, sealedCircleKey = "sealed_circle_key"
    }
}

struct APIErrorBody: Decodable {
    let error: String
    let message: String?
    let serverTime: Int64?
    enum CodingKeys: String, CodingKey { case error, message, serverTime = "server_time" }
}

struct EmptyResponse: Decodable {}
