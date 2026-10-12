import Foundation
import XCTest

@MainActor
extension PushGo_macOSUITests {
    func testPreparedLargeMessageStoreColdLaunchReachesAccurateContent() {
        let sessionID = "macos-performance-\(UUID().uuidString.lowercased())"
        let context = configuredQualityApp(sessionID: sessionID, fixture: "messages.large")
        let exactRow = element(
            in: context.app,
            identifier: "message.row.00000000-0000-0000-0000-0000000003e8"
        )

        // Build the deterministic 1,000-message canonical Store before the measured
        // interval. The measured user task starts from a cold process with existing data.
        launchQuality(context, sessionID: sessionID)
        XCTAssertTrue(
            exactRow.waitForExistence(timeout: 12),
            "The 1,000-message Store must expose its exact highest-index row before measurement."
        )
        XCTAssertTrue(exactRow.label.contains("Quality message 999"))
        context.app.terminate()

        let options = XCTMeasureOptions()
        options.iterationCount = 5
        options.invocationOptions = [.manuallyStart, .manuallyStop]
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
            let reachedAccurateContent = exactRow.waitForExistence(timeout: 8)
            stopMeasuring()
            let elapsed = launchStartedAt.duration(to: .now)
            let seconds = Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000
            launchToAccurateContentSeconds.append(seconds)
            XCTAssertTrue(
                reachedAccurateContent,
                "A cold macOS launch did not reach the exact prepared 1,000-message content."
            )
            XCTAssertLessThanOrEqual(
                seconds,
                8,
                "Local macOS launch-to-accurate-content exceeded the provisional gross-regression ceiling; this is not a physical Release SLO."
            )
        }

        // XCTest may invoke the block once for warm-up in addition to the five
        // measured iterations. Keep that warm-up under the max guard above, but
        // report and median only the same five samples represented by XCTMetrics.
        let measuredDurations = Array(launchToAccurateContentSeconds.suffix(options.iterationCount))
        XCTAssertEqual(measuredDurations.count, options.iterationCount)
        let sortedDurations = measuredDurations.sorted()
        let median = sortedDurations[sortedDurations.count / 2]
        XCTAssertLessThanOrEqual(
            median,
            5,
            "The five-sample local macOS median exceeded the provisional accurate-content trend ceiling."
        )
        XCTContext.runActivity(
            named: "macos_local_launch_to_accurate_content_seconds=\(sortedDurations) median_ceiling_seconds=5.0 max_ceiling_seconds=8.0 physical_release_baseline=NOT_RUN"
        ) { _ in }

        XCTAssertFalse(element(in: context.app, identifier: "state.messages.load_failed").exists)
        XCTAssertTrue(exactRow.label.contains("Quality message 999"))
        XCTAssertTrue(exactRow.isHittable, "The timely exact row must remain actionable.")
        exactRow.click()
        assertVisibleScreenThroughUI("screen.message.detail", in: context.app, timeout: 8)
        XCTAssertTrue(
            context.app.staticTexts["Deterministic app-owned performance fixture row 999."].exists,
            "The timely title must open the matching persisted canonical body."
        )
    }

    func testSlowLargeMessageLoadTripsAccurateContentBudget() {
        let sessionID = "macos-performance-negative-\(UUID().uuidString.lowercased())"
        let context = configuredQualityApp(
            sessionID: sessionID,
            fixture: "messages.large",
            messageLoadDelayMilliseconds: 8_000
        )
        let exactRow = element(
            in: context.app,
            identifier: "message.row.00000000-0000-0000-0000-0000000003e8"
        )

        // Seed outside the measured interval, then use the same cold process → Store →
        // view model → AppKit path as the positive test. The delay is not the oracle:
        // exact visible content and its matching detail must still arrive.
        launchQuality(context, sessionID: sessionID)
        XCTAssertTrue(exactRow.waitForExistence(timeout: 14))
        XCTAssertTrue(exactRow.label.contains("Quality message 999"))
        context.app.terminate()

        let expectationOptions = XCTExpectedFailure.Options()
        expectationOptions.isStrict = true
        expectationOptions.issueMatcher = { issue in
            issue.compactDescription.contains(
                "macOS slow-load negative control: launch-to-accurate-content took"
            ) && issue.compactDescription.contains("budget=8000ms")
        }
        XCTExpectFailure(
            "The controlled 8-second macOS load must trip the existing 8-second accurate-content ceiling.",
            options: expectationOptions
        )

        let launchStartedAt = ContinuousClock.now
        context.app.launch()
        let reachedAccurateContent = exactRow.waitForExistence(timeout: 14)
        let elapsed = launchStartedAt.duration(to: .now)
        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000
        XCTAssertTrue(
            reachedAccurateContent,
            "The deliberately delayed Store did not reach its exact canonical row."
        )
        let elapsedMilliseconds = Int((seconds * 1_000).rounded())
        XCTAssertLessThanOrEqual(
            seconds,
            8,
            "macOS slow-load negative control: launch-to-accurate-content took \(elapsedMilliseconds)ms; budget=8000ms"
        )
        XCTAssertTrue(exactRow.label.contains("Quality message 999"))
        XCTAssertTrue(exactRow.isHittable)
        exactRow.click()
        assertVisibleScreenThroughUI("screen.message.detail", in: context.app, timeout: 8)
        XCTAssertTrue(
            context.app.staticTexts["Deterministic app-owned performance fixture row 999."].exists,
            "The deliberately slow row must still open the matching persisted body."
        )
    }
}
