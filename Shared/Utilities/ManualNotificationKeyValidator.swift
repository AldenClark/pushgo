import Foundation

enum ManualNotificationKeyEncoding: String, CaseIterable, Identifiable {
    case plaintext
    case base64
    case hex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .plaintext: "Plaintext"
        case .base64: "Base64"
        case .hex: "Hex"
        }
    }

    static func normalized(from raw: String?) -> ManualNotificationKeyEncoding {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "plain", "plaintext", "text":
            .plaintext
        case "hex":
            .hex
        default:
            .base64
        }
    }
}

enum ManualNotificationKeyValidationError: LocalizedError, LocalProblemPayloadConvertible {
    case invalidBase64
    case invalidHex
    case invalidLength

    var errorDescription: String? {
        switch self {
        case .invalidBase64:
            return LocalizationProvider.localized("the_selected_format_is_not_valid_base64_please_check_your_input")
        case .invalidHex:
            return LocalizationProvider.localized("the_selected_format_is_not_a_valid_hex_please_check_your_input")
        case .invalidLength:
            return LocalizationProvider.localized("key_length_must_be_128_192_256_bits")
        }
    }

    var localProblemPayload: LocalProblemPayload {
        switch self {
        case .invalidBase64:
            return LocalProblemPayload(
                code: "manual_notification_key_invalid_base64",
                category: .validation,
                message: LocalizationProvider.localized(
                    "the_selected_format_is_not_valid_base64_please_check_your_input"
                ),
                detail: "manual notification key is not valid base64"
            )
        case .invalidHex:
            return LocalProblemPayload(
                code: "manual_notification_key_invalid_hex",
                category: .validation,
                message: LocalizationProvider.localized(
                    "the_selected_format_is_not_a_valid_hex_please_check_your_input"
                ),
                detail: "manual notification key is not valid hex"
            )
        case .invalidLength:
            return LocalProblemPayload(
                code: "manual_notification_key_invalid_length",
                category: .validation,
                message: LocalizationProvider.localized("key_length_must_be_128_192_256_bits"),
                detail: "manual notification key length must be 128/192/256 bits"
            )
        }
    }
}

enum ManualNotificationKeyValidator {
    static let allowedKeyByteCounts: Set<Int> = [16, 24, 32]

    static func normalizedKeyData(
        from input: String,
        encoding: ManualNotificationKeyEncoding
    ) throws -> Data {
        let data: Data
        switch encoding {
        case .plaintext:
            data = Data(input.utf8)
        case .base64:
            guard let decoded = Data(base64Encoded: input) else {
                throw ManualNotificationKeyValidationError.invalidBase64
            }
            data = decoded
        case .hex:
            let clean = input.filter { !$0.isWhitespace }
            guard clean.count.isMultiple(of: 2) else {
                throw ManualNotificationKeyValidationError.invalidHex
            }
            var bytes = [UInt8]()
            bytes.reserveCapacity(clean.count / 2)
            var index = clean.startIndex
            while index < clean.endIndex {
                let next = clean.index(index, offsetBy: 2)
                let slice = clean[index ..< next]
                guard let value = UInt8(slice, radix: 16) else {
                    throw ManualNotificationKeyValidationError.invalidHex
                }
                bytes.append(value)
                index = next
            }
            data = Data(bytes)
        }

        guard allowedKeyByteCounts.contains(data.count) else {
            throw ManualNotificationKeyValidationError.invalidLength
        }
        return data
    }
}
