import Foundation
import Testing
@testable import PushGoAppleCore

struct WatchNotificationFreshnessTests {
    private let sent = Date(timeIntervalSince1970: 1_800_000_000)

    @Test(arguments: ["message", "thing", "event"])
    func originalSendTimeControlsLegacyReminderForEveryEntity(_ kind: String) {
        let payload: [AnyHashable: Any] = ["sent_at": "1800000000000", "entity_type": kind]
        #expect(WatchNotificationFreshness.shouldPresent(
            payload: payload, now: sent.addingTimeInterval(1_799.999)
        ))
        #expect(!WatchNotificationFreshness.shouldPresent(
            payload: payload, now: sent.addingTimeInterval(1_800)
        ))
        #expect(!WatchNotificationFreshness.shouldPresent(
            payload: payload, now: sent.addingTimeInterval(7_200)
        ))
        #expect(payload["sent_at"] as? String == "1800000000000")
    }

    @Test
    func frozenDeadlineSurvivesWindowChangesAndExpiresAtExactMillisecond() {
        let payload: [AnyHashable: Any] = [
            "sent_at": "1800000000000",
            "watch_alert_deadline_at": "1800000900000",
        ]
        let afterFiveMinutes = sent.addingTimeInterval(600)
        #expect(WatchNotificationFreshness.shouldPresent(
            payload: payload, configuredMinutes: 5, now: afterFiveMinutes
        ))
        #expect(WatchNotificationFreshness.shouldPresent(
            payload: payload, configuredMinutes: 60, now: sent.addingTimeInterval(899.999)
        ))
        #expect(!WatchNotificationFreshness.shouldPresent(
            payload: payload, configuredMinutes: 60, now: sent.addingTimeInterval(900)
        ))
    }

    @Test
    func numericAndISOOriginalTimesKeepProtocolCompatibility() {
        let formatter = ISO8601DateFormatter()
        let originals: [Any] = ["1800000000", Int64(1_800_000_000_000), formatter.string(from: sent)]
        for original in originals {
            #expect(WatchNotificationFreshness.shouldPresent(
                payload: ["sent_at": original], configuredMinutes: 5,
                now: sent.addingTimeInterval(299)
            ))
            #expect(!WatchNotificationFreshness.shouldPresent(
                payload: ["sent_at": original], configuredMinutes: 5,
                now: sent.addingTimeInterval(300)
            ))
        }
    }

    @Test
    func missingMalformedAndFutureOriginalTimesNeverBecomeFreshOnReceipt() {
        let malformed: [Any] = [true, "bad", "1800000000.5", Double.nan, Double.infinity, -1, "9223372036854775808"]
        #expect(!WatchNotificationFreshness.shouldPresent(payload: [:], now: sent))
        for value in malformed {
            let payload: [AnyHashable: Any] = ["sent_at": value, "watch_alert_deadline_at": "1800000900000"]
            let shouldPresent = WatchNotificationFreshness.shouldPresent(payload: payload, now: sent)
            #expect(shouldPresent == false, "Invalid sent_at must not become a fresh reminder: \(value)")
        }
        #expect(!WatchNotificationFreshness.shouldPresent(
            payload: ["sent_at": "1800000001000"], now: sent
        ))
    }

    @Test
    func invalidPresentFrozenDeadlineCannotFallBackToLegacyWindow() {
        let invalid: [Any] = [true, "bad", NSNull(), "1800000900", "1800000000000", "1800003600001"]
        for value in invalid {
            let payload: [AnyHashable: Any] = ["sent_at": "1800000000000", "watch_alert_deadline_at": value]
            let shouldPresent = WatchNotificationFreshness.shouldPresent(
                payload: payload,
                configuredMinutes: 60, now: sent.addingTimeInterval(1)
            )
            #expect(shouldPresent == false, "Invalid frozen deadline must not use the legacy window: \(value)")
        }
    }

    @Test
    func provisioningWindowValidationAndDefaultsStayBounded() {
        for minutes in [5, 15, 30, 60] {
            #expect(WatchNotificationFreshness.normalizedMinutes(minutes) == minutes)
            #expect(!WatchNotificationFreshness.shouldPresent(
                payload: ["sent_at": "1800000000000"], configuredMinutes: minutes,
                now: sent.addingTimeInterval(TimeInterval(minutes * 60))
            ))
        }
        for value in [nil, -1, 0, 1, 61] as [Int?] {
            #expect(WatchNotificationFreshness.normalizedMinutes(value) == 30)
        }
    }
}
