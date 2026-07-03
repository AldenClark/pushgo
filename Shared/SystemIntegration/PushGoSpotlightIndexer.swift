import Foundation

#if canImport(CoreSpotlight)
@preconcurrency import CoreSpotlight
#endif

protocol PushGoSpotlightIndexing: Sendable {
    func index(_ summaries: [PushGoSystemSummary]) async throws
    func delete(_ identifiers: [PushGoSpotlightIdentifier]) async throws
    func deleteAll() async throws
}

enum PushGoSpotlightIndexingError: Error, Equatable {
    case unavailable
}

struct PushGoSpotlightIndexOperation: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case index
        case delete
        case deleteAll
    }

    let kind: Kind
    let identifiers: [PushGoSpotlightIdentifier]
}

#if canImport(CoreSpotlight)
struct CoreSpotlightPushGoIndexer: PushGoSpotlightIndexing, @unchecked Sendable {
    private let searchableIndex: CSSearchableIndex

    init(searchableIndex: CSSearchableIndex = .default()) {
        self.searchableIndex = searchableIndex
    }

    func index(_ summaries: [PushGoSystemSummary]) async throws {
        let items = summaries.compactMap(Self.searchableItem(for:))
        guard !items.isEmpty else { return }
        try await searchableIndex.indexSearchableItems(items)
    }

    func delete(_ identifiers: [PushGoSpotlightIdentifier]) async throws {
        let unique = Array(Set(identifiers))
        guard !unique.isEmpty else { return }
        try await searchableIndex.deleteSearchableItems(withIdentifiers: unique.map(\.uniqueIdentifier))
    }

    func deleteAll() async throws {
        try await searchableIndex.deleteAllSearchableItems()
    }

    private static func searchableItem(for summary: PushGoSystemSummary) -> CSSearchableItem? {
        guard let identifier = PushGoSpotlightIdentifier(kind: summary.kind, identifier: summary.stableID),
              summary.privacy.mayIndexTitle
        else {
            return nil
        }
        let attributes = CSSearchableItemAttributeSet(contentType: .content)
        attributes.title = summary.title
        attributes.displayName = summary.title
        attributes.contentDescription = summary.bodyPreview ?? summary.subtitle ?? summary.status
        attributes.keywords = keywords(for: summary)
        attributes.identifier = identifier.uniqueIdentifier
        attributes.relatedUniqueIdentifier = summary.localMessageID?.uuidString
            ?? summary.eventID
            ?? summary.thingID
        attributes.contentCreationDate = summary.updatedAt
        attributes.contentModificationDate = summary.updatedAt
        attributes.userCreated = false
        attributes.userOwned = true
        if let imageURL = summary.imageURL {
            attributes.thumbnailURL = imageURL
        }
        let item = CSSearchableItem(
            uniqueIdentifier: identifier.uniqueIdentifier,
            domainIdentifier: identifier.domainIdentifier,
            attributeSet: attributes
        )
        item.expirationDate = .distantFuture
        return item
    }

    private static func keywords(for summary: PushGoSystemSummary) -> [String] {
        var values: [String] = [
            summary.kind.rawValue,
            summary.stableID,
            summary.subtitle,
            summary.status,
            summary.severity,
            summary.channelID,
            summary.eventID,
            summary.thingID,
        ].compactMap { value in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        values.append(contentsOf: summary.tags)
        if !summary.searchableText.isEmpty {
            values.append(summary.searchableText)
        }
        return Array(Set(values))
    }
}
#else
struct CoreSpotlightPushGoIndexer: PushGoSpotlightIndexing {
    func index(_ summaries: [PushGoSystemSummary]) async throws {
        _ = summaries
        throw PushGoSpotlightIndexingError.unavailable
    }

    func delete(_ identifiers: [PushGoSpotlightIdentifier]) async throws {
        _ = identifiers
        throw PushGoSpotlightIndexingError.unavailable
    }

    func deleteAll() async throws {
        throw PushGoSpotlightIndexingError.unavailable
    }
}
#endif

actor RecordingPushGoSpotlightIndexer: PushGoSpotlightIndexing {
    private(set) var operations: [PushGoSpotlightIndexOperation] = []

    func index(_ summaries: [PushGoSystemSummary]) async throws {
        let identifiers = summaries.compactMap {
            PushGoSpotlightIdentifier(kind: $0.kind, identifier: $0.stableID)
        }
        operations.append(PushGoSpotlightIndexOperation(kind: .index, identifiers: identifiers))
    }

    func delete(_ identifiers: [PushGoSpotlightIdentifier]) async throws {
        operations.append(PushGoSpotlightIndexOperation(kind: .delete, identifiers: identifiers))
    }

    func deleteAll() async throws {
        operations.append(PushGoSpotlightIndexOperation(kind: .deleteAll, identifiers: []))
    }
}
