import Foundation

extension KeyedDecodingContainer {
    /// Decodes an optional value, treating a value of the wrong type as absent. Log formats change
    /// between tool versions, and one odd field must not drop the whole line.
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }

    /// True when the key exists and its value is not `null`, whatever its type.
    func hasNonNullValue(_ key: Key) -> Bool {
        contains(key) && (try? decodeNil(forKey: key)) == false
    }
}
