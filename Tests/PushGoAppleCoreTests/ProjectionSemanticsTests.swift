import Foundation
import Testing
@testable import PushGoAppleCore

struct ProjectionSemanticsTests {
    @Test
    func topLevelEventProjectionAllowsEventHeadWithinThingScope() {
        #expect(
            ProjectionSemantics.isTopLevelEventProjection(
                entityType: "event",
                eventId: "evt_p4_boundary_001",
                thingId: "thing_p4_boundary_001",
                projectionDestination: "event_head"
            )
        )
    }

    @Test
    func topLevelEventProjectionRejectsThingSubEvents() {
        #expect(
            !ProjectionSemantics.isTopLevelEventProjection(
                entityType: "event",
                eventId: "evt_p4_boundary_002",
                thingId: "thing_p4_boundary_001",
                projectionDestination: "thing_sub_event"
            )
        )
    }

    @Test
    func topLevelEventProjectionTrimsWhitespaceAndCase() {
        #expect(
            ProjectionSemantics.isTopLevelEventProjection(
                entityType: " Event ",
                eventId: " evt_p4_boundary_003 ",
                thingId: " thing_p4_boundary_002 ",
                projectionDestination: " EVENT_HEAD "
            )
        )
    }

    @Test
    func topLevelEventProjectionRequiresEventIdentity() {
        #expect(
            !ProjectionSemantics.isTopLevelEventProjection(
                entityType: "event",
                eventId: "   ",
                thingId: nil,
                projectionDestination: nil
            )
        )
    }
}
