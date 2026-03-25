import Foundation
import Testing
@testable import PushGoAppleCore

struct ManualNotificationKeyValidatorTests {
    @Test
    func normalizedEncodingMapsAliases() {
        #expect(ManualNotificationKeyEncoding.normalized(from: nil) == .base64)
        #expect(ManualNotificationKeyEncoding.normalized(from: "plain") == .plaintext)
        #expect(ManualNotificationKeyEncoding.normalized(from: " text ") == .plaintext)
        #expect(ManualNotificationKeyEncoding.normalized(from: "HEX") == .hex)
    }

    @Test
    func normalizedKeyDataAcceptsHexWithWhitespace() throws {
        let data = try ManualNotificationKeyValidator.normalizedKeyData(
            from: "0011 2233 4455 6677 8899 aabb ccdd eeff",
            encoding: .hex
        )
        #expect(data.count == 16)
    }

    @Test
    func normalizedKeyDataRejectsInvalidBase64() {
        #expect(throws: ManualNotificationKeyValidationError.invalidBase64) {
            try ManualNotificationKeyValidator.normalizedKeyData(from: "%%%invalid%%%", encoding: .base64)
        }
    }

    @Test
    func normalizedKeyDataRejectsOddHexLength() {
        #expect(throws: ManualNotificationKeyValidationError.invalidHex) {
            try ManualNotificationKeyValidator.normalizedKeyData(from: "abc", encoding: .hex)
        }
    }

    @Test
    func normalizedKeyDataRejectsInvalidHexCharacters() {
        #expect(throws: ManualNotificationKeyValidationError.invalidHex) {
            try ManualNotificationKeyValidator.normalizedKeyData(
                from: "0011 2233 4455 6677 8899 aabb ccdd zzff",
                encoding: .hex
            )
        }
    }

    @Test
    func normalizedKeyDataRejectsInvalidLength() {
        #expect(throws: ManualNotificationKeyValidationError.invalidLength) {
            try ManualNotificationKeyValidator.normalizedKeyData(from: "short", encoding: .plaintext)
        }
    }
}
