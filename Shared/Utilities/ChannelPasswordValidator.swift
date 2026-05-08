import Foundation

enum ChannelPasswordError: LocalizedError, Equatable, LocalProblemPayloadConvertible {
    case invalidLength

    var errorDescription: String? {
        switch self {
        case .invalidLength:
            return LocalizationProvider.localized("channel_password_invalid_length")
        }
    }

    var localProblemPayload: LocalProblemPayload {
        switch self {
        case .invalidLength:
            return LocalProblemPayload(
                code: "invalid_password",
                category: .validation,
                message: LocalizationProvider.localized("channel_password_invalid_length"),
                detail: "channel password length must be between 8 and 128 characters"
            )
        }
    }
}

enum ChannelPasswordValidator {
    static func validate(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let len = trimmed.count
        guard (8...128).contains(len) else { throw ChannelPasswordError.invalidLength }
        return trimmed
    }
}
