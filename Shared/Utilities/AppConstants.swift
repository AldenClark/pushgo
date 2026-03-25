import CoreFoundation
import Darwin
import Foundation
import ImageIO
import Network
import Security
import UniformTypeIdentifiers
import UserNotifications
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum PushGoAutomationContext {
    private static let storageRootEnv = "PUSHGO_AUTOMATION_STORAGE_ROOT"
    private static let providerTokenEnv = "PUSHGO_AUTOMATION_PROVIDER_TOKEN"
    private static let skipPushAuthorizationEnv = "PUSHGO_AUTOMATION_SKIP_PUSH_AUTHORIZATION"
    private static let gatewayBaseURLEnv = "PUSHGO_AUTOMATION_GATEWAY_BASE_URL"
    private static let gatewayTokenEnv = "PUSHGO_AUTOMATION_GATEWAY_TOKEN"
    private static let forceForegroundAppEnv = "PUSHGO_AUTOMATION_FORCE_FOREGROUND_APP"
    private static let allowCrossAppDataAccessEnv = "PUSHGO_AUTOMATION_ALLOW_CROSS_APP_DATA_ACCESS"

    static var storageRootURL: URL? {
        normalizedURL(for: storageRootEnv)
    }

    static var keychainDirectoryURL: URL? {
        storageRootURL?.appendingPathComponent("keychain", isDirectory: true)
    }

    static var providerToken: String? {
        normalizedString(for: providerTokenEnv)
    }

    static var gatewayBaseURLString: String? {
        normalizedString(for: gatewayBaseURLEnv)
    }

    static var gatewayToken: String? {
        normalizedString(for: gatewayTokenEnv)
    }

    static var isActive: Bool {
        storageRootURL != nil
            || providerToken != nil
            || gatewayBaseURLString != nil
            || gatewayToken != nil
    }

    static var forceForegroundApp: Bool {
        guard isActive else { return false }
        guard let raw = ProcessInfo.processInfo.environment[forceForegroundAppEnv]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        else {
            return true
        }
        if ["0", "false", "no", "off"].contains(raw) {
            return false
        }
        return true
    }

    static var bypassPushAuthorizationPrompt: Bool {
        if let raw = ProcessInfo.processInfo.environment[skipPushAuthorizationEnv]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        {
            if ["1", "true", "yes", "on"].contains(raw) {
                return true
            }
            if ["0", "false", "no", "off"].contains(raw) {
                return false
            }
        }
        return providerToken != nil || storageRootURL != nil
    }

    static var blocksCrossAppDataAccess: Bool {
        guard isActive else { return false }
        guard let raw = ProcessInfo.processInfo.environment[allowCrossAppDataAccessEnv]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        else {
            return true
        }
        if ["1", "true", "yes", "on"].contains(raw) {
            return false
        }
        if ["0", "false", "no", "off"].contains(raw) {
            return true
        }
        return true
    }

    static func appGroupContainerURL(identifier: String) -> URL? {
        guard let root = storageRootURL else { return nil }
        return root
            .appendingPathComponent("app-groups", isDirectory: true)
            .appendingPathComponent(identifier, isDirectory: true)
    }

    private static func normalizedURL(for envKey: String) -> URL? {
        guard let raw = normalizedString(for: envKey) else { return nil }
        return URL(fileURLWithPath: raw, isDirectory: true)
    }

    private static func normalizedString(for envKey: String) -> String? {
        let rawValue: String
        if let cString = getenv(envKey) {
            rawValue = String(cString: cString)
        } else {
            rawValue = ProcessInfo.processInfo.environment[envKey] ?? ""
        }
        let raw = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }
}

