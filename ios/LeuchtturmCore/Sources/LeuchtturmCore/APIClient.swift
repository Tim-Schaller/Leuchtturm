import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum APIError: Error, Sendable, Equatable {
    /// The server answered with an error (`code` is the machine-readable error).
    case server(status: Int, code: String, message: String)
    case invalidResponse
    case invalidURL
}

/// Thin, signed HTTP client for the v1 API. Every request is signed with the
/// device key; there are no sessions or tokens.
public actor APIClient {
    public nonisolated let baseURL: URL
    private let identity: DeviceIdentity
    private let session: URLSession
    private let origin: String
    private let pathPrefix: String
    /// Seconds to add to the local clock (learned from `stale_timestamp` errors).
    private var clockOffset: Int64 = 0

    public init(baseURL: URL, identity: DeviceIdentity, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.identity = identity
        self.session = session
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        var prefix = components.percentEncodedPath
        while prefix.hasSuffix("/") { prefix.removeLast() }
        pathPrefix = prefix
        components.percentEncodedPath = ""
        components.query = nil
        components.fragment = nil
        origin = components.string ?? baseURL.absoluteString
    }

    // MARK: Endpoints

    func registerDevice() async throws -> String {
        let body = RegisterDeviceRequest(signingKey: B64Data(identity.signingPublicKey), agreementKey: B64Data(identity.agreementPublicKey))
        let response: RegisterDeviceResponse = try await send("POST", "/v1/devices", body)
        return response.deviceID
    }

    func deleteDevice() async throws {
        try await sendVoid("DELETE", "/v1/devices/me")
    }

    func createCircle(_ request: CreateCircleRequest) async throws -> CreateCircleResponse {
        try await send("POST", "/v1/circles", request)
    }

    func listCircles() async throws -> [CircleSummaryDTO] {
        let response: ListCirclesResponse = try await send("GET", "/v1/circles")
        return response.circles
    }

    func circle(_ id: String) async throws -> CircleDetailDTO {
        try await send("GET", "/v1/circles/\(try pathComponent(id))")
    }

    func updateMemberBlob(circleID: String, blob: Data) async throws {
        try await sendVoid("PUT", "/v1/circles/\(try pathComponent(circleID))/members/me", MemberBlobRequest(memberBlob: B64Data(blob)))
    }

    func updateMeta(circleID: String, blob: Data) async throws {
        try await sendVoid("PUT", "/v1/circles/\(try pathComponent(circleID))/meta", MetaBlobRequest(metaBlob: B64Data(blob)))
    }

    func leave(circleID: String) async throws {
        try await sendVoid("POST", "/v1/circles/\(try pathComponent(circleID))/leave")
    }

    func removeMember(circleID: String, deviceID: String, request: RemoveMemberRequest) async throws -> Int64 {
        let path = "/v1/circles/\(try pathComponent(circleID))/members/\(try pathComponent(deviceID))/remove"
        let response: EpochResponse = try await send("POST", path, request)
        return response.epoch
    }

    func createInvite(circleID: String, request: CreateInviteRequest) async throws -> CreateInviteResponse {
        try await send("POST", "/v1/circles/\(try pathComponent(circleID))/invites", request)
    }

    func revokeInvite(circleID: String, inviteID: String) async throws {
        try await sendVoid("DELETE", "/v1/circles/\(try pathComponent(circleID))/invites/\(try pathComponent(inviteID))")
    }

    func redeemInvite(inviteID: String, request: RedeemInviteRequest) async throws -> RedeemInviteResponse {
        try await send("POST", "/v1/invites/\(try pathComponent(inviteID))/redeem", request)
    }

    // MARK: Transport

    private func send<R: Decodable>(_ method: String, _ path: String) async throws -> R {
        try decode(await perform(method, path, body: Data()))
    }

    private func send<B: Encodable, R: Decodable>(_ method: String, _ path: String, _ body: B) async throws -> R {
        try decode(await perform(method, path, body: JSONEncoder().encode(body)))
    }

    private func sendVoid(_ method: String, _ path: String) async throws {
        _ = try await perform(method, path, body: Data())
    }

    private func sendVoid<B: Encodable>(_ method: String, _ path: String, _ body: B) async throws {
        _ = try await perform(method, path, body: JSONEncoder().encode(body))
    }

    private func decode<R: Decodable>(_ data: Data) throws -> R {
        do {
            return try JSONDecoder().decode(R.self, from: data)
        } catch {
            throw APIError.invalidResponse
        }
    }

    /// IDs are base64url, so they never need escaping; reject anything else.
    private func pathComponent(_ id: String) throws -> String {
        guard !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            throw APIError.invalidURL
        }
        return id
    }

    private func perform(_ method: String, _ path: String, body: Data, retryOnStaleClock: Bool = true) async throws -> Data {
        let requestURI = pathPrefix + path
        guard let url = URL(string: origin + requestURI) else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        if !body.isEmpty {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let timestamp = Int64(Date().timeIntervalSince1970) + clockOffset
        let header = try RequestSigner.authorization(
            identity: identity, method: method, requestURI: requestURI,
            timestamp: timestamp, nonce: RequestSigner.randomNonce(), body: body
        )
        request.setValue(header, forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        if (200 ..< 300).contains(http.statusCode) { return data }

        let error = try? JSONDecoder().decode(APIErrorBody.self, from: data)
        if http.statusCode == 401, retryOnStaleClock, error?.error == "stale_timestamp", let serverTime = error?.serverTime {
            clockOffset = serverTime - Int64(Date().timeIntervalSince1970)
            return try await perform(method, path, body: body, retryOnStaleClock: false)
        }
        throw APIError.server(status: http.statusCode, code: error?.error ?? "unknown", message: error?.message ?? "")
    }
}
