import Foundation
import Observation

@MainActor
@Observable
final class MessageDetailViewModel {
    private(set) var message: PushMessage?
    private(set) var hasResolvedMessage = false
    private(set) var isLoading = false
    var alertMessage: String?

    private let environment: AppEnvironment
    private let messageId: UUID
    private let localizationManager: LocalizationManager
    private let dataStore: LocalDataStore
    private var seedMessage: PushMessage?

    init(
        environment: AppEnvironment? = nil,
        messageId: UUID,
        initialMessage: PushMessage? = nil,
        localizationManager: LocalizationManager? = nil,
    ) {
        let resolvedInitialMessage: PushMessage? = {
            guard let initialMessage else { return nil }
            guard initialMessage.id == messageId else { return nil }
            return initialMessage
        }()
        if let environment {
            self.environment = environment
        } else {
            self.environment = AppEnvironment.shared
        }
        self.messageId = messageId
        self.message = resolvedInitialMessage
        self.hasResolvedMessage = resolvedInitialMessage != nil
        self.localizationManager = localizationManager ?? LocalizationManager.shared
        dataStore = self.environment.dataStore
        seedMessage = resolvedInitialMessage
        Task { @MainActor in
            await loadMessage()
        }
    }

    func refresh() {
        Task { @MainActor in
            await loadMessage()
        }
    }

    func ensureLoaded() async {
        guard message == nil, !isLoading else { return }
        await loadMessage()
    }

    func markRead(_ isRead: Bool) async {
        guard isRead else { return }
        guard let message else { return }
        do {
            let updated = try await environment.messageStateCoordinator.markRead(messageId: message.id)
            self.message = updated ?? message
            MessageDetailSnapshotCache.shared.store(
                message: self.message,
                id: message.id,
                revision: environment.messageStoreRevision
            )
        } catch {
            alertMessage = AppError.wrap(
                error,
                fallbackMessage: localizationManager.localized("operation_failed"),
                code: "message_mark_read_failed"
            ).errorDescription
        }
    }

    func markAsReadIfNeeded() async {
        await ensureLoaded()
        guard let message, message.isRead == false else { return }
        await markRead(true)
    }

    func deleteMessage() async {
        guard let message else { return }
        do {
            try await environment.messageStateCoordinator.deleteMessage(messageId: message.id)
            self.message = nil
            hasResolvedMessage = true
            MessageDetailSnapshotCache.shared.removeAll(for: message.id)
        } catch {
            alertMessage = AppError.wrap(
                error,
                fallbackMessage: localizationManager.localized("operation_failed"),
                code: "message_delete_failed"
            ).errorDescription
        }
    }

    func copyBody() {
        guard let message else { return }
        Self.copyText(message.resolvedBody.rawText)
        alertMessage = localizationManager.localized("message_content_copied")
    }

    func copyLink() {
        guard let url = message?.url else { return }
        Self.copyText(url.absoluteString)
        alertMessage = localizationManager.localized("link_copied")
    }

    private static func copyText(_ text: String) {
        PushGoSystemInteraction.copyTextToPasteboard(text)
    }

    private func loadMessage() async {
        guard !isLoading else { return }
        isLoading = true
        defer {
            isLoading = false
            hasResolvedMessage = true
        }

        let revision = environment.messageStoreRevision
        let resolvedMessage: PushMessage?
        if let seeded = seedMessage {
            seedMessage = nil
            resolvedMessage = seeded
        } else {
            let result = await MessageDetailSnapshotCache.shared.loadMessage(
                id: messageId,
                revision: revision
            ) { [dataStore, messageId] in
                try await dataStore.loadMessage(id: messageId)
            }
            resolvedMessage = result.message
        }

        if let resolvedMessage {
            message = resolvedMessage
            hasResolvedMessage = true
            MessageDetailSnapshotCache.shared.store(
                message: resolvedMessage,
                id: messageId,
                revision: revision
            )
            scheduleDetailImageMetadataPreheat(for: resolvedMessage)
        } else {
            message = nil
        }
    }

    private func scheduleDetailImageMetadataPreheat(for message: PushMessage) {
        let bodyText = message.resolvedBody.rawText
        let directImageURLs = message.imageURLs
        Task.detached(priority: .utility) {
            let imageURLs = resolvedDetailImageAssetURLs(
                bodyText: bodyText,
                directImageURLs: directImageURLs
            )
            guard !imageURLs.isEmpty else { return }
            await SharedImageCache.primeMetadataSnapshots(for: imageURLs)
            await SharedImageCache.preheatMetadata(
                for: imageURLs,
                maxBytes: AppConstants.maxMessageImageBytes,
                timeout: 10
            )
        }
    }
}

func resolvedDetailImageAssetURLs(for message: PushMessage) -> [URL] {
    resolvedDetailImageAssetURLs(
        bodyText: message.resolvedBody.rawText,
        directImageURLs: message.imageURLs
    )
}

func resolvedDetailImageAssetURLs(bodyText: String, directImageURLs: [URL]) -> [URL] {
    let markdownImageURLs = MarkdownImageURLExtractor.extractURLs(from: bodyText)
    return Array(Set(directImageURLs + markdownImageURLs))
}

@MainActor
final class MessageDetailSnapshotCache {
    static let shared = MessageDetailSnapshotCache()

    enum LoadSource: String {
        case cache
        case inFlight
        case storage
    }

    struct LoadResult {
        let message: PushMessage?
        let source: LoadSource
    }

    private struct Key: Hashable {
        let id: UUID
        let revision: UUID
    }

    private struct Entry {
        let message: PushMessage?
    }

    private let capacity: Int = 256
    private var entries: [Key: Entry] = [:]
    private var order: [Key] = []
    private var inFlight: [Key: Task<PushMessage?, Never>] = [:]

    private init() {}

    func loadMessage(
        id: UUID,
        revision: UUID,
        loader: @escaping () async throws -> PushMessage?
    ) async -> LoadResult {
        let key = Key(id: id, revision: revision)

        if let cached = entries[key] {
            touch(key)
            return LoadResult(message: cached.message, source: .cache)
        }

        if let task = inFlight[key] {
            let message = await task.value
            return LoadResult(message: message, source: .inFlight)
        }

        let task = Task<PushMessage?, Never> {
            do {
                return try await loader()
            } catch {
                return nil
            }
        }
        inFlight[key] = task
        let loaded = await task.value
        inFlight[key] = nil

        entries[key] = Entry(message: loaded)
        touch(key)
        trimIfNeeded()
        return LoadResult(message: loaded, source: .storage)
    }

    func prefetchMessage(
        id: UUID,
        revision: UUID,
        loader: @escaping () async throws -> PushMessage?
    ) async {
        _ = await loadMessage(id: id, revision: revision, loader: loader)
    }

    func store(message: PushMessage?, id: UUID, revision: UUID) {
        let key = Key(id: id, revision: revision)
        entries[key] = Entry(message: message)
        touch(key)
        trimIfNeeded()
    }

    func removeAll(for messageId: UUID) {
        entries = entries.filter { $0.key.id != messageId }
        order.removeAll { $0.id == messageId }
        let keysToRemove = inFlight.keys.filter { $0.id == messageId }
        for key in keysToRemove {
            inFlight[key]?.cancel()
            inFlight[key] = nil
        }
    }

    private func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func trimIfNeeded() {
        guard entries.count > capacity else { return }
        let overflow = entries.count - capacity
        guard overflow > 0 else { return }
        for _ in 0 ..< overflow {
            guard let oldest = order.first else { break }
            order.removeFirst()
            entries.removeValue(forKey: oldest)
        }
    }
}
