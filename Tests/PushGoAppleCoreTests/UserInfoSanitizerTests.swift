import Foundation
import Testing
@testable import PushGoAppleCore

struct UserInfoSanitizerTests {
    @Test
    func sanitizerKeepsOnlySerializableValues() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let userInfo: [AnyHashable: Any] = [
            "title": "hello",
            "count": 2,
            "flag": true,
            "ratio": Float(1.5),
            "bytes": Data([0x61, 0x62]),
            "created_at": now,
            "nested": [
                "ok": "yes",
                "drop": URL(string: "https://example.com") as Any,
            ],
            "list": [1, "two", Data([0x63])],
            42: "ignored",
        ]

        let sanitized = UserInfoSanitizer.sanitize(userInfo)

        #expect(sanitized["title"] as? String == "hello")
        #expect(sanitized["count"] as? Int == 2)
        #expect(sanitized["flag"] as? Bool == true)
        #expect(sanitized["ratio"] as? Double == 1.5)
        #expect(sanitized["bytes"] as? String == Data([0x61, 0x62]).base64EncodedString())
        #expect((sanitized["nested"] as? [String: Any])?["ok"] as? String == "yes")
        #expect((sanitized["nested"] as? [String: Any])?["drop"] == nil)
        #expect((sanitized["list"] as? [Any])?.count == 3)
        #expect(sanitized["42"] == nil)
    }
}
