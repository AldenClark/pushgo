import Foundation

enum ProjectionSemantics {
    static func normalizedProjectionDestination(_ value: String?) -> String? {
        normalizedComponent(value)?.lowercased()
    }

    static func isTopLevelEventProjection(
        entityType: String,
        eventId: String?,
        thingId: String?,
        projectionDestination: String?,
    ) -> Bool {
        guard normalizedComponent(entityType)?.lowercased() == "event",
              normalizedComponent(eventId) != nil
        else {
            return false
        }
        if normalizedComponent(thingId) == nil {
            return true
        }
        return normalizedProjectionDestination(projectionDestination) == "event_head"
    }

    private static func normalizedComponent(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
