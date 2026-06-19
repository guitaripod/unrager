import Foundation

/// Centralized JSON coding for the unrager API.
///
/// The server serializes with literal snake_case field names; every model in
/// this kit declares explicit `CodingKeys`, so no global key strategy is set
/// (that keeps the externally-tagged `MediaKind` decoder unambiguous).
public enum UnragerJSON {
    /// Value-type ISO-8601 parsers (Sendable, unlike `ISO8601DateFormatter`).
    private static let isoPlain = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
    private static let isoFractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = try? isoPlain.parse(raw) { return date }
            if let date = try? isoFractional.parse(raw) { return date }
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unrecognized date: \(raw)")
        }
        return decoder
    }()

    public static let encoder = JSONEncoder()

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch let error as DecodingError {
            throw APIError.decoding(String(describing: error))
        }
    }
}