enum OpaqueId {
    static func generateHex128() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

enum PushGoSystemInteraction {
    static func copyTextToPasteboard(_ text: String) {
        guard !text.isEmpty else { return }
        guard !PushGoAutomationContext.blocksCrossAppDataAccess else { return }
#if os(iOS)
        UIPasteboard.general.string = text
#elseif os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
#endif
    }

#if os(macOS)
    @discardableResult
    static func openExternalURL(_ url: URL) -> Bool {
        guard !PushGoAutomationContext.blocksCrossAppDataAccess else { return false }
        return NSWorkspace.shared.open(url)
    }
#endif
}

enum AppConstants {
    static let appGroupIdentifier = "group.ethan.pushgo.messages"
    static let serverConfigFilename = "server_config.json"
    static let messagesFilename = "messages.json"
    // No backward-compatibility for local persistence artifacts.
    static let databaseVersion = "v9"
    static let databaseStoreFilename = "pushgo-\(databaseVersion).db"
    private static let productionServerAddress = "https://gateway.pushgo.dev"
    static let messageSyncNotificationName = "io.ethan.pushgo.message-sync"
    static let copyToastNotificationName = "io.ethan.pushgo.copy-toast"
    static let notificationDefaultCategoryIdentifier = "PUSHGO_DEFAULT"
    static let notificationEntityReminderCategoryIdentifier = "PUSHGO_ENTITY_REMINDER"
    static let maxStoredMessages = 100_000
    static let pruneBatchSize = 200
    static let maxMessageImageBytes: Int64 = 10 * 1024 * 1024
    static let deviceRegistrationTimeout: TimeInterval = 15

    static var defaultServerAddress: String {
        PushGoAutomationContext.gatewayBaseURLString ?? productionServerAddress
    }

    static var defaultServerURL: URL? {
        URL(string: defaultServerAddress)
    }

    static var defaultGatewayToken: String? {
        PushGoAutomationContext.gatewayToken
    }

    static func appGroupContainerURL(
        fileManager: FileManager = .default,
        identifier: String = appGroupIdentifier
    ) -> URL? {
        if let automationURL = PushGoAutomationContext.appGroupContainerURL(identifier: identifier) {
            return automationURL
        }
        return fileManager.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    static func sharedUserDefaults(
        suiteName: String = appGroupIdentifier
    ) -> UserDefaults {
        #if os(macOS) || os(iOS)
        if PushGoAutomationContext.blocksCrossAppDataAccess {
            return .standard
        }
        #endif
        return UserDefaults(suiteName: suiteName) ?? .standard
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
    private static let maxURLLength = 4096
    private static let externalOpenSchemes: Set<String> = [
        "http",
        "https",
        "ftp",
        "ftps",
        "mailto",
        "tel",
        "sms",
        "app",
        "pushgo",
    ]
    private static let blockedOpenSchemes: Set<String> = [
        "javascript",
        "data",
        "file",
        "content",
        "intent",
        "vbscript",
    ]

    static func isAllowedRemoteURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" else { return false }
        guard let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty else {
            return false
        }
        if url.user != nil || url.password != nil {
            return false
        }
        return !isBlockedRemoteHost(host)
    }

    static func isAllowedExternalOpenURL(_ url: URL) -> Bool {
        guard let rawScheme = url.scheme?.lowercased(), !rawScheme.isEmpty else { return false }
        if blockedOpenSchemes.contains(rawScheme) { return false }
        if !externalOpenSchemes.contains(rawScheme) { return false }
        if ["http", "https", "ftp", "ftps"].contains(rawScheme) {
            guard let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty else {
                return false
            }
            if url.user != nil || url.password != nil {
                return false
            }
        }
        return true
    }

    static func sanitizeHTTPSURL(_ url: URL?) -> URL? {
        guard let url, isAllowedRemoteURL(url) else { return nil }
        return url
    }

    static func sanitizeExternalOpenURL(_ url: URL?) -> URL? {
        guard let url, isAllowedExternalOpenURL(url) else { return nil }
        return url
    }

    static func resolveHTTPSURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxURLLength, let url = URL(string: trimmed) else { return nil }
        return sanitizeHTTPSURL(url)
    }

    static func resolveExternalOpenURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count > maxURLLength { return nil }
        if containsBlockedEncodedScheme(trimmed) { return nil }

        if let direct = URL(string: trimmed), sanitizeExternalOpenURL(direct) != nil {
            return direct
        }

