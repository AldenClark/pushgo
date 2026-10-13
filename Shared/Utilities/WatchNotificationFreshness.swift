import CoreFoundation
import Foundation

/// Controls new Watch reminders only. It never decides whether content is stored or ACKed.
enum WatchNotificationFreshness {
    static let deadlineKey = "watch_alert_deadline_at"
    static let defaultMinutes = 30
    static let allowedMinutes = [5, 15, 30, 60]

    static func normalizedMinutes(_ value: Int?) -> Int {
        guard let value, allowedMinutes.contains(value) else { return defaultMinutes }
        return value
    }

    static func configuredMinutes(defaults: UserDefaults) -> Int {
        let value = defaults.integer(forKey: AppConstants.watchAlertWindowMinutesDefaultsKey)
        return normalizedMinutes(value)
    }

    static func shouldPresent(
        payload: [AnyHashable: Any],
        configuredMinutes: Int = defaultMinutes,
        now: Date = Date()
    ) -> Bool {
        guard let sentAt = originalSentAt(payload["sent_at"]),
              sentAt.timeIntervalSince1970 > 0,
              sentAt <= now
        else { return false }

        let deadline: Date
        if let rawDeadline = payload[deadlineKey] {
            // A malformed new-format deadline cannot silently become a legacy
            // delivery whose window changes when provisioning changes.
            guard let milliseconds = integer(rawDeadline), milliseconds > 0 else { return false }
            deadline = Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
            guard deadline > sentAt,
                  deadline <= sentAt.addingTimeInterval(60 * 60)
            else { return false }
        } else {
            // Old Gateways did not freeze a delivery deadline. Their limited
            // compatibility uses the current provisioned window and original
            // send time; receipt, retry and decrypt times never refresh it.
            let minutes = normalizedMinutes(configuredMinutes)
            deadline = sentAt.addingTimeInterval(TimeInterval(minutes * 60))
        }
        return now < deadline
    }

    private static func originalSentAt(_ value: Any?) -> Date? {
        if let raw = integer(value) {
            // Match PayloadTimeParser's seconds/milliseconds protocol without
            // losing the millisecond precision needed at the alert boundary.
            return PayloadTimeParser.date(from: raw)
        }
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let date = formatter.date(from: normalized) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: normalized)
    }

    private static func integer(_ value: Any?) -> Int64? {
        if let string = value as? String {
            return Int64(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        // Parse the exact integer text; floating point NaN, infinity, overflow
        // and fractional timestamps are invalid instead of trapping/coercing.
        return Int64(number.stringValue)
    }
}
