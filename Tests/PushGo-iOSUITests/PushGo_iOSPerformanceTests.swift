import Foundation
import XCTest

@MainActor
extension PushGo_iOSUITests {
    func testPreparedLargeMessageStoreColdLaunchReachesAccurateContent() {
        let sessionID = "ios-performance-\(UUID().uuidString.lowercased())"
        let context = configuredLaunchContext()
        context.app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = qualitySessionPayload(
            sessionID: sessionID,
            fixture: "messages.large"
        )

        // Preparing the canonical Store is deliberately outside the measured region.
        // The user task being measured starts with an existing 1,000-message database.
        launch(context.app)
        assertQualityRuntimeReady(in: context.app, timeout: 30)
        XCTAssertTrue(
            context.app.staticTexts["Quality message 999"].waitForExistence(timeout: 8),
            "The atomic 1,000-message fixture must reach its highest indexed row before measuring relaunch"
        )
        context.app.terminate()

        let options = XCTMeasureOptions()
        options.iterationCount = 5
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        let firstAccurateTitle = context.app.staticTexts["Quality message 999"]
        var launchToAccurateContentSeconds: [Double] = []

        measure(
            metrics: [
                XCTApplicationLaunchMetric(waitUntilResponsive: true),
                XCTClockMetric(),
                XCTCPUMetric(application: context.app),
                XCTMemoryMetric(application: context.app),
            ],
            options: options
        ) {
            if context.app.state != .notRunning {
                context.app.terminate()
            }
            let launchStartedAt = ContinuousClock.now
            startMeasuring()
            context.app.launch()
            let reachedAccurateContent = firstAccurateTitle.waitForExistence(timeout: 8)
            stopMeasuring()
            let elapsed = launchStartedAt.duration(to: .now)
            let seconds = Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000
            launchToAccurateContentSeconds.append(seconds)
            XCTAssertTrue(
                reachedAccurateContent,
                "A prepared 1,000-message Store did not reach accurate visible content"
            )
            XCTAssertLessThanOrEqual(
                seconds,
                8,
                "Simulator launch-to-accurate-content exceeded the provisional gross-regression ceiling; this does not replace a physical Release baseline"
            )
        }

        let sortedDurations = launchToAccurateContentSeconds.sorted()
        let performanceSummary = "simulator_launch_to_accurate_content_seconds=\(sortedDurations) provisional_ceiling_seconds=8.0 physical_release_baseline=NOT_RUN"
        XCTContext.runActivity(named: performanceSummary) { _ in }

        assertQualityRuntimeReady(in: context.app, timeout: 10)
        XCTAssertFalse(element(in: context.app, identifier: "state.messages.load_failed").exists)
        tapWhenHittable(
            firstAccurateTitle,
            timeout: 5,
            message: "The measured result must remain interactive"
        )
        assertElementExists("sheet.message.detail", in: context.app, timeout: 8)
        XCTAssertTrue(
            context.app.staticTexts["Deterministic app-owned performance fixture row 999."].exists,
            "The measured title must open the matching persisted message body"
        )
    }

