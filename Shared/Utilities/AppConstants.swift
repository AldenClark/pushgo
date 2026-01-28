import CoreFoundation
import Foundation
import ImageIO
import Security
import UniformTypeIdentifiers
import UserNotifications

enum AppConstants {
    static let appGroupIdentifier = "group.ethan.pushgo.messages"
    static let serverConfigFilename = "server_config.json"
    static let messagesFilename = "messages.json"
    static let customRingtoneRelativePath = "Library/Sounds"
    static let longRingtoneRelativePath = "Library/Sounds/Long"
    static let longRingtonePrefix = "pushgo_long."
    static let defaultServerAddress = "https://gateway.pushgo.dev"
    static let messageSyncNotificationName = "io.ethan.pushgo.message-sync"
    static let copyToastNotificationName = "io.ethan.pushgo.copy-toast"
    static let nceMarkdownCategoryIdentifier = "PUSHGO_MD"
    static let ncePlainCategoryIdentifier = "PUSHGO_PLAIN"
    static let actionCopyIdentifier = "PUSHGO_ACTION_COPY"
    static let actionMarkReadIdentifier = "PUSHGO_ACTION_MARK_READ"
    static let actionDeleteIdentifier = "PUSHGO_ACTION_DELETE"
    static let markdownRenderPayloadKey = "body_render_payload"
    static let markdownRenderPayloadMaxCharacters = 4000
    static let markdownRenderPayloadListSoftCap = 2400
    static let markdownRenderPayloadMinCharacters = 240
    static let markdownRenderPayloadUserInfoMaxCharacters = 1200
    static let markdownRenderPayloadUserInfoMinCharacters = 200
    static let markdownRenderPayloadUserInfoMaxBytes = 2048
    static let maxStoredMessages = 100_000
    static let pruneBatchSize = 200
    static let autoCleanupBatchSize = 300
    static let performanceSampleWindow = 6
    static let performanceDegradationCooldownSeconds: TimeInterval = 180
    static let performanceDegradationNotificationName = "io.ethan.pushgo.performance-degradation"
    static let performanceDegradationOperationKey = "operation"
    static let performanceDegradationAverageMsKey = "averageMs"
    static let maxMessageImageBytes: Int64 = 10 * 1024 * 1024
    static let deviceRegistrationTimeout: TimeInterval = 15
    static let defaultRingtoneFilenameKey = "default_ringtone_filename"
    static let fallbackRingtoneFilename = "notification-sound.caf"
    static let autoCleanupEnabledKey = "auto_cleanup_enabled"

    static var nceCategories: Set<String> {
        [nceMarkdownCategoryIdentifier, ncePlainCategoryIdentifier]
    }

    static var defaultServerURL: URL? {
        URL(string: defaultServerAddress)
    }

    static var apnsEnvironment: String? {
#if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        let value = SecTaskCopyValueForEntitlement(task, "aps-environment" as CFString, nil)
        return value as? String
#else
        if let value = apnsEnvironmentFromMobileProvision() {
            return value
        }
#if targetEnvironment(simulator)
        return "development"
#else
        return "production"
#endif
#endif
    }

#if !os(macOS)
    private static func apnsEnvironmentFromMobileProvision() -> String? {
        guard let path = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") else {
            return nil
        }

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let content = String(data: data, encoding: .isoLatin1)
        else {
            return nil
        }

        guard let start = content.range(of: "<?xml"),
              let end = content.range(of: "</plist>")
        else {
            return nil
        }

        let plistString = String(content[start.lowerBound..<end.upperBound])
        guard let plistData = plistString.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(
                  from: plistData,
                  options: [],
                  format: nil
              ) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any]
        else {
            return nil
        }

        return entitlements["aps-environment"] as? String
    }
#endif
}

