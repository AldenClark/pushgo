import Foundation

enum PushGoSystemPrivacyPolicy {
    static func privacy(
        for message: PushMessage,
        settings: SystemIntegrationSettings = SystemIntegrationSettings()
    ) -> PushGoSystemSummary.Privacy {
        let isSensitive = message.isEncrypted
            || message.decryptionState == .decryptFailed
            || message.status == .partiallyDecrypted
            || message.status == .missing
            || settings.excludesChannel(message.channel)
        return PushGoSystemSummary.Privacy(
            mayIndexTitle: settings.systemSearchEnabled && !settings.excludesChannel(message.channel),
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
        let isSensitive = decryptionState == .decryptFailed
            || settings.excludesChannel(channelID)
        let canIndex = settings.systemSearchEnabled
            && entityIndexEnabled
            && !settings.excludesChannel(channelID)
        return PushGoSystemSummary.Privacy(
            mayIndexTitle: canIndex,
            mayIndexBody: canIndex && !isSensitive,
            mayExposeMetadata: canIndex && settings.includeMetadataInSearch && !isSensitive,
            isEncryptedOrSensitive: isSensitive
        )
    }
}
