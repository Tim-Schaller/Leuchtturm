#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Request authentication, scheme "LT1". See docs/API.md.
///
///     Authorization: LT1 key=<b64url>,ts=<unix>,nonce=<b64url>,sig=<b64url>
///
/// The Ed25519 signature covers
/// `LT1\n<METHOD>\n<request URI>\n<ts>\n<nonce>\n<hex sha256(body)>`.
public enum RequestSigner {
    public static let scheme = "LT1"

    public static func canonical(method: String, requestURI: String, timestamp: Int64, nonce: String, body: Data) -> Data {
        let bodyHash = Wire.hex(SHA256.hash(data: body))
        return Data("\(scheme)\n\(method)\n\(requestURI)\n\(timestamp)\n\(nonce)\n\(bodyHash)".utf8)
    }

    public static func authorization(
        identity: DeviceIdentity, method: String, requestURI: String,
        timestamp: Int64, nonce: Data, body: Data
    ) throws -> String {
        let n = Base64URL.encode(nonce)
        let signature = try identity.sign(canonical(method: method, requestURI: requestURI, timestamp: timestamp, nonce: n, body: body))
        return "\(scheme) key=\(Base64URL.encode(identity.signingPublicKey)),ts=\(timestamp),nonce=\(n),sig=\(Base64URL.encode(signature))"
    }

    public static func randomNonce() -> Data { randomBytes(16) }

    /// Verifies a header and returns the signer's public key. Used by tests;
    /// the server has its own implementation. Does not check time or replays.
    public static func verify(authorization: String, method: String, requestURI: String, body: Data) -> Data? {
        guard authorization.hasPrefix(scheme + " ") else { return nil }
        var fields: [String: String] = [:]
        for part in authorization.dropFirst(scheme.count + 1).split(separator: ",") {
            let kv = part.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { return nil }
            fields[String(kv[0])] = String(kv[1])
        }
        guard let keyString = fields["key"], let key = Base64URL.decode(keyString),
              let sigString = fields["sig"], let sig = Base64URL.decode(sigString),
              let nonce = fields["nonce"], let tsString = fields["ts"], let ts = Int64(tsString),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: key)
        else { return nil }
        let message = canonical(method: method, requestURI: requestURI, timestamp: ts, nonce: nonce, body: body)
        return publicKey.isValidSignature(sig, for: message) ? key : nil
    }
}
