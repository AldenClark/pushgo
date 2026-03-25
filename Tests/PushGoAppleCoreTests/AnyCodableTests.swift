import Foundation
import Testing
@testable import PushGoAppleCore

struct AnyCodableTests {
    @Test
    func anyCodableRoundTripsNestedJSON() throws {
        let payload = AnyCodable(
            [
                "title": "Disk alert",
                "count": 3,
                "is_read": false,
                "tags": ["ops", "storage"],
                "meta": [
                    "severity": "high",
                    "ratio": 0.98,
                ],
            ]
        )

        let encoded = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: encoded)

        #expect(decoded == payload)
    }

    @Test
    func anyCodableFallsBackToNullForUnsupportedValues() throws {
        let encoded = try JSONEncoder().encode(AnyCodable(Date()))
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: encoded)
        #expect(decoded == AnyCodable(Optional<Int>.none as Any))
    }
}