        // For scheme-less host-like links, only auto-upgrade to https.
        let hostCandidate = trimmed
            .split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
            .first?
            .split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init)
            ?? ""
        guard hostCandidate.contains("."),
              hostCandidate.unicodeScalars.allSatisfy({ scalar in
                  CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-"
              }),
              let upgraded = URL(string: "https://\(trimmed)")
        else {
            return nil
        }
        return sanitizeExternalOpenURL(upgraded)
    }

    static func rewriteVisibleURLsInMarkdown(_ raw: String) -> String {
        guard !raw.isEmpty, raw.contains("](") else { return raw }

        var cursor = raw.startIndex
        var copyStart = raw.startIndex
        var rewritten = String()
        rewritten.reserveCapacity(raw.count)

        while cursor < raw.endIndex {
            guard raw[cursor] == "]" else {
                cursor = raw.index(after: cursor)
                continue
            }
            let markerNext = raw.index(after: cursor)
            guard markerNext < raw.endIndex, raw[markerNext] == "(" else {
                cursor = markerNext
                continue
            }

            let destinationStart = raw.index(after: markerNext)
            var end = destinationStart
            var depth = 0
            var matched = false
            while end < raw.endIndex {
                let ch = raw[end]
                if ch == "(" {
                    depth += 1
                } else if ch == ")" {
                    if depth == 0 {
                        matched = true
                        break
                    }
                    depth -= 1
                }
                end = raw.index(after: end)
            }
            guard matched else { break }

            rewritten.append(contentsOf: raw[copyStart..<destinationStart])
            rewritten.append(rewriteMarkdownDestination(String(raw[destinationStart..<end])))
            rewritten.append(")")

            cursor = raw.index(after: end)
            copyStart = cursor
        }

        guard copyStart != raw.startIndex else { return raw }
        rewritten.append(contentsOf: raw[copyStart..<raw.endIndex])
        return rewritten
    }

    private static func rewriteMarkdownDestination(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return raw }

        let leading = raw.firstIndex(where: { !$0.isWhitespace }) ?? raw.startIndex
        let trailingInclusive = raw.lastIndex(where: { !$0.isWhitespace }) ?? raw.index(before: raw.endIndex)
        let trailingExclusive = raw.index(after: trailingInclusive)
        let inner = raw[leading..<trailingExclusive]
        let tokenEnd = inner.firstIndex(where: \.isWhitespace) ?? inner.endIndex
        let token = String(inner[..<tokenEnd])
        let suffix = String(inner[tokenEnd...])
        let unwrapped: String
        if token.hasPrefix("<"), token.hasSuffix(">"), token.count >= 2 {
            unwrapped = String(token.dropFirst().dropLast())
        } else {
            unwrapped = token
        }

        let rewrittenToken: String
        if let safe = resolveExternalOpenURL(from: unwrapped)?.absoluteString {
            if token.hasPrefix("<"), token.hasSuffix(">") {
                rewrittenToken = "<\(safe)>"
            } else {
                rewrittenToken = safe
            }
        } else if looksLikeURLToken(unwrapped) {
            rewrittenToken = "#"
        } else {
            rewrittenToken = token
        }

        let prefix = String(raw[..<leading])
        let tail = String(raw[trailingExclusive...])
        return prefix + rewrittenToken + suffix + tail
    }

    private static func looksLikeURLToken(_ raw: String) -> Bool {
        raw.contains(":") || raw.lowercased().hasPrefix("www.")
    }

    private static func containsBlockedEncodedScheme(_ raw: String) -> Bool {
        var candidate = raw
        for _ in 0..<3 {
            if let scheme = leadingSchemeToken(candidate), blockedOpenSchemes.contains(scheme) {
                return true
            }
            guard let decoded = candidate.removingPercentEncoding, decoded != candidate else {
                break
            }
            candidate = decoded
        }
        if let scheme = leadingSchemeToken(candidate), blockedOpenSchemes.contains(scheme) {
            return true
        }
        return false
    }

    private static func leadingSchemeToken(_ raw: String) -> String? {
        let scalars = raw.unicodeScalars.drop(while: { CharacterSet.whitespacesAndNewlines.contains($0) })
        if scalars.isEmpty { return nil }
        var token = ""
        var sawColon = false
        for scalar in scalars {
            if scalar == ":" {
                sawColon = true
                break
            }
            if CharacterSet.whitespacesAndNewlines.contains(scalar)
                || CharacterSet.controlCharacters.contains(scalar)
            {
                continue
            }
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "+" || scalar == "-" || scalar == "." {
                token.append(String(scalar).lowercased())
                if token.count > 32 { return nil }
                continue
            }
            return nil
        }
        guard sawColon, !token.isEmpty else { return nil }
        return token
    }

    private static func isBlockedRemoteHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        guard !normalized.isEmpty else { return true }
        if normalized == "localhost" || normalized.hasSuffix(".localhost") {
            return true
        }
        if let ipv4 = IPv4Address(normalized) {
            return isBlockedIPv4(ipv4.rawValue)
        }
        if let ipv6 = IPv6Address(normalized) {
            return isBlockedIPv6(ipv6.rawValue)
        }
        return false
    }

    private static func isBlockedIPv4(_ bytes: Data) -> Bool {
        guard bytes.count == 4 else { return true }
        let octets = Array(bytes)
        let b0 = Int(octets[0])
        let b1 = Int(octets[1])
        if b0 == 0 || b0 == 10 || b0 == 127 { return true }
        if b0 == 169 && b1 == 254 { return true }
        if b0 == 172 && (16...31).contains(b1) { return true }
        if b0 == 192 && b1 == 168 { return true }
        if b0 == 100 && (64...127).contains(b1) { return true }
        if b0 >= 224 { return true }
        return false
    }

    private static func isBlockedIPv6(_ bytes: Data) -> Bool {
        guard bytes.count == 16 else { return true }
        let octets = Array(bytes)
        if octets.allSatisfy({ $0 == 0 }) { return true }
        if octets.dropLast().allSatisfy({ $0 == 0 }) && octets.last == 1 { return true } // ::1
        let b0 = Int(octets[0])
        let b1 = Int(octets[1])
        if b0 == 0xFE && (b1 & 0xC0) == 0x80 { return true } // fe80::/10
        if (b0 & 0xFE) == 0xFC { return true } // fc00::/7
        return false
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

enum MessagePreviewExtractor {
    static func notificationPreview(from markdown: String) -> String {
        preview(from: markdown, maxLines: 1, maxCharacters: 180)
    }

    static func listPreview(from markdown: String) -> String {
        preview(from: markdown, maxLines: 6, maxCharacters: 1200)
    }

    private static func preview(from markdown: String, maxLines: Int, maxCharacters: Int) -> String {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = plainLines(from: normalized)
        var rendered: [String] = []
        rendered.reserveCapacity(maxLines)

        for line in lines.prefix(maxLines) {
            let plain = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !plain.isEmpty {
                rendered.append(plain)
            }
        }

        let joined = rendered.joined(separator: "\n")
        if joined.count <= maxCharacters {
            return joined
        }
        let truncated = joined.prefix(maxCharacters)
        return String(truncated).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func plainLines(from markdown: String) -> [String] {
        let document = PushGoMarkdownParser().parse(markdown)
        if document.blocks.isEmpty {
            return markdown
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }

        var lines: [String] = []
        for block in document.blocks {
            let blockLines = plainLines(from: block)
            for line in blockLines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    lines.append(trimmed)
                }
            }
        }
        return lines
    }

    private static func plainLines(from block: MarkdownBlock) -> [String] {
        switch block {
        case let .heading(_, content):
            return [plainText(from: content)]
        case let .paragraph(content):
            return [plainText(from: content)]
        case let .blockquote(content):
            return [plainText(from: content)]
        case let .callout(_, content):
            return [plainText(from: content)]
        case let .bulletList(items):
            return items.map { plainText(from: $0.content) }
        case let .orderedList(items):
            return items.map { plainText(from: $0.content) }
        case let .table(table):
            var lines: [String] = []
            if !table.headers.isEmpty {
                lines.append(table.headers.map { plainText(from: $0) }.joined(separator: " | "))
            }
            for row in table.rows {
                lines.append(row.map { plainText(from: $0) }.joined(separator: " | "))
            }
            return lines
        case .horizontalRule:
            return []
        }
    }

    private static func plainText(from inlines: [MarkdownInline]) -> String {
        inlines.map(plainText(from:)).joined()
    }

    private static func plainText(from inline: MarkdownInline) -> String {
        switch inline {
        case let .text(text):
            return text
        case let .bold(content):
            return plainText(from: content)
        case let .italic(content):
            return plainText(from: content)
        case let .strikethrough(content):
            return plainText(from: content)
        case let .highlight(content):
            return plainText(from: content)
        case let .code(code):
            return code
        case let .link(text, _):
            return plainText(from: text)
        case let .mention(value):
            return "@\(value)"
        case let .tag(value):
            return "#\(value)"
        case let .autolink(autolink):
            return autolink.value
        }
    }
}

