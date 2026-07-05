import Foundation

enum PushGoSystemPrivacyPolicy {
    static func privacy(
        for message: PushMessage,
        settings: SystemIntegrationSettings = SystemIntegrationSettings()
    ) -> PushGoSystemSummary.Privacy {
        let hasUnsuccessfulDecryption = message.decryptionState != nil
            && message.decryptionState != .decryptOk
        let hasEncryptedPayloadWithoutSuccessfulDecryption = message.decryptionState != .decryptOk
            && message.isEncrypted
        let isSensitive = hasUnsuccessfulDecryption
            || hasEncryptedPayloadWithoutSuccessfulDecryption
            || message.status == .partiallyDecrypted
            || message.status == .missing
        return PushGoSystemSummary.Privacy(
            mayIndexTitle: settings.systemSearchEnabled,
            mayIndexBody: settings.systemSearchEnabled
                && settings.includeMessageBodyInSearch
                && !isSensitive,
            mayExposeMetadata: settings.systemSearchEnabled
                && settings.includeMetadataInSearch
                && !isSensitive,
            isEncryptedOrSensitive: isSensitive
        )
    }

    static func privacy(
        kind: PushGoSystemEntityKind,
        channelID: String?,
        decryptionState: PushMessage.DecryptionState?,
        settings: SystemIntegrationSettings = SystemIntegrationSettings()
    ) -> PushGoSystemSummary.Privacy {
        let entityIndexEnabled = kind == .message || settings.indexEventsAndThings
        let isSensitive = decryptionState != nil && decryptionState != .decryptOk
        let canIndex = settings.systemSearchEnabled
            && entityIndexEnabled
        return PushGoSystemSummary.Privacy(
            mayIndexTitle: canIndex,
            mayIndexBody: canIndex && !isSensitive,
            mayExposeMetadata: canIndex && settings.includeMetadataInSearch && !isSensitive,
            isEncryptedOrSensitive: isSensitive
        )
    }
}
