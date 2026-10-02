import Foundation

/// An array that keeps the elements that decode and drops the ones that don't.
/// The server can grow a new media kind or tweet shape before this client knows
/// it; without this, one unknown element fails the decode of the whole page, and
/// the user sees an error where one attachment should have been skipped.
struct LossyArray<Element: Decodable>: Decodable {
    let elements: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var kept: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                kept.append(element)
            } else {
                _ = try? container.decode(Skipped.self)
            }
        }
        elements = kept
    }

    /// Accepts any JSON value without reading it, so the container always moves
    /// past an element that failed to decode, whether it is an object, `null`,
    /// a string, a number or a nested array. A type that only decoded from an
    /// object would leave the index in place and loop forever.
    private struct Skipped: Decodable {
        init(from decoder: Decoder) throws {}
    }
}

extension KeyedDecodingContainer {
    /// The array at `key`, element by element, without failing for an element
    /// that doesn't decode; empty when the key is absent or null.
    func decodeLossy<Element: Decodable>(_ type: Element.Type, forKey key: Key) throws -> [Element] {
        try decodeIfPresent(LossyArray<Element>.self, forKey: key)?.elements ?? []
    }
}