enum MessageTimestampFormatter {
    static func listTimestamp(
        for date: Date,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let startOfToday = calendar.startOfDay(for: now)
        let startOfDate = calendar.startOfDay(for: date)
        let dayDelta = calendar.dateComponents([.day], from: startOfDate, to: startOfToday).day ?? 0

        if calendar.isDate(date, inSameDayAs: now) {
            return formattedTime(date, locale: locale, calendar: calendar)
        }
        if dayDelta == 1 || dayDelta == 2 {
            return formattedRelative(date, relativeTo: now, locale: locale)
        }
        if dayDelta > 2 && dayDelta < 7 {
            return formatted(date, template: "EEE", locale: locale, calendar: calendar)
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return formatted(date, template: "MMMd", locale: locale, calendar: calendar)
        }
        return formatted(date, template: "yMMMd", locale: locale, calendar: calendar)
    }

    private static func formattedTime(_ date: Date, locale: Locale, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static func formattedRelative(_ date: Date, relativeTo now: Date, locale: Locale) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: now)
    }

    private static func formatted(
        _ date: Date,
        template: String,
        locale: Locale,
        calendar: Calendar
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
}


enum URLSanitizer {
    static func isAllowedRemoteURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" else { return false }
        return url.host?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    static func sanitizeHTTPSURL(_ url: URL?) -> URL? {
        guard let url, isAllowedRemoteURL(url) else { return nil }
        return url
    }

    static func resolveHTTPSURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return nil }
        return sanitizeHTTPSURL(url)
    }

    static func validatedServerURL(from raw: String) -> URL? {
        guard let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(), scheme == "https",
              let host = components.host, !host.isEmpty
        else { return nil }
        return components.url
    }

    static func validatedServerURL(_ baseURL: URL) -> URL? {
        guard let scheme = baseURL.scheme?.lowercased(), scheme == "https",
              let host = baseURL.host, !host.isEmpty
        else { return nil }
        return baseURL
    }
}

enum MessageIdExtractor {
    static func extract(from payload: [String: Any]) -> UUID? {
        if let value = payload["messageId"], let uuid = parseUUID(from: value) {
            return uuid
        }
        if let value = payload["message_id"], let uuid = parseUUID(from: value) {
            return uuid
        }
        if let value = payload["id"], let uuid = parseUUID(from: value) {
            return uuid
        }
        if let value = payload["serverId"], let uuid = parseUUID(from: value) {
            return uuid
        }
        if let value = payload["server_id"], let uuid = parseUUID(from: value) {
            return uuid
        }
        if let meta = payload["meta"] as? [String: AnyCodable] {
            if let value = meta["messageId"]?.value, let uuid = parseUUID(from: value) {
                return uuid
            }
            if let value = meta["message_id"]?.value, let uuid = parseUUID(from: value) {
                return uuid
            }
            if let value = meta["id"]?.value, let uuid = parseUUID(from: value) {
                return uuid
            }
            if let value = meta["serverId"]?.value, let uuid = parseUUID(from: value) {
                return uuid
            }
            if let value = meta["server_id"]?.value, let uuid = parseUUID(from: value) {
                return uuid
            }
        }
        if let meta = payload["meta"] as? [String: Any] {
            if let value = meta["messageId"], let uuid = parseUUID(from: value) {
                return uuid
            }
            if let value = meta["message_id"], let uuid = parseUUID(from: value) {
                return uuid
            }
            if let value = meta["id"], let uuid = parseUUID(from: value) {
                return uuid
            }
            if let value = meta["serverId"], let uuid = parseUUID(from: value) {
                return uuid
            }
            if let value = meta["server_id"], let uuid = parseUUID(from: value) {
                return uuid
            }
        }
        return nil
    }

    private static func parseUUID(from value: Any) -> UUID? {
        if let string = value as? String {
            return UUID(uuidString: string)
        }
        return nil
    }
}

struct NormalizedNotificationPayload {
    let title: String
    let body: String
    let channel: String?
    let url: URL?
    let decryptionState: PushMessage.DecryptionState?
    let rawPayload: [String: AnyCodable]
    let messageId: UUID?
}

