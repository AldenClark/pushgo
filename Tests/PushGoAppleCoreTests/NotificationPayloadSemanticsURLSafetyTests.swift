import Foundation
import XCTest
@testable import PushGoAppleCore

final class NotificationPayloadSemanticsURLSafetyTests: XCTestCase {
    func testNormalizeRemoteNotification_sanitizesOpenUrlAndImages() {
        let payload: [AnyHashable: Any] = [
            "entity_type": "message",
            "message_id": "m-1",
            "entity_id": "m-1",
            "title": "hello",
            "body": "[x](javascript:alert(1)) and [ok](https://safe.example/p)",
            "url": "javascript:alert(1)",
            "images": #"["https://cdn.example.com/a.png","http://localhost/b.png","data:image/png;base64,AAA"]"#,
        ]

        let normalized = NotificationPayloadSemantics.normalizeRemoteNotification(
            payload,
            localizeTypeLabel: { $0 },
            localizeThingAttributeUpdateBody: { $0 },
            localizeThingAttributePair: { "\($0): \($1)" }
        )
        XCTAssertNotNil(normalized)
        guard let normalized else { return }

        XCTAssertEqual(normalized.body, "[x](#) and [ok](https://safe.example/p)")
        XCTAssertNil(normalized.url)
        XCTAssertNil(normalized.rawPayload["url"])

        let imageRaw = normalized.rawPayload["images"] as? String
        XCTAssertNotNil(imageRaw)
        if let imageRaw,
           let data = imageRaw.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String]
        {
            XCTAssertEqual(decoded, ["https://cdn.example.com/a.png"])
        } else {
            XCTFail("images should be a json string array")
        }
    }

    func testNormalizeRemoteNotification_keepsCanonicalThingFieldsUntouchedByIngressFilter() throws {
        let payload: [AnyHashable: Any] = [
            "entity_type": "thing",
            "thing_id": "thing-1",
            "entity_id": "thing-1",
            "title": "Object",
            "body": "updated",
            "description": "[bad](javascript:alert(1))",
            "message": "[ok](https://safe.example/m)",
            "primary_image": "http://127.0.0.1/a.png",
            "images": #"["https://cdn.example.com/a.png","http://localhost/b.png"]"#,
        ]

        let normalized = NotificationPayloadSemantics.normalizeRemoteNotification(
            payload,
            localizeTypeLabel: { $0 },
            localizeThingAttributeUpdateBody: { $0 },
            localizeThingAttributePair: { "\($0): \($1)" }
        )
        XCTAssertNotNil(normalized)
        guard let normalized else { return }
        XCTAssertEqual(normalized.rawPayload["description"] as? String, "[bad](javascript:alert(1))")
        XCTAssertEqual(normalized.rawPayload["message"] as? String, "[ok](https://safe.example/m)")
        XCTAssertEqual(normalized.rawPayload["primary_image"] as? String, "http://127.0.0.1/a.png")
        let images = normalized.rawPayload["images"] as? String
        XCTAssertEqual(images, #"["https:\/\/cdn.example.com\/a.png"]"#)
    }

    func testNormalizeRemoteNotification_keepsCiphertextOnlyPayloadPersistable() {
        let payload: [AnyHashable: Any] = [
            "entity_type": "message",
            "message_id": "m-2",
            "entity_id": "m-2",
            "ciphertext": "QUJDREVGR0hJSg==",
        ]

        let normalized = NotificationPayloadSemantics.normalizeRemoteNotification(
            payload,
            localizeTypeLabel: { $0 },
            localizeThingAttributeUpdateBody: { $0 },
            localizeThingAttributePair: { "\($0): \($1)" }
        )
        XCTAssertNotNil(normalized)
        XCTAssertEqual(normalized?.title, "")
        XCTAssertEqual(normalized?.body, "")
        XCTAssertEqual(normalized?.rawPayload["ciphertext"] as? String, "QUJDREVGR0hJSg==")
    }

    func testNormalizeRemoteNotification_keepsMarkdownRichBodyPersistable() {
        let richBody = "[https://sway.cloud.microsoft/lNjlqkdUA7wtAxfV](https://sway.cloud.microsoft/lNjlqkdUA7wtAxfV)\n\n无论可以玩玩。有上千个，\n\n\n\n[原文链接](https://www.v2ex.com/t/1200790)"
        let payload: [AnyHashable: Any] = [
            "entity_type": "message",
            "message_id": "m-rich-1",
            "entity_id": "m-rich-1",
            "title": "sample",
            "body": richBody,
        ]

        let normalized = NotificationPayloadSemantics.normalizeRemoteNotification(
            payload,
            localizeTypeLabel: { $0 },
            localizeThingAttributeUpdateBody: { $0 },
            localizeThingAttributePair: { "\($0): \($1)" }
        )
        XCTAssertNotNil(normalized)
        XCTAssertEqual(normalized?.body, richBody)
        XCTAssertEqual(normalized?.rawPayload["body"] as? String, richBody)
    }
}
