import XCTest
@testable import PushGoAppleCore

final class AppVersionDisplayTests: XCTestCase {
    func testResolve_prefersExplicitDisplayVersion() {
        XCTAssertEqual(
            AppVersionDisplay.resolve(
                displayVersion: "v1.2.0-beta.2",
                shortVersion: "1.2.0",
                buildVersion: "58"
            ),
            "v1.2.0-beta.2"
        )
    }

    func testResolve_prefixesDisplayVersionWhenNeeded() {
        XCTAssertEqual(
            AppVersionDisplay.resolve(
                displayVersion: "1.2.0-beta.2",
                shortVersion: "1.2.0",
                buildVersion: "58"
            ),
            "v1.2.0-beta.2"
        )
    }

    func testResolve_fallsBackToMarketingVersionWhenDisplayVersionIsUnset() {
        XCTAssertEqual(
            AppVersionDisplay.resolve(
                displayVersion: nil,
                shortVersion: "1.2.0",
                buildVersion: "58"
            ),
            "v1.2.0"
        )
    }

    func testResolve_ignoresUnresolvedBuildSettingPlaceholder() {
        XCTAssertEqual(
            AppVersionDisplay.resolve(
                displayVersion: "$(PUSHGO_DISPLAY_VERSION)",
                shortVersion: "1.2.0",
                buildVersion: "58"
            ),
            "v1.2.0"
        )
    }
}
