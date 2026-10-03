import Foundation
import Testing
#if os(macOS)
import AppKit
import ImageIO
#endif
@testable import PushGoAppleCore

struct ValidationUtilitiesTests {
#if os(macOS)
    @Test
    @MainActor
    func macOSImageExportProducesDecodablePixelExactPNG() throws {
        let canonicalBase64 =
            "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAFElEQVR42mNkYPj/n4GBgYGJAQoAHgQCAf2fP6sAAAAASUVORK5CYII="
        let canonicalData = try #require(Data(base64Encoded: canonicalBase64))
        let sourceImage = try #require(NSImage(data: canonicalData))
        let exportedData = try #require(PushGoMacImageExportEncoder.pngData(from: sourceImage))

        _ = try #require(NSBitmapImageRep(data: exportedData))
        let canonicalPixels = try #require(normalizedRGBA8Pixels(from: canonicalData))
        let exportedPixels = try #require(normalizedRGBA8Pixels(from: exportedData))
        #expect(exportedPixels.width == canonicalPixels.width)
        #expect(exportedPixels.height == canonicalPixels.height)
        #expect(exportedPixels.data == canonicalPixels.data)
    }

    private func normalizedRGBA8Pixels(from data: Data) -> (width: Int, height: Int, data: Data)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else {
            return nil
        }

        let width = image.width
        let height = image.height
        var pixels = Data(count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return rendered ? (width, height, pixels) : nil
    }
#endif

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
    func localValidationErrorsPreserveStructuredUserFacingMessages() {
        let invalidChannelId = AppError.wrap(
            ChannelIdError.invalid,
            fallbackMessage: LocalizationProvider.localized("operation_failed")
        )
        #expect(invalidChannelId.code == "invalid_channel_id")
        #expect(invalidChannelId.errorDescription == LocalizationProvider.localized("channel_id_invalid"))

        let invalidPassword = AppError.wrap(
            ChannelPasswordError.invalidLength,
            fallbackMessage: LocalizationProvider.localized("operation_failed")
        )
        #expect(invalidPassword.code == "invalid_password")
        #expect(invalidPassword.errorDescription == LocalizationProvider.localized("channel_password_invalid_length"))
    }

    @Test
    func localErrorCodeMappingRefinesGenericFallbackMessages() {
        let missingProviderToken = AppError.typedLocal(
            code: "provider_token_missing",
            category: .validation,
            message: LocalizationProvider.localized("operation_failed"),
            detail: "provider token missing"
        )
        #expect(
            missingProviderToken.errorDescription
                == LocalizationProvider.localized("device_push_route_not_ready")
        )

        let failedMessageLoad = AppError.typedLocal(
            code: "message_page_load_failed",
            category: .local,
            message: LocalizationProvider.localized("operation_failed"),
            detail: "failed to load message page"
        )
        #expect(
            failedMessageLoad.errorDescription
                == LocalizationProvider.localized("message_load_failed")
        )

        let missingEventChannel = AppError.typedLocal(
            code: "event_missing_channel_id",
            category: .validation,
            message: LocalizationProvider.localized("operation_failed"),
            detail: "event missing channel_id"
        )
        #expect(
            missingEventChannel.errorDescription
                == LocalizationProvider.localized("event_missing_channel_id")
        )

        let failedWatchModeChange = AppError.typedLocal(
            code: "watch_mode_change_failed",
            category: .local,
            message: LocalizationProvider.localized("operation_failed"),
            detail: "apple watch mode switch failed"
        )
        #expect(
            failedWatchModeChange.errorDescription
                == LocalizationProvider.localized("watch_mode_change_failed")
        )
    }

    @Test
    func keychainErrorsPreserveLocalizedStructuredPayloads() {
        let error = AppError.wrap(
            KeychainStoreError.unexpectedData,
            fallbackMessage: LocalizationProvider.localized("operation_failed")
        )
        #expect(error.code == "keychain_unexpected_data")
        #expect(error.errorDescription == LocalizationProvider.localized("keychain_unexpected_data"))
    }

    @Test
    func localizationProviderReturnsFallbackKeyWhenTranslationIsMissing() {
        #expect(LocalizationProvider.localized("__pushgo_missing_key__") == "__pushgo_missing_key__")
    }
}
