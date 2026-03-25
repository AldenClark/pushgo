import Foundation

private func anyCodableIsNil(_ value: Any) -> Bool {
    let mirror = Mirror(reflecting: value)
    return mirror.displayStyle == .optional && mirror.children.isEmpty
}

private enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case int64(Int64)
    case uint(UInt)
    case uint64(UInt64)
    case double(Double)
    case float(Float)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let boolValue = try? container.decode(Bool.self) {
            self = .bool(boolValue)
        } else if let intValue = try? container.decode(Int.self) {
            self = .int(intValue)
        } else if let int64Value = try? container.decode(Int64.self) {
            self = .int64(int64Value)
        } else if let uintValue = try? container.decode(UInt.self) {
            self = .uint(uintValue)
        } else if let uint64Value = try? container.decode(UInt64.self) {
            self = .uint64(uint64Value)
        } else if let doubleValue = try? container.decode(Double.self) {
            self = .double(doubleValue)
        } else if let floatValue = try? container.decode(Float.self) {
            self = .float(floatValue)
        } else if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
        } else if let arrayValue = try? container.decode([JSONValue].self) {
            self = .array(arrayValue)
        } else if let objectValue = try? container.decode([String: JSONValue].self) {
            self = .object(objectValue)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .int(value):
            try container.encode(value)
        case let .int64(value):
            try container.encode(value)
        case let .uint(value):
            try container.encode(value)
        case let .uint64(value):
            try container.encode(value)
        case let .double(value):
            try container.encode(value)
        case let .float(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(values):
            try container.encode(values)
        case let .object(value):
            try container.encode(value)
        }
    }

    static func from(any value: Any) -> JSONValue? {
        if anyCodableIsNil(value) { return .null }
        switch value {
        case let boolValue as Bool:
            return .bool(boolValue)
        case let intValue as Int:
            return .int(intValue)
        case let int64Value as Int64:
            return .int64(int64Value)
        case let uintValue as UInt:
            return .uint(uintValue)
        case let uint64Value as UInt64:
            return .uint64(uint64Value)
        case let doubleValue as Double:
            return .double(doubleValue)
        case let floatValue as Float:
            return .float(floatValue)
        case let stringValue as String:
            return .string(stringValue)
        case let arrayValue as [Any]:
            return .array(arrayValue.compactMap { JSONValue.from(any: $0) })
        case let objectValue as [String: Any]:
            return .object(objectValue.reduce(into: [String: JSONValue]()) { result, element in
                guard let converted = JSONValue.from(any: element.value) else { return }
                result[element.key] = converted
            })
        default:
            return nil
        }
    }

    func asAny() -> Any {
        switch self {
        case .null:
            return Optional<Any>.none as Any
        case let .bool(value):
            return value
        case let .int(value):
            return value
        case let .int64(value):
            return value
        case let .uint(value):
            return value
        case let .uint64(value):
            return value
        case let .double(value):
            return value
        case let .float(value):
            return value
        case let .string(value):
            return value
        case let .array(values):
            return values.map { $0.asAny() }
        case let .object(value):
            return value.mapValues { $0.asAny() }
        }
    }
}

struct AnyCodable: Codable, Equatable, Sendable {
    private let storage: JSONValue

    var value: Any {
        storage.asAny()
    }

    init(_ value: Any) {
        storage = JSONValue.from(any: value) ?? .null
    }

    init(from decoder: Decoder) throws {
        storage = try JSONValue(from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        try storage.encode(to: encoder)
    }

    static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        lhs.storage == rhs.storage
    }
}
