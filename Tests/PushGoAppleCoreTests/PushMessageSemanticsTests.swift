import Foundation
import Testing
@testable import PushGoAppleCore

struct PushMessageSemanticsTests {
    @Test
    func tagsAcceptCanonicalJSONArrayAndLegacyEncodedArray() {
        let canonical = message(tags: AnyCodable(["ops", "ops", "urgent"]))
        let legacy = message(tags: AnyCodable(#"["ops","urgent"]"#))

        #expect(canonical.tags == ["ops", "urgent"])
        #expect(legacy.tags == ["ops", "urgent"])
    }

    private func message(tags: AnyCodable) -> PushMessage {
        PushMessage(
            messageId: "message-tags",
            title: "Tagged message",
            body: "body",
            rawPayload: ["tags": tags]
        )
    }
}
