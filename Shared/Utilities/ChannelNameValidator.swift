import Foundation

enum ChannelNameError: LocalizedError, Equatable {
    case empty
    case tooLong(Int)
    case invalidCharacter(Character)

    var errorDescription: String? {
        switch self {
        case .empty:
            return LocalizationProvider.localized("channel_name_required")
        case let .tooLong(max):
            return LocalizationProvider.localized("channel_name_too_long", max)
        case let .invalidCharacter(char):
            return LocalizationProvider.localized("channel_name_invalid_character_placeholder", String(char))
        }
    }
}

enum ChannelNameValidator {
    static let maxLength = 128

    static func normalize(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ChannelNameError.empty }
        if trimmed.count > maxLength {
            throw ChannelNameError.tooLong(maxLength)
        }

        if let invalidScalar = trimmed.unicodeScalars.first(where: { $0.properties.generalCategory == .control }) {
            throw ChannelNameError.invalidCharacter(Character(invalidScalar))
        }
        return trimmed
    }
}

enum ChannelIdError: LocalizedError, Equatable {
    case empty
    case invalid

    var errorDescription: String? {
        switch self {
        case .empty:
            return LocalizationProvider.localized("channel_id_required")
        case .invalid:
            return LocalizationProvider.localized("channel_id_invalid")
        }
    }
}

enum ChannelIdValidator {
    static let expectedLength = 26
    private static let alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

    static func normalize(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ChannelIdError.empty }

        var output = String()
        output.reserveCapacity(expectedLength)

        for ch in trimmed {
            if ch == "-" || ch.isWhitespace {
                continue
            }
            let upper = String(ch).uppercased()
            let mapped: String
            switch upper {
            case "O":
                mapped = "0"
            case "I", "L":
                mapped = "1"
            default:
                mapped = upper
            }

            guard mapped.count == 1, let scalar = mapped.unicodeScalars.first else {
                throw ChannelIdError.invalid
            }
            guard scalar.isASCII, alphabet.contains(mapped) else {
                throw ChannelIdError.invalid
            }
            output.append(Character(mapped))
        }

        guard output.count == expectedLength else { throw ChannelIdError.invalid }
        return output
    }
}