enum NotificationPayloadNormalizer {
    static func normalize(
        content: UNNotificationContent,
        requestId: String
    ) -> NormalizedNotificationPayload {
        var sanitizedPayload = UserInfoSanitizer.sanitize(content.userInfo)
        sanitizedPayload["_notificationRequestId"] = requestId

        let title = content.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = title.isEmpty
            ? (sanitizedPayload["title"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            : content.title
        let body = content.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let payloadBody = (sanitizedPayload["body"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBody = payloadBody ?? (body.isEmpty ? "" : content.body)

        let channelIdentifier = content.threadIdentifier.isEmpty
            ? ((sanitizedPayload["channel_id"] as? String)
                ?? (sanitizedPayload["channel"] as? String))
            : content.threadIdentifier
        let trimmedChannel = channelIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedChannel = trimmedChannel?.isEmpty == true ? nil : trimmedChannel
        let url = URLSanitizer.sanitizeHTTPSURL((sanitizedPayload["url"] as? String).flatMap(URL.init(string:)))
        let stateRaw = sanitizedPayload["decryptionState"] as? String
        let decryptionState = stateRaw.flatMap(PushMessage.DecryptionState.init(rawValue:))

        if sanitizedPayload["title"] == nil {
            sanitizedPayload["title"] = resolvedTitle
        }
        if sanitizedPayload["body"] == nil {
            sanitizedPayload["body"] = resolvedBody
        }
        if let resolvedChannel, sanitizedPayload["channel_id"] == nil {
            sanitizedPayload["channel_id"] = resolvedChannel
        }
        if let url, sanitizedPayload["url"] == nil {
            sanitizedPayload["url"] = url.absoluteString
        }

        let rawPayload = sanitizedPayload.reduce(into: [String: AnyCodable]()) { result, element in
            result[element.key] = AnyCodable(element.value)
        }
        let messageId = MessageIdExtractor.extract(from: sanitizedPayload)

        return NormalizedNotificationPayload(
            title: resolvedTitle,
            body: resolvedBody,
            channel: resolvedChannel,
            url: url,
            decryptionState: decryptionState,
            rawPayload: rawPayload,
            messageId: messageId
        )
    }
}

enum NotificationMediaResolver {
    static func urlValue(in userInfo: [AnyHashable: Any], keys: [String]) -> URL? {
        for key in keys {
            if let text = (userInfo[key] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                let url = URLSanitizer.resolveHTTPSURL(from: text)
            {
                return url
            }
        }
        return nil
    }

    static func attachments(
        from userInfo: [AnyHashable: Any],
        candidates: [(key: String, identifier: String)],
        maxBytes: Int64 = AppConstants.maxMessageImageBytes
    ) async -> [UNNotificationAttachment] {
        var attachments: [UNNotificationAttachment] = []
        for candidate in candidates {
            guard let url = urlValue(in: userInfo, keys: [candidate.key]) else { continue }
            if let attachment = await downloadAttachment(
                from: url,
                identifier: candidate.identifier,
                maxBytes: maxBytes
            ) {
                attachments.append(attachment)
            }
        }
        return attachments
    }

    static func isImageData(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source)
        else {
            return false
        }
        if let utType = UTType(type as String) {
            return utType.conforms(to: .image)
        }
        return false
    }

    static func normalizedExtension(from url: URL, utType: UTType?) -> String {
        let ext = url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ext.isEmpty {
            return ext
        }
        if let preferred = utType?.preferredFilenameExtension?.trimmingCharacters(in: .whitespacesAndNewlines),
           !preferred.isEmpty
        {
            return preferred
        }
        return "jpg"
    }

    private static func downloadAttachment(
        from url: URL,
        identifier: String,
        maxBytes: Int64
    ) async -> UNNotificationAttachment? {
        guard URLSanitizer.isAllowedRemoteURL(url) else { return nil }
        do {
            let data = try await SharedImageCache.fetchData(from: url, maxBytes: maxBytes, timeout: 10)
            guard isImageData(data) else { return nil }

            let fileExt = normalizedExtension(from: url, utType: nil)
            let targetURL = SharedImageCache.cachedFileURL(for: url)
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(fileExt)")
            if !FileManager.default.fileExists(atPath: targetURL.path) {
                try data.write(to: targetURL, options: .atomic)
            }

            let utType = UTType(filenameExtension: fileExt) ?? .image
            let typeHint = utType.identifier
            let options: [AnyHashable: Any] = [UNNotificationAttachmentOptionsTypeHintKey: typeHint]
            return try UNNotificationAttachment(identifier: identifier, url: targetURL, options: options)
        } catch {
            return nil
        }
    }
}

private let darwinNotificationCallback: CFNotificationCallback = { _, observer, _, _, _ in
    guard let observer else { return }
    let unmanaged = Unmanaged<DarwinNotificationObserver>.fromOpaque(observer)
    unmanaged.takeUnretainedValue().invoke()
}

final class DarwinNotificationObserver {
    typealias Handler = () -> Void

    private let handler: Handler
    private let name: CFNotificationName
    private var observerPointer: UnsafeMutableRawPointer?

    init(name: String, handler: @escaping Handler) {
        self.handler = handler
        self.name = CFNotificationName(name as CFString)
        observerPointer = nil
        let pointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        observerPointer = pointer
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(
            center,
            pointer,
            darwinNotificationCallback,
            self.name.rawValue,
            nil,
            .deliverImmediately,
        )
    }

    deinit {
        if let observerPointer {
            let center = CFNotificationCenterGetDarwinNotifyCenter()
            CFNotificationCenterRemoveObserver(center, observerPointer, name, nil)
        }
    }

    fileprivate func invoke() {
        handler()
    }
}

enum DarwinNotificationPoster {
    static func post(name: String) {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let cfName = CFNotificationName(name as CFString)
        CFNotificationCenterPostNotification(center, cfName, nil, nil, true)
    }
}

enum PerformanceOperation: String, Sendable {
    case listRefresh
    case listPageLoad
    case channelFilter
    case bulkRead
    case bulkDelete
    case writeBatch
}

actor PerformanceMonitor {
    static let shared = PerformanceMonitor()

    private struct SampleBucket {
        var samples: [Double] = []
        var lastTriggeredAt: Date?
    }

    private var buckets: [PerformanceOperation: SampleBucket] = [:]

    func record(operation: PerformanceOperation, durationMs: Double) {
        guard durationMs > 0 else { return }
        let windowSize = AppConstants.performanceSampleWindow
        var bucket = buckets[operation, default: SampleBucket()]
        bucket.samples.append(durationMs)
        if bucket.samples.count > windowSize {
            bucket.samples.removeFirst(bucket.samples.count - windowSize)
        }

        if bucket.samples.count == windowSize,
           shouldTriggerDegradation(bucket: bucket, operation: operation)
        {
            let avg = bucket.samples.reduce(0, +) / Double(bucket.samples.count)
            bucket.lastTriggeredAt = Date()
            bucket.samples.removeAll(keepingCapacity: true)
            buckets[operation] = bucket
            NotificationCenter.default.post(
                name: Notification.Name(AppConstants.performanceDegradationNotificationName),
                object: nil,
                userInfo: [
                    AppConstants.performanceDegradationOperationKey: operation.rawValue,
                    AppConstants.performanceDegradationAverageMsKey: avg,
                ]
            )
            return
        }

        buckets[operation] = bucket
    }

    private func shouldTriggerDegradation(
        bucket: SampleBucket,
        operation: PerformanceOperation
    ) -> Bool {
        let now = Date()
        if let last = bucket.lastTriggeredAt,
           now.timeIntervalSince(last) < AppConstants.performanceDegradationCooldownSeconds
        {
            return false
        }

        let average = bucket.samples.reduce(0, +) / Double(bucket.samples.count)
        return average >= degradationThresholdMs(for: operation)
    }

    private func degradationThresholdMs(for operation: PerformanceOperation) -> Double {
        switch operation {
        case .listRefresh:
            220
        case .listPageLoad:
            180
        case .channelFilter:
            240
        case .bulkRead:
            260
        case .bulkDelete:
            320
        case .writeBatch:
            200
        }
    }
}
