import Foundation
import Testing
@testable import PushGoAppleCore

struct ValidationUtilitiesTests {
    @Test
    func channelNameNormalizationTrimsWhitespace() throws {
        #expect(try ChannelNameValidator.normalize("  alerts  ") == "alerts")
    }

    @Test
    func channelNameNormalizationRejectsControlCharacters() {
        #expect(throws: ChannelNameError.invalidCharacter("\u{0007}")) {
            try ChannelNameValidator.normalize("ops\u{0007}")
        }
    }

    @Test
    func channelIdNormalizationMapsAmbiguousCharacters() throws {
        #expect(
            try ChannelIdValidator.normalize("O123456789ABCDEFGHJKLMNPQR")
                == "0123456789ABCDEFGHJK1MNPQR"
        )
    }

    @Test
    func channelPasswordValidationRejectsShortValues() {
        #expect(throws: ChannelPasswordError.invalidLength) {
            try ChannelPasswordValidator.validate("1234567")
        }
    }

    @Test
    func localizationProviderReturnsFallbackKeyWhenTranslationIsMissing() {
        #expect(LocalizationProvider.localized("__pushgo_missing_key__") == "__pushgo_missing_key__")
    }
}
