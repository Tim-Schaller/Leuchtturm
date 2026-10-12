#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Left in the old Leuchtturm by whoever took it over: where the new one is
/// and who owns it. Encrypted under the old circle key and signed by the new
/// owner, so only admitted members can read it and nobody can redirect them.
public struct MoveNotice: Sendable, Equatable {
    public let newCircleID: String
    /// iCloud share of the new Leuchtturm.
    public let shareURL: URL
    public let ownerSigningKey: Data
    public let ownerAgreementKey: Data
    public let timestamp: Date

    public init(newCircleID: String, shareURL: URL, ownerSigningKey: Data, ownerAgreementKey: Data, timestamp: Date) {
        self.newCircleID = newCircleID
        self.shareURL = shareURL
        self.ownerSigningKey = ownerSigningKey
        self.ownerAgreementKey = ownerAgreementKey
        self.timestamp = Date(timeIntervalSince1970: timestamp.timeIntervalSince1970.rounded(.down))
    }
}

private struct MovePayload: Codable {
    let c: String
    let u: String
    let s: B64Data
    let a: B64Data
    let t: Int64
}

extension CircleCrypto {
    static func sealMove(_ move: MoveNotice, key: SymmetricKey, epoch: Int64, circleID: String, signer: String) throws -> Data {
        let payload = MovePayload(
            c: move.newCircleID, u: move.shareURL.absoluteString, s: B64Data(move.ownerSigningKey),
            a: B64Data(move.ownerAgreementKey), t: Int64(move.timestamp.timeIntervalSince1970)
        )
        return try sealContent(JSONEncoder().encode(payload), key: key, epoch: epoch, context: moveContext(circleID: circleID, signer: signer))
    }

    static func openMove(
        _ blob: Data, circleID: String, signer: String, keyForEpoch: (Int64) -> SymmetricKey?
    ) throws -> MoveNotice? {
        guard let (plain, _) = try openContent(blob, context: moveContext(circleID: circleID, signer: signer), keyForEpoch: keyForEpoch)
        else { return nil }
        let p = try JSONDecoder().decode(MovePayload.self, from: plain)
        guard DeviceID.raw(p.c) != nil, let url = URL(string: p.u), url.scheme == "https", url.host != nil,
              p.s.bytes.count == 32, p.a.bytes.count == 32, p.t > 0
        else { throw ProtocolError.malformed }
        return MoveNotice(
            newCircleID: p.c, shareURL: url, ownerSigningKey: p.s.bytes, ownerAgreementKey: p.a.bytes,
            timestamp: Date(timeIntervalSince1970: TimeInterval(p.t))
        )
    }

    static func moveRecordStatement(circleID: String, signer: String, blob: Data) -> Data {
        Wire.context("leuchtturm/v1/move-record", circleID, signer) + blob
    }

    static func moveContext(circleID: String, signer: String) -> Data {
        Wire.context("leuchtturm/v1/move", circleID, signer)
    }
}
