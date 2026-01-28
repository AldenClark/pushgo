import Foundation

enum ChannelPasswordError: LocalizedError, Equatable {
    case invalidLength

    var errorDescription: String? {
        switch self {
        case .invalidLength:
            return LocalizationProvider.localized("channel_password_invalid_length")
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