    func testSlowLargeMessageLoadTripsAccurateContentBudget() {
        let context = configuredLaunchContext()
        context.app.launchEnvironment["PUSHGO_QUALITY_SESSION_BASE64"] = qualitySessionPayload(
            sessionID: "ios-performance-negative-\(UUID().uuidString.lowercased())",
            fixture: "messages.large",
            messageLoadDelayMilliseconds: 8_000
        )
        let exactTitle = context.app.staticTexts["Quality message 999"]

        // Seed outside the measured interval, then force a real cold relaunch through the
        // same Store -> view model -> SwiftUI path as the positive performance journey.
        launch(context.app)
        assertQualityRuntimeReady(in: context.app, timeout: 30)
        XCTAssertTrue(exactTitle.waitForExistence(timeout: 12))
        context.app.terminate()

        let expectationOptions = XCTExpectedFailure.Options()
        expectationOptions.isStrict = true
        expectationOptions.issueMatcher = { issue in
            issue.compactDescription.contains(
                "slow-load negative control: launch-to-accurate-content took"
            ) && issue.compactDescription.contains("budget=8000ms")
        }
        XCTExpectFailure(
            "The controlled 8-second load must trip the existing 8-second accurate-content ceiling.",
            options: expectationOptions
        )

        let launchStartedAt = ContinuousClock.now
        context.app.launch()
        let reachedAccurateContent = exactTitle.waitForExistence(timeout: 12)
        let elapsed = launchStartedAt.duration(to: .now)
        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000
        XCTAssertTrue(
            reachedAccurateContent,
            "The deliberately delayed 1,000-message Store did not reach its exact canonical title"
        )
        let elapsedMilliseconds = Int((seconds * 1_000).rounded())
        XCTAssertLessThanOrEqual(
            seconds,
            8,
            "slow-load negative control: launch-to-accurate-content took \(elapsedMilliseconds)ms; budget=8000ms"
        )
        tapWhenHittable(exactTitle, timeout: 5)
        assertElementExists("sheet.message.detail", in: context.app, timeout: 8)
        XCTAssertTrue(
            context.app.staticTexts["Deterministic app-owned performance fixture row 999."].exists,
            "The deliberately slow title must still open the matching persisted body"
        )
    }

    func testPhysicalReferenceDeviceColdLaunchReachesExpectedContent() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipIf(
            environment["SIMULATOR_UDID"] != nil,
            "Physical performance evidence cannot be collected from Simulator"
        )
        let expectedTitle = try XCTUnwrap(
            environment["PUSHGO_PHYSICAL_EXPECTED_TITLE"]?.trimmingCharacters(in: .whitespacesAndNewlines),
            "A dedicated reference device must declare its expected visible sentinel title"
        )
        let expectedBody = try XCTUnwrap(
            environment["PUSHGO_PHYSICAL_EXPECTED_BODY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
            "A dedicated reference device must declare the matching sentinel body"
        )
        let maximumSeconds = try XCTUnwrap(
            Double(environment["PUSHGO_PHYSICAL_MAX_SECONDS"] ?? ""),
            "A physical Release budget must be explicit and device-specific"
        )
        XCTAssertFalse(expectedTitle.isEmpty)
        XCTAssertFalse(expectedBody.isEmpty)
        XCTAssertGreaterThan(maximumSeconds, 0)

        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        let expectedTitleElement = app.staticTexts[expectedTitle]
        let options = XCTMeasureOptions()
        options.iterationCount = 10
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        var launchToAccurateContentSeconds: [Double] = []

        measure(
            metrics: [
                XCTApplicationLaunchMetric(waitUntilResponsive: true),
                XCTClockMetric(),
                XCTCPUMetric(application: app),
                XCTMemoryMetric(application: app),
            ],
            options: options
        ) {
            if app.state != .notRunning {
                app.terminate()
            }
            let launchStartedAt = ContinuousClock.now
            startMeasuring()
            app.launch()
            let reachedAccurateContent = expectedTitleElement.waitForExistence(
                timeout: maximumSeconds + 2
            )
            stopMeasuring()
            let elapsed = launchStartedAt.duration(to: .now)
            let seconds = Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000
            launchToAccurateContentSeconds.append(seconds)
            XCTAssertTrue(reachedAccurateContent, "The physical reference Store did not render its expected sentinel")
            XCTAssertLessThanOrEqual(
                seconds,
                maximumSeconds,
                "Physical launch-to-accurate-content exceeded the reference-device Release budget"
            )
        }

        let sortedDurations = launchToAccurateContentSeconds.sorted()
        XCTContext.runActivity(
            named: "physical_launch_to_accurate_content_seconds=\(sortedDurations) budget_seconds=\(maximumSeconds)"
        ) { _ in }
        tapWhenHittable(expectedTitleElement, timeout: 5)
        assertElementExists("sheet.message.detail", in: app, timeout: 8)
        XCTAssertTrue(
            app.staticTexts[expectedBody].exists,
            "The timely sentinel title must still resolve to the expected persisted body"
        )
    }
}
