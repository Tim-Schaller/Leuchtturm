#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// A chat message in a circle: text, a picture or sticker, a reply to
/// another message, or a reaction to one. Encrypted under the circle key
/// and signed by the sending device.
public struct ChatMessage: Sendable, Hashable, Identifiable {
    public let id: String
    public let senderID: String
    public let text: String
    /// The message this one answers.
    public let replyTo: String?
    /// Set for a reaction: the message it reacts to (`text` is the emoji).
    public let reactsTo: String?
    /// A photo (JPEG) or sticker (image data as the keyboard provides it).
    public let image: Data?
    /// True if `image` is a sticker or Genmoji, shown without a bubble.
    public let isSticker: Bool
    public let timestamp: Date

    public static let maxTextLength = 2000
    public static let maxImageBytes = 400_000
    /// Older messages are ignored by readers and deleted by their sender.
    public static let lifetime: TimeInterval = 30 * 86400

    public init(
        id: String, senderID: String, text: String, replyTo: String? = nil, reactsTo: String? = nil,
        image: Data? = nil, isSticker: Bool = false, timestamp: Date
    ) {
        self.id = id
        self.senderID = senderID
        self.text = text
        self.replyTo = replyTo
        self.reactsTo = reactsTo
        self.image = image
        self.isSticker = isSticker
        // Milliseconds, so messages sent within one second keep their order.
        self.timestamp = Date(timeIntervalSince1970: (timestamp.timeIntervalSince1970 * 1000).rounded(.down) / 1000)
    }

    var isValid: Bool {
        text.count <= Self.maxTextLength && (image?.count ?? 0) <= Self.maxImageBytes
            && (reactsTo == nil || text.count <= 8) && (!text.isEmpty || image != nil)
    }
}

private struct MessagePayload: Codable {
    let x: String
    var r: String?
    var a: String?
    var s: Bool?
    /// Unix time in milliseconds.
    let t: Int64
}

extension CircleCrypto {
    static func sealMessage(_ message: ChatMessage, key: SymmetricKey, epoch: Int64, circleID: String) throws -> (blob: Data, image: Data) {
        let context = Wire.context("leuchtturm/v1/message", circleID, message.id)
        let payload = MessagePayload(
            x: message.text, r: message.replyTo, a: message.reactsTo, s: message.isSticker ? true : nil,
            t: Int64((message.timestamp.timeIntervalSince1970 * 1000).rounded())
        )
        return (
            try sealContent(JSONEncoder().encode(payload), key: key, epoch: epoch, context: context),
            try message.image.map { try sealPicture($0, key: key, epoch: epoch, context: context + Data("image".utf8)) } ?? Data()
        )
    }

    static func openMessage(
        blob: Data, image: Data, id: String, senderID: String, circleID: String, keyForEpoch: (Int64) -> SymmetricKey?
    ) throws -> ChatMessage? {
        let context = Wire.context("leuchtturm/v1/message", circleID, id)
        guard let (plain, _) = try openContent(blob, context: context, keyForEpoch: keyForEpoch) else { return nil }
        let p = try JSONDecoder().decode(MessagePayload.self, from: plain)
        let message = ChatMessage(
            id: id, senderID: senderID, text: p.x, replyTo: p.r, reactsTo: p.a,
            image: image.isEmpty ? nil : try openPicture(image, context: context + Data("image".utf8), keyForEpoch: keyForEpoch),
            isSticker: p.s ?? false, timestamp: Date(timeIntervalSince1970: TimeInterval(p.t) / 1000)
        )
        guard message.isValid, p.t > 0 else { throw ProtocolError.malformed }
        return message
    }

    static func messageRecordStatement(circleID: String, id: String, senderID: String, blob: Data, image: Data) -> Data {
        var out = Wire.context("leuchtturm/v1/message-record", circleID, id, senderID)
        for part in [blob, image] {
            out.append(Wire.bigEndian(UInt64(part.count)))
            out.append(part)
        }
        return out
    }
}
