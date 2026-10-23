import Foundation

/// Any JSON value. Used for tool arguments and JSON schemas, which have no fixed shape.
indirect enum JSONValue: Equatable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Not JSON") }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var numberValue: Double? { if case .number(let n) = self { return n }; return nil }
    var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }

    /// For `JSONSerialization`.
    var any: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let v): return v
        case .number(let v): return v
        case .string(let v): return v
        case .array(let v): return v.map(\.any)
        case .object(let v): return v.mapValues(\.any)
        }
    }

    /// From what `JSONSerialization` gives back. Anything that is not JSON becomes null.
    static func from(_ any: Any?) -> JSONValue {
        switch any {
        case let n as NSNumber:
            return CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
        case let v as String: return .string(v)
        case let v as [Any]: return .array(v.map { from($0) })
        case let v as [String: Any]: return .object(v.mapValues { from($0) })
        default: return .null
        }
    }

    static func parse(_ text: String) -> JSONValue? {
        guard let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return from(object)
    }

    /// Compact, key-sorted text.
    var text: String {
        guard JSONSerialization.isValidJSONObject(any) || self.isScalar,
              let data = try? JSONSerialization.data(withJSONObject: any, options: [.sortedKeys, .fragmentsAllowed]) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    private var isScalar: Bool {
        switch self { case .array, .object: return false; default: return true }
    }
}
