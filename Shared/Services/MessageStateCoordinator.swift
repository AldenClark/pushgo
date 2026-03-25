import Foundation
import UserNotifications

@MainActor
final class MessageStateCoordinator {
    private let dataStore: LocalDataStore
    private let refreshCountsAndNotify: () async -> Void

    init(
        dataStore: LocalDataStore,
        refreshCountsAndNotify: @escaping () async -> Void,
    ) {
        self.dataStore = dataStore
        self.refreshCountsAndNotify = refreshCountsAndNotify
    }

    @discardableResult
    func markRead(messageId: UUID) async throws -> PushMessage? {
        guard var message = try await dataStore.loadMessage(id: messageId) else { return nil }
        if message.isRead == false {
            try await dataStore.setMessageReadState(id: messageId, isRead: true)
            message.isRead = true
        }
        removeDeliveredNotifications(for: message)
        await refreshCountsAndNotify()
        return message
    }

    @discardableResult
    func markRead(notificationRequestId: String, messageId: String?) async throws -> PushMessage? {
        if let messageId, let message = try await dataStore.loadMessage(messageId: messageId) {
            let updated = try await markRead(messageId: message.id)
            removeDeliveredNotifications(identifiers: [notificationRequestId])
            return updated
        }
        if let message = try await dataStore.loadMessage(notificationRequestId: notificationRequestId) {
            let updated = try await markRead(messageId: message.id)
            removeDeliveredNotifications(identifiers: [notificationRequestId])
            return updated
        }
        removeDeliveredNotifications(identifiers: [notificationRequestId])
        return nil
    }

    func markMessagesRead(filter: MessageQueryFilter, channel: String?) async throws -> Int {
        let candidates = try await dataStore.loadMessages(filter: filter, channel: channel)
        let unread = candidates.filter { !$0.isRead }
        let changed = try await dataStore.markMessagesRead(filter: filter, channel: channel)
        if changed > 0 {
            removeDeliveredNotifications(identifiers: notificationRequestIds(from: unread))
            await refreshCountsAndNotify()
        }
        return changed
    }

    func deleteMessage(messageId: UUID) async throws {
        let message = try await dataStore.loadMessage(id: messageId)
        try await dataStore.deleteMessage(id: messageId)
        if let message {
            removeDeliveredNotifications(identifiers: notificationRequestIds(from: [message]))
        }
        await refreshCountsAndNotify()
    }

    func deleteMessage(notificationRequestId: String, messageId: String?) async throws {
        var message: PushMessage?
        if let messageId {
            message = try await dataStore.loadMessage(messageId: messageId)
        }
        if message == nil {
            message = try await dataStore.loadMessage(notificationRequestId: notificationRequestId)
        }
        if let message {
            try await dataStore.deleteMessage(id: message.id)
        } else {
            try await dataStore.deleteMessage(notificationRequestId: notificationRequestId)
        }
        removeDeliveredNotifications(identifiers: [notificationRequestId])
        await refreshCountsAndNotify()
    }

    func deleteMessages(channel: String?, readState: Bool?) async throws -> Int {
        if channel == nil && readState == nil {
            return try await deleteAllMessages()
        }
        let filter = messageFilter(for: readState)
        let candidates = try await dataStore.loadMessages(filter: filter, channel: channel)
        let deletionCandidates = candidates.filter { readState == nil || $0.isRead == readState }
        let deleted = try await dataStore.deleteMessages(channel: channel, readState: readState)
        if deleted > 0 {
            removeDeliveredNotifications(identifiers: notificationRequestIds(from: deletionCandidates))
            await refreshCountsAndNotify()
        }
        return deleted
    }

    func deleteMessages(readState: Bool?, before cutoff: Date?) async throws -> Int {
        if readState == nil && cutoff == nil {
            return try await deleteAllMessages()
        }
        let filter = messageFilter(for: readState)
        let candidates = try await dataStore.loadMessages(filter: filter, channel: nil)
        let deletionCandidates = candidates.filter { message in
            if let cutoff {
                return message.receivedAt < cutoff
            }
            return true
        }
        let deleted = try await dataStore.deleteMessages(readState: readState, before: cutoff)
        if deleted > 0 {
            removeDeliveredNotifications(identifiers: notificationRequestIds(from: deletionCandidates))
            await refreshCountsAndNotify()
        }
        return deleted
    }

    @discardableResult
    func deleteAllMessages() async throws -> Int {
        let deletedCount = try await dataStore.deleteMessages(readState: nil, before: nil)
        removeAllDeliveredNotifications()
        await refreshCountsAndNotify()
        return deletedCount
    }

    func deleteOldestReadMessages(limit: Int, excludingChannels: [String]) async throws -> Int {
        guard limit > 0 else { return 0 }
        let candidates = try await dataStore.loadOldestReadMessages(
            limit: limit,
            excludingChannels: excludingChannels
        )
        guard !candidates.isEmpty else { return 0 }
        let deleted = try await dataStore.deleteOldestReadMessages(
            limit: limit,
            excludingChannels: excludingChannels
        )
        if deleted > 0 {
            removeDeliveredNotifications(identifiers: notificationRequestIds(from: candidates))
            await refreshCountsAndNotify()
        }
        return deleted
    }

    func pruneMessagesIfNeeded(maxCount: Int, batchSize: Int) async {
        let candidates = (try? await dataStore.loadPruneCandidates(
            maxCount: maxCount,
            batchSize: batchSize
        )) ?? []
        let deleted = await dataStore.pruneMessagesIfNeeded(
            maxCount: maxCount,
            batchSize: batchSize
        )
        if deleted > 0 {
            removeDeliveredNotifications(identifiers: notificationRequestIds(from: candidates))
            await refreshCountsAndNotify()
        }
    }

    private func messageFilter(for readState: Bool?) -> MessageQueryFilter {
        switch readState {
        case .some(true):
            return .readOnly
        case .some(false):
            return .unreadOnly
        case .none:
            return .all
        }
    }

    private func notificationRequestIds(from messages: [PushMessage]) -> [String] {
        messages.compactMap { message in
            let id = message.notificationRequestId?.trimmingCharacters(in: .whitespacesAndNewlines)
            return id?.isEmpty == false ? id : nil
        }
    }

    private func removeDeliveredNotifications(for message: PushMessage) {
        removeDeliveredNotifications(identifiers: notificationRequestIds(from: [message]))
    }

    private func removeDeliveredNotifications(identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    private func removeAllDeliveredNotifications() {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }
}
