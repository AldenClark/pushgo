import Foundation

struct UserInfoSanitizer {
    static func sanitize(_ userInfo: [AnyHashable: Any]) -> [String: Any] {
        userInfo.reduce(into: [String: Any]()) { result, element in
            guard let key = element.key as? String else { return }
            if let value = sanitize(value: element.value) {
                result[key] = value
            }
        }
    }

    private static func sanitize(value: Any) -> Any? {
        switch value {
        case let dict as [AnyHashable: Any]:
            let cleaned = sanitizeDictionary(dict)
            return cleaned.isEmpty ? nil : cleaned
        case let array as [Any]:
            let cleaned = array.compactMap { sanitize(value: $0) }
            return cleaned
        case is String, is Int, is Double, is Bool:
            return value
        case let value as Float:
            return Double(value)
        case let value as Date:
            return iso8601String(from: value)
        case let value as Data:
            return value.base64EncodedString()
        default:
            return nil
        }
    }

    private static func sanitizeDictionary(_ dict: [AnyHashable: Any]) -> [String: Any] {
        dict.reduce(into: [String: Any]()) { result, element in
            guard let key = element.key as? String else { return }
            if let value = sanitize(value: element.value) {
                result[key] = value
            }
        }
    }

    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
