#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// One day of a member's path, shared only if they turned history on.
/// Encrypted under the circle key and signed by the member's device, which
/// also deletes it again when the chosen retention ends.
public struct HistoryDay: Sendable, Hashable, Identifiable {
    public struct Point: Sendable, Hashable, Codable {
        public let latitude: Double
        public let longitude: Double
        public let timestamp: Date

        public init(latitude: Double, longitude: Double, timestamp: Date) {
            self.latitude = latitude
            self.longitude = longitude
            self.timestamp = Date(timeIntervalSince1970: timestamp.timeIntervalSince1970.rounded(.down))
        }
    }

    public var id: String { "\(deviceID)/\(day)" }
    public let deviceID: String
    /// UTC day, "yyyy-MM-dd".
    public let day: String
    public let points: [Point]

    public static let maxPoints = 2000
    public static let retentions: [Int] = [1, 7, 30]

    public init(deviceID: String, day: String, points: [Point]) {
        self.deviceID = deviceID
        self.day = day
        self.points = Array(points.suffix(Self.maxPoints))
    }

    /// "yyyy-MM-dd" in UTC, so every device files a moment under the same day.
    public static func dayKey(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func isDayKey(_ s: String) -> Bool {
        s.count == 10 && s.allSatisfy { $0.isNumber || $0 == "-" }
    }
}

extension HistoryDay {
    /// GPX 1.1 with one track segment per day, oldest day first.
    public static func gpx(_ days: [HistoryDay], name: String) -> String {
        let iso = ISO8601DateFormatter()
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Leuchtturm" xmlns="http://www.topografix.com/GPX/1/1">
          <trk><name>\(escape(name))</name>

        """
        for day in days.sorted(by: { $0.day < $1.day }) where !day.points.isEmpty {
            out += "    <trkseg>\n"
            for p in day.points {
                out += "      <trkpt lat=\"\(p.latitude)\" lon=\"\(p.longitude)\"><time>\(iso.string(from: p.timestamp))</time></trkpt>\n"
            }
            out += "    </trkseg>\n"
        }
        return out + "  </trk>\n</gpx>\n"
    }
}

/// What a device uploads with its location while history is on.
public struct HistoryUpdate: Sendable {
    /// Today's points so far.
    public let today: HistoryDay
    /// Days older than this many days are deleted.
    public let keepDays: Int

    public init(today: HistoryDay, keepDays: Int) {
        self.today = today
        self.keepDays = keepDays
    }
}

private struct HistoryPayload: Codable {
    let p: [[Double]]
}

extension CircleCrypto {
    /// Points as `[lat, lon, unix seconds]` triples.
    static func sealHistory(_ day: HistoryDay, key: SymmetricKey, epoch: Int64, circleID: String) throws -> Data {
        let payload = HistoryPayload(p: day.points.map {
            [($0.latitude * 1e6).rounded() / 1e6, ($0.longitude * 1e6).rounded() / 1e6, $0.timestamp.timeIntervalSince1970]
        })
        return try sealContent(JSONEncoder().encode(payload), key: key, epoch: epoch, context: historyContext(circleID: circleID, deviceID: day.deviceID, day: day.day))
    }

    static func openHistory(
        _ blob: Data, deviceID: String, day: String, circleID: String, keyForEpoch: (Int64) -> SymmetricKey?
    ) throws -> HistoryDay? {
        guard let (plain, _) = try openContent(blob, context: historyContext(circleID: circleID, deviceID: deviceID, day: day), keyForEpoch: keyForEpoch)
        else { return nil }
        let payload = try JSONDecoder().decode(HistoryPayload.self, from: plain)
        guard payload.p.count <= HistoryDay.maxPoints else { throw ProtocolError.malformed }
        let points = try payload.p.map { triple -> HistoryDay.Point in
            guard triple.count == 3, (-90 ... 90).contains(triple[0]), (-180 ... 180).contains(triple[1]), triple[2] > 0
            else { throw ProtocolError.malformed }
            return HistoryDay.Point(latitude: triple[0], longitude: triple[1], timestamp: Date(timeIntervalSince1970: triple[2]))
        }
        return HistoryDay(deviceID: deviceID, day: day, points: points)
    }

    static func historyRecordStatement(circleID: String, deviceID: String, day: String, blob: Data) -> Data {
        Wire.context("leuchtturm/v1/history-record", circleID, deviceID, day) + blob
    }

    static func historyContext(circleID: String, deviceID: String, day: String) -> Data {
        Wire.context("leuchtturm/v1/history", circleID, deviceID, day)
    }
}
