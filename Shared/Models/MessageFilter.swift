import Foundation

enum MessageFilter: Equatable, Hashable, Sendable {
    case all
    case unread
    case read
    case withURL
    case byServer(UUID)

    var title: String {
        switch self {
        case .all:
            return LocalizationProvider.localized("all")
        case .unread:
            return LocalizationProvider.localized("unread")
        case .read:
            return LocalizationProvider.localized("read")
        case .withURL:
            return LocalizationProvider.localized("contains_links")
        case .byServer:
            return LocalizationProvider.localized("by_server")
        }
    }

    static func availableFilters(messageId: UUID?) -> [MessageFilter] {
        var filters: [MessageFilter] = [.all, .unread, .read, .withURL]
        if let id = messageId {
            filters.append(.byServer(id))
        }
        return filters
    }
}