enum MessageIdExtractor {
    static func extract(from payload: [String: Any]) -> String? {
        stringValue(keys: ["message_id"], from: payload)
    }

    private static func stringValue(keys: [String], from payload: [String: Any]) -> String? {
        for key in keys {
            if let raw = payload[key] as? String {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }

}

enum OperationIdExtractor {
    static func extract(from payload: [String: Any]) -> String? {
        stringValue(key: "op_id", from: payload)
    }

    private static func stringValue(key: String, from payload: [String: Any]) -> String? {
        if let raw = payload[key] as? String {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

}

enum PayloadTimeParser {
    static func epochSeconds(from value: Any?) -> Int64? {
        switch value {
        case let number as Int:
            return Int64(number)
        case let number as Int64:
            return number
        case let number as Double:
            return Int64(number)
        case let number as NSNumber:
            return number.int64Value
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return Int64(trimmed)
        default:
            return nil
        }
    }

    static func epochSeconds(from value: AnyCodable?) -> Int64? {
        epochSeconds(from: value?.value)
    }

    static func date(from value: Any?) -> Date? {
        guard let seconds = epochSeconds(from: value) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    static func date(from value: AnyCodable?) -> Date? {
        date(from: value?.value)
    }
}

#if !os(watchOS)
struct NormalizedNotificationPayload {
    let title: String
    let body: String
    let hasExplicitTitle: Bool
    let channel: String?
    let url: URL?
    let decryptionState: PushMessage.DecryptionState?
    let rawPayload: [String: AnyCodable]
    let messageId: String?
    let operationId: String?
}

enum NotificationPayloadNormalizer {
    static func normalize(
        content: UNNotificationContent,
        requestId: String
    ) -> NormalizedNotificationPayload {
        let sanitizedPayload = UserInfoSanitizer.sanitize(content.userInfo)
        let rawEntityType = (sanitizedPayload["entity_type"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let entityType = rawEntityType.isEmpty ? "message" : rawEntityType

        let title = content.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = content.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowContentAlertFallback = !NotificationPayloadSemantics.isGatewayFallbackAlertCandidate(
            entityType: entityType,
            title: title,
            body: body
        )
        let resolvedTitle = if let payloadTitle = (sanitizedPayload["title"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !payloadTitle.isEmpty
        {
            payloadTitle
        } else if allowContentAlertFallback {
            title
        } else {
            ""
        }
        let payloadBody = (sanitizedPayload["body"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBody = if let payloadBody, !payloadBody.isEmpty {
            payloadBody
        } else if allowContentAlertFallback {
            body
        } else {
            ""
        }

        let channelIdentifier = content.threadIdentifier.isEmpty
            ? (sanitizedPayload["channel_id"] as? String)
            : content.threadIdentifier
        let trimmedChannel = channelIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedChannel = trimmedChannel?.isEmpty == true ? nil : trimmedChannel
        let url = (sanitizedPayload["url"] as? String).flatMap { URLSanitizer.resolveExternalOpenURL(from: $0) }
        let stateRaw = sanitizedPayload["decryption_state"] as? String
        let decryptionState = stateRaw.flatMap(PushMessage.DecryptionState.init(rawValue:))

        let bridgedPayload = sanitizedPayload.reduce(into: [AnyHashable: Any]()) { result, element in
            result[element.key] = element.value
        }
        let normalizedRemote = NotificationHandling.normalizeRemoteNotification(bridgedPayload)

        var fallbackPayload = sanitizedPayload
        if fallbackPayload["title"] == nil {
            fallbackPayload["title"] = resolvedTitle
        }
        if fallbackPayload["body"] == nil {
            fallbackPayload["body"] = resolvedBody
        }
        if let resolvedChannel, fallbackPayload["channel_id"] == nil {
            fallbackPayload["channel_id"] = resolvedChannel
        }
        if let url, fallbackPayload["url"] == nil {
            fallbackPayload["url"] = url.absoluteString
        }

        let finalTitle = normalizedRemote?.title ?? resolvedTitle
        let finalBody = normalizedRemote?.body ?? resolvedBody
        let fallbackExplicitTitle = (sanitizedPayload["title"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        let hasExplicitTitle = normalizedRemote?.hasExplicitTitle ?? fallbackExplicitTitle
        let finalChannel = normalizedRemote?.channel ?? resolvedChannel
        let finalURL = normalizedRemote?.url ?? url
        let finalDecryptionState = normalizedRemote?.decryptionState ?? decryptionState
        let messageId = normalizedRemote?.messageId ?? MessageIdExtractor.extract(from: sanitizedPayload)
        let operationId = normalizedRemote?.operationId ?? OperationIdExtractor.extract(from: sanitizedPayload)

        let payloadSource = normalizedRemote?.rawPayload ?? fallbackPayload
        var rawPayload = payloadSource.reduce(into: [String: AnyCodable]()) { result, element in
            result[element.key] = AnyCodable(element.value)
        }
        rawPayload["_notificationRequestId"] = AnyCodable(requestId)

        return NormalizedNotificationPayload(
            title: finalTitle,
            body: finalBody,
            hasExplicitTitle: hasExplicitTitle,
            channel: finalChannel,
            url: finalURL,
            decryptionState: finalDecryptionState,
            rawPayload: rawPayload,
            messageId: messageId,
            operationId: operationId
        )
    }
}
#endif

@MainActor
enum NotificationMediaResolver {
    static func urlValue(in userInfo: [AnyHashable: Any], keys: [String]) -> URL? {
        urls(in: userInfo, keys: keys).first
    }

    static func urls(in userInfo: [AnyHashable: Any], keys: [String]) -> [URL] {
        var resolved: [URL] = []
        for key in keys {
            guard let value = userInfo[key] else { continue }
            appendResolvedURLs(from: value, into: &resolved)
        }
        return resolved
    }

    static func attachments(
        from userInfo: [AnyHashable: Any],
        candidates: [(key: String, identifier: String)],
        maxBytes: Int64 = AppConstants.maxMessageImageBytes,
        timeout: TimeInterval = 10
    ) async -> [UNNotificationAttachment] {
        for candidate in candidates {
            guard let url = urls(in: userInfo, keys: [candidate.key]).first else { continue }
            if let attachment = await downloadAttachment(
                from: url,
                identifier: candidate.identifier,
                maxBytes: maxBytes,
                timeout: timeout
            ) {
                return [attachment]
            }
        }
        return []
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
        maxBytes: Int64,
        timeout: TimeInterval
    ) async -> UNNotificationAttachment? {
        guard URLSanitizer.isAllowedRemoteURL(url) else { return nil }
        do {
            let data = try await SharedImageCache.fetchData(
                from: url,
                maxBytes: maxBytes,
                timeout: timeout
            )
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

    private static func appendResolvedURLs(from raw: Any, into results: inout [URL]) {
        switch raw {
        case let text as String:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if let data = trimmed.data(using: .utf8),
               let decoded = try? JSONSerialization.jsonObject(with: data),
               let array = decoded as? [Any]
            {
                for item in array {
                    appendResolvedURLs(from: item, into: &results)
                }
                return
            }
            if let url = URLSanitizer.resolveHTTPSURL(from: trimmed),
               !results.contains(where: { $0.absoluteString == url.absoluteString })
            {
                results.append(url)
            }
        case let values as [Any]:
            for item in values {
                appendResolvedURLs(from: item, into: &results)
            }
        default:
            return
        }
    }
}

final class DarwinNotificationObserver {
    typealias Handler = () -> Void

    private let handler: Handler
    private var token: Int32 = 0
    private var isRegistered = false

    init(name: String, handler: @escaping Handler) {
        self.handler = handler
        var registrationToken: Int32 = 0
        let status = name.withCString { cName in
            notify_register_dispatch_shim(cName, &registrationToken, DispatchQueue.main) { [weak self] _ in
                self?.invoke()
            }
        }
        guard status == notifyStatusOK else { return }
        token = registrationToken
        isRegistered = true
    }

    deinit {
        if isRegistered {
            _ = notify_cancel_shim(token)
        }
    }

    fileprivate func invoke() {
        handler()
    }
}

enum DarwinNotificationPoster {
    static func post(name: String) {
        _ = name.withCString { cName in
            notify_post_shim(cName)
        }
    }
}

private let notifyStatusOK: Int32 = 0

@_silgen_name("notify_register_dispatch")
private func notify_register_dispatch_shim(
    _ name: UnsafePointer<CChar>,
    _ outToken: UnsafeMutablePointer<Int32>,
    _ queue: DispatchQueue,
    _ handler: @escaping @convention(block) (Int32) -> Void
) -> Int32

@_silgen_name("notify_cancel")
private func notify_cancel_shim(_ token: Int32) -> Int32

@_silgen_name("notify_post")
private func notify_post_shim(_ name: UnsafePointer<CChar>) -> Int32
