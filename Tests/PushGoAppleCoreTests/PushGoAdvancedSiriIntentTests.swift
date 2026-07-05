import Foundation
import Testing
@testable import PushGoAppleCore

#if canImport(AppIntents)
struct PushGoAdvancedSiriIntentTests {
    @Test
    func advancedSiriSummaryFiltersPriorityAndAvoidsSensitiveContent() {
        let now = Date()
        let safeCritical = item(
            id: "event:evt-critical",
            kind: .event,
            title: "Database outage",
            severity: "critical",
            updatedAt: now
        )
        let safeHigh = item(
            id: "event:evt-high",
            kind: .event,
            title: "Disk pressure",
            severity: "high",
            updatedAt: now.addingTimeInterval(-60)
        )
        let snapshot = PushGoSystemSurfaceSnapshot(
            schemaVersion: PushGoSystemSurfaceSnapshot.schemaVersion,
            generatedAtEpochMs: PushGoSystemSurfaceSnapshot.epochMilliseconds(now),
            source: "tests",
            counts: .init(totalMessages: 2, unreadMessages: 0, criticalEvents: 2, objectWarnings: 0),
            focusState: .default(now: now),
            recentMessages: [],
            unreadMessages: [],
            criticalEvents: [safeHigh, safeCritical],
            objectWarnings: [],
            latestObjectStates: []
        )

        let summary = PushGoAdvancedSiriSummaryProvider.summary(
            query: .criticalEvents,
            timeRange: .last24Hours,
            priority: .critical,
            snapshot: snapshot
        )

        #expect(summary.contains("Database outage"))
        #expect(!summary.contains("Disk pressure"))
        #expect(!summary.contains("raw"))
    }

    @Test
    func objectStatusSummaryUsesWarningObjects() {
        let warning = item(
            id: "thing:server-1",
            kind: .thing,
            title: "Server 1",
            status: "warning",
            updatedAt: Date()
        )
        let snapshot = PushGoSystemSurfaceSnapshot(
            schemaVersion: PushGoSystemSurfaceSnapshot.schemaVersion,
            generatedAtEpochMs: PushGoSystemSurfaceSnapshot.epochMilliseconds(Date()),
            source: "tests",
            counts: .init(totalMessages: 0, unreadMessages: 0, criticalEvents: 0, objectWarnings: 1),
            focusState: .default(),
            recentMessages: [],
            unreadMessages: [],
            criticalEvents: [],
            objectWarnings: [warning],
            latestObjectStates: [warning]
        )

        let summary = PushGoAdvancedSiriSummaryProvider.summary(
            query: .objectStatus,
            timeRange: .latest,
            priority: .any,
            snapshot: snapshot
        )

        #expect(summary.contains("Server 1"))
    }

    private func item(
        id: String,
        kind: PushGoSystemEntityKind,
        title: String,
        status: String? = nil,
        severity: String? = nil,
        updatedAt: Date
    ) -> PushGoSystemSurfaceSnapshot.Item {
        PushGoSystemSurfaceSnapshot.Item(
            id: id,
            kind: kind,
            title: title,
            subtitle: nil,
            bodyPreview: nil,
            status: status,
            severity: severity,
            channelID: "ops",
            eventID: kind == .event ? id.replacingOccurrences(of: "event:", with: "") : nil,
            thingID: kind == .thing ? id.replacingOccurrences(of: "thing:", with: "") : nil,
            updatedAtEpochMs: PushGoSystemSurfaceSnapshot.epochMilliseconds(updatedAt),
            imageURL: nil,
            accessibilityLabel: title,
            accessibilityValue: nil,
            openTarget: nil
        )
    }
}
#endif
