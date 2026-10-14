import Foundation
import GRDB
import Testing
@testable import PushGoAppleCore

@MainActor
struct ChannelRemovalControllerTests {
    @Test
    func preparingThenCancellingChannelRemovalHasNoLocalOrRemoteEffects() async throws {
        try await withIsolatedLocalDataStore { @MainActor store, appGroup in
            let fixture = try await Fixture.make(store: store)
            let deviceKey = UUID().uuidString
            #expect(ProviderDeviceKeyStore().save(deviceKey: deviceKey, platform: "macos").didPersist)
            LocalDataStore.saveWakeupIngressDeviceKeyDefaults("defaults-sentinel", platform: "macos", suiteName: appGroup)
            #expect(LocalDataStore.loadWakeupIngressDeviceKeyDefaults(platform: "macos", suiteName: appGroup) == "defaults-sentinel")
            let target = try await fixture.prepare()
            #expect(target.channelID == fixture.subscription.channelId)
            #expect(target.password == fixture.credential)
            #expect(target.originalDeviceKey == deviceKey)
            #expect(LocalDataStore.loadWakeupIngressDeviceKeyDefaults(platform: "macos", suiteName: appGroup) == "defaults-sentinel")
            #expect(fixture.remote.calls.isEmpty)
            #expect(try await store.loadPendingLocalDeletions(now: Date()).isEmpty)
            #expect(try await store.loadChannelSubscriptions(gateway: fixture.original.gatewayKey, includeDeleted: false).count == 1)
        }
    }

    @Test(arguments: [true, false])
    func acceptedRemovalKeepsOriginalDestinationAfterGatewayChanges(keepHistory: Bool) async throws {
        try await withIsolatedLocalDataStore { @MainActor store, _ in
            let fixture = try await Fixture.make(store: store)
            let message = Self.message(channel: fixture.subscription.channelId)
            let control = Self.message(channel: "control")
            try await store.saveMessage(message)
            try await store.saveMessage(control)
            var target = try await fixture.prepare()
            target.keepHistory = keepHistory
            let receipt = try await store.acceptConfirmedChannelRemoval(target)
            #expect(try await store.acceptConfirmedChannelRemoval(target).id == receipt.id)
            fixture.current.config = ServerConfig(baseURL: URL(string: "https://replacement.example/GatewayB")!, token: UUID().uuidString)
            let claimed = try #require(try await store.claimNextPendingLocalDeletion(owner: "test", leaseDuration: 30, now: Date()))
            let cleanup = try await fixture.controller.commitPendingChannelRemoval(record: claimed, leaseOwner: "test")
            #expect(fixture.remote.calls == [.unsubscribe(fixture.original.baseURL, fixture.original.token, target.channelID)])
            #expect(try await store.loadChannelSubscriptions(gateway: fixture.original.gatewayKey, includeDeleted: false).isEmpty)
            #expect(try await store.loadMessage(id: message.id) == (keepHistory ? message : nil))
            #expect(try await store.loadMessage(id: control.id) == control)
            #expect(cleanup.deletedRecordCount == (keepHistory ? 0 : 1))
            let receipts = try await store.loadPendingLocalDeletions(now: Date())
            #expect(receipts.count == 1)
            #expect(receipts.first?.state == .cleanupPending)
            #expect(receipts.first?.cleanup == cleanup)
        }
    }

    @Test(arguments: [false, true])
    func actualUnsubscribeUsesCapturedDeviceRouteAndNeverRegistersReplacement(missingOriginalKey: Bool) async throws {
        try await withIsolatedLocalDataStore { @MainActor store, _ in
            let requests = RequestCapture()
            let service = ChannelSubscriptionService(requestTransport: { request in
                await requests.append(request)
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (Data(#"{"success":true,"data":{"channel_id":"01ARZ3NDEKTSV4RRFFQ69G5FAV","removed":true}}"#.utf8), response)
            })
            let fixture = try await Fixture.make(store: store, service: service, useRemote: false)
            let capturedKey = UUID().uuidString
            let target = PendingChannelRemovalTarget(channelID: fixture.subscription.channelId, originalConfig: fixture.original,
                expectedUpdatedAt: fixture.subscription.updatedAt, password: fixture.credential,
                originalDeviceKey: missingOriginalKey ? nil : capturedKey, keepHistory: true)
            _ = try await store.acceptConfirmedChannelRemoval(target)
            fixture.current.config = ServerConfig(baseURL: URL(string: "https://replacement.example")!, token: UUID().uuidString)
            let claimed = try #require(try await store.claimNextPendingLocalDeletion(owner: "test", leaseDuration: 30, now: Date()))
            do {
                _ = try await fixture.controller.commitPendingChannelRemoval(record: claimed, leaseOwner: "test")
                #expect(!missingOriginalKey)
            } catch {
                #expect(missingOriginalKey)
                #expect((error as? AppError)?.code == "channel_removal_reconciliation_required")
            }
            let capturedRequests = await requests.values
            if missingOriginalKey {
                #expect(capturedRequests.isEmpty)
                #expect(try await store.loadChannelSubscriptions(gateway: fixture.original.gatewayKey, includeDeleted: false).count == 1)
            } else {
                let request = try #require(capturedRequests.first)
                #expect(capturedRequests.count == 1)
                #expect(request.url?.absoluteString == fixture.original.baseURL.absoluteString + "/channel/unsubscribe")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + (fixture.original.token ?? ""))
                let requestBody = try #require(request.httpBody)
                let body = try #require(try JSONSerialization.jsonObject(with: requestBody) as? [String: String])
                #expect(body["device_key"] == capturedKey)
                #expect(body["channel_id"] == target.channelID)
            }
        }
    }

    @Test
    func remoteFailurePreservesSubscriptionHistoryAndAcceptedReceipt() async throws {
        try await withIsolatedLocalDataStore { @MainActor store, _ in
            let fixture = try await Fixture.make(store: store)
            let message = Self.message(channel: fixture.subscription.channelId)
            try await store.saveMessage(message)
            let target = try await fixture.prepare()
            _ = try await store.acceptConfirmedChannelRemoval(target)
            fixture.remote.rejectUnsubscribe = true
            let claimed = try #require(try await store.claimNextPendingLocalDeletion(owner: "test", leaseDuration: 30, now: Date()))
            do { _ = try await fixture.controller.commitPendingChannelRemoval(record: claimed, leaseOwner: "test"); Issue.record("Remote failure deleted data") }
            catch { #expect((error as? AppError)?.code == "test_remote_rejected") }
            #expect(try await store.loadMessage(id: message.id) == message)
            #expect(try await store.activeChannelPassword(gateway: fixture.original.gatewayKey, for: target.channelID) == target.password)
            #expect(try await store.loadPendingLocalDeletions(now: Date()).first?.id == claimed.id)
            #expect(fixture.remote.calls.count == 1)
        }
    }

    @Test
    func localFailureCompensatesWithCapturedCredentialAndKeepsReceiptRetryable() async throws {
        try await withIsolatedLocalDataStore { @MainActor store, appGroup in
            let fixture = try await Fixture.make(store: store)
            let message = Self.message(channel: fixture.subscription.channelId)
            try await store.saveMessage(message)
            let target = try await fixture.prepare()
            _ = try await store.acceptConfirmedChannelRemoval(target)
            let directory = try AppConstants.appLocalDatabaseDirectory(appGroupIdentifier: appGroup)
            let queue = try DatabaseQueue(path: directory.appendingPathComponent(AppConstants.databaseStoreFilename).path)
            try await queue.write { db in
                try db.execute(sql: "CREATE TRIGGER reject_channel_removal BEFORE UPDATE OF is_deleted ON channel_subscriptions BEGIN SELECT RAISE(ABORT, 'injected channel commit failure'); END;")
            }
            let claimed = try #require(try await store.claimNextPendingLocalDeletion(owner: "test", leaseDuration: 30, now: Date()))
            fixture.current.config = ServerConfig(baseURL: URL(string: "https://replacement.example")!, token: UUID().uuidString)
            do { _ = try await fixture.controller.commitPendingChannelRemoval(record: claimed, leaseOwner: "test"); Issue.record("Local failure was ignored") }
            catch { #expect(error.localizedDescription.contains("injected channel commit failure")) }
            #expect(fixture.remote.calls == [
                .unsubscribe(fixture.original.baseURL, fixture.original.token, target.channelID),
                .subscribe(fixture.original.baseURL, fixture.original.token, target.channelID, fixture.credential),
            ])
            #expect(try await store.loadMessage(id: message.id) == message)
            #expect(try await store.activeChannelPassword(gateway: fixture.original.gatewayKey, for: target.channelID) == target.password)
            #expect(try await store.loadPendingLocalDeletions(now: Date()).first?.state == .executing)
            try await queue.write { db in try db.execute(sql: "DROP TRIGGER reject_channel_removal;") }
            _ = try await fixture.controller.commitPendingChannelRemoval(record: claimed, leaseOwner: "test")
            #expect(try await store.loadMessage(id: message.id) == nil)
        }
    }

    @Test(arguments: [false, true])
    func changedSubscriptionNeverDeletesOrCompensatesReplacement(duringRemoteCall: Bool) async throws {
        try await withIsolatedLocalDataStore { @MainActor store, _ in
            let fixture = try await Fixture.make(store: store)
            let message = Self.message(channel: fixture.subscription.channelId)
            try await store.saveMessage(message)
            let target = try await fixture.prepare()
            _ = try await store.acceptConfirmedChannelRemoval(target)
            let replacementCredential = UUID().uuidString
            let replace: @MainActor () async throws -> Void = {
                try await store.upsertChannelSubscription(gateway: fixture.original.gatewayKey, channelId: target.channelID,
                    displayName: "replacement", password: replacementCredential, lastSyncedAt: nil,
                    updatedAt: target.expectedUpdatedAt.addingTimeInterval(1), isDeleted: false, deletedAt: nil)
            }
            if duringRemoteCall { fixture.remote.afterUnsubscribe = replace }
            else { try await replace() }
            let claimed = try #require(try await store.claimNextPendingLocalDeletion(owner: "test", leaseDuration: 30, now: Date()))
            do { _ = try await fixture.controller.commitPendingChannelRemoval(record: claimed, leaseOwner: "test"); Issue.record("Changed target was deleted") }
            catch { #expect((error as? AppError)?.code == (duringRemoteCall ? "channel_removal_reconciliation_required" : "channel_subscription_changed_during_removal")) }
            #expect(fixture.remote.calls == (duringRemoteCall ? [.unsubscribe(fixture.original.baseURL, fixture.original.token, target.channelID)] : []))
            #expect(try await store.loadMessage(id: message.id) == message)
            #expect(try await store.activeChannelPassword(gateway: fixture.original.gatewayKey, for: target.channelID) == replacementCredential)
            try await store.markPendingLocalDeletionReconciliationRequired(id: claimed.id, owner: "test", errorCode: "channel_removal_reconciliation_required")
            #expect(try await store.acceptConfirmedChannelRemoval(target).id == claimed.id)
            #expect(try await store.pendingLocalDeletionRecoveryCount() == 1)
        }
    }

    @Test(arguments: [false, true])
    func historyChangedDuringRemoteCallRollsBackCleanupAndRestoresOriginalSubscription(replaceExistingMessage: Bool) async throws {
        try await withIsolatedLocalDataStore { @MainActor store, _ in
            let fixture = try await Fixture.make(store: store)
            let message = Self.message(channel: fixture.subscription.channelId)
            try await store.saveMessage(message)
            let control = Self.message(channel: "unrelated-history")
            try await store.saveMessage(control)
            let target = try await fixture.prepare()
            _ = try await store.acceptConfirmedChannelRemoval(target)
            var changed = replaceExistingMessage ? message : Self.message(channel: fixture.subscription.channelId)
            changed.body = "history received during the remote request"
            let changedMessage = changed
            fixture.remote.afterUnsubscribe = { try await store.saveMessage(changedMessage) }
            let claimed = try #require(try await store.claimNextPendingLocalDeletion(owner: "test", leaseDuration: 30, now: Date()))
            do { _ = try await fixture.controller.commitPendingChannelRemoval(record: claimed, leaseOwner: "test"); Issue.record("Changed history was deleted") }
            catch { #expect((error as? AppError)?.code == "channel_history_changed_during_removal") }
            #expect(try await store.loadMessage(id: changedMessage.id)?.body == changedMessage.body)
            #expect(try await store.loadMessage(id: message.id) != nil)
            #expect(try await store.activeChannelPassword(gateway: fixture.original.gatewayKey, for: target.channelID) == fixture.credential)
            #expect(fixture.remote.calls == [
                .unsubscribe(fixture.original.baseURL, fixture.original.token, target.channelID),
                .subscribe(fixture.original.baseURL, fixture.original.token, target.channelID, fixture.credential),
            ])
            #expect(try await store.loadPendingLocalDeletions(now: Date()).first?.id == claimed.id)
            try await store.markPendingLocalDeletionReconciliationRequired(id: claimed.id, owner: "test", errorCode: "channel_history_changed_during_removal")
            try await store.retryPendingLocalDeletionRecovery(now: Date())
            #expect(try await store.pendingLocalDeletionRecoveryCount() == 1)
            #expect(try await store.claimNextPendingLocalDeletion(owner: "generic-retry", leaseDuration: 30, now: Date()) == nil)

            let freshConfirmation = try await fixture.prepare()
            #expect(freshConfirmation.originalDeviceKey == target.originalDeviceKey)
            #expect(try await store.acceptConfirmedChannelRemoval(freshConfirmation).id == claimed.id)
            fixture.remote.afterUnsubscribe = nil
            let freshClaim = try #require(try await store.claimNextPendingLocalDeletion(owner: "reconfirmed", leaseDuration: 30, now: Date()))
            #expect(freshClaim.id == claimed.id)
            _ = try await fixture.controller.commitPendingChannelRemoval(record: freshClaim, leaseOwner: "reconfirmed")
            #expect(try await store.loadMessage(id: message.id) == nil)
            #expect(try await store.loadMessage(id: changedMessage.id) == nil)
            #expect(try await store.loadMessage(id: control.id) == control)
            #expect(try await store.pendingLocalDeletionRecoveryCount() == 0)
            #expect(try await store.loadPendingLocalDeletions(now: Date()).first?.state == .cleanupPending)
        }
    }

    @Test
    func inFlightRemovalRejectsSameSubscriptionMutationAndReleasesGuardAfterCommit() async throws {
        try await withIsolatedLocalDataStore { @MainActor store, _ in
            let fixture = try await Fixture.make(store: store)
            let target = try await fixture.prepare()
            _ = try await store.acceptConfirmedChannelRemoval(target)
            fixture.remote.afterUnsubscribe = {
                do {
                    _ = try await fixture.controller.subscribeChannel(channelId: target.channelID, password: fixture.credential)
                    Issue.record("Existing subscription overlapped its pending unsubscribe")
                } catch {
                    #expect((error as? AppError)?.code == "channel_mutation_in_progress")
                }
            }
            let claimed = try #require(try await store.claimNextPendingLocalDeletion(owner: "test", leaseDuration: 30, now: Date()))
            _ = try await fixture.controller.commitPendingChannelRemoval(record: claimed, leaseOwner: "test")
            #expect(fixture.remote.calls == [.unsubscribe(fixture.original.baseURL, fixture.original.token, target.channelID)])
            #expect(try await store.loadChannelSubscriptions(gateway: fixture.original.gatewayKey, includeDeleted: false).isEmpty)
            _ = try await fixture.controller.subscribeChannel(channelId: target.channelID, password: fixture.credential)
            #expect(fixture.remote.calls == [
                .unsubscribe(fixture.original.baseURL, fixture.original.token, target.channelID),
                .subscribe(fixture.original.baseURL, fixture.original.token, target.channelID, fixture.credential),
            ])
            #expect(try await store.loadChannelSubscriptions(gateway: fixture.original.gatewayKey, includeDeleted: false).count == 1)
        }
    }

    @Test
    func removalWaitsForSentSyncAndDeferredSyncReadsCommittedSubscriptions() async throws {
        try await withIsolatedLocalDataStore { @MainActor store, _ in
            let controlledSync = ControlledSyncRemote()
            let fixture = try await Fixture.make(store: store, syncRoundTrip: controlledSync)
            let target = try await fixture.prepare()
            _ = try await store.acceptConfirmedChannelRemoval(target)
            let claimed = try #require(try await store.claimNextPendingLocalDeletion(owner: "test", leaseDuration: 30, now: Date()))
            fixture.remote.afterUnsubscribe = { controlledSync.events.append("unsubscribe") }
            let syncTask = Task { try await fixture.sync.syncSubscriptionsIfNeeded() }
            await controlledSync.waitForStart()
            let removalTask = Task { try await fixture.controller.commitPendingChannelRemoval(record: claimed, leaseOwner: "test") }
            let started = ContinuousClock.now
            while !fixture.sync.testingChannelRemovalWindowIsActive && ContinuousClock.now - started < .seconds(3) {
                await Task.yield()
            }
            #expect(fixture.sync.testingChannelRemovalWindowIsActive)
            #expect(fixture.remote.calls.isEmpty)
            // A new entry while deletion is waiting must defer rather than send
            // another snapshot of the still-active subscription.
            let deferredSyncTask = Task { try await fixture.sync.syncSubscriptionsIfNeeded() }
            await Task.yield()
            controlledSync.release()
            try await syncTask.value
            _ = try await removalTask.value
            try await deferredSyncTask.value
            try await fixture.sync.syncSubscriptionsIfNeeded()
            #expect(controlledSync.events == ["sync.start", "sync.finish", "unsubscribe"])
            #expect(controlledSync.requestedChannels == [[target.channelID]])
            #expect(try await store.loadChannelSubscriptions(gateway: fixture.original.gatewayKey, includeDeleted: false).isEmpty)
        }
    }

    @Test
    func executorLosingLeaseNeverResubscribesBehindReplacementExecutor() async throws {
        try await withIsolatedLocalDataStore { @MainActor store, _ in
            let fixture = try await Fixture.make(store: store)
            let target = try await fixture.prepare()
            let receipt = try await store.acceptConfirmedChannelRemoval(target)
            fixture.remote.afterUnsubscribe = {
                try await store.retryClaimedPendingLocalDeletion(id: receipt.id, owner: "test", retryAfter: Date(), errorCode: "test_takeover")
                _ = try await store.claimNextPendingLocalDeletion(owner: "replacement", leaseDuration: 30, now: Date())
            }
            let claimed = try #require(try await store.claimNextPendingLocalDeletion(owner: "test", leaseDuration: 30, now: Date()))
            do { _ = try await fixture.controller.commitPendingChannelRemoval(record: claimed, leaseOwner: "test"); Issue.record("Lost lease committed") }
            catch { #expect((error as? AppError)?.code == "channel_removal_lease_changed") }
            #expect(fixture.remote.calls == [.unsubscribe(fixture.original.baseURL, fixture.original.token, target.channelID)])
            #expect(try await store.loadPendingLocalDeletions(now: Date()).first?.leaseOwner == "replacement")
            #expect(try await store.loadChannelSubscriptions(gateway: fixture.original.gatewayKey, includeDeleted: false).count == 1)
        }
    }

    @Test(arguments: [false, true])
    func legacyAcceptedChannelIntentUsesOriginalGatewayOrRetainsRecovery(originalGatewayUnavailable: Bool) async throws {
        try await withIsolatedLocalDataStore { @MainActor store, _ in
            // This reference-epoch value changes by one Date ULP through the
            // receipt's millisecond codec, reproducing the first PR failure.
            let fixture = try await Fixture.make(store: store,
                configUpdatedAt: Date(timeIntervalSinceReferenceDate: 813_638_686.46743))
            _ = try await store.seedLegacyPendingLocalDeletion(summary: "legacy", undoLabel: "Undo",
                intent: .channelHistory(channelID: fixture.subscription.channelId, expectedGateway: fixture.original.gatewayKey,
                    expectedUpdatedAt: fixture.subscription.updatedAt), timeout: 0, now: Date())
            if originalGatewayUnavailable { fixture.current.config = ServerConfig(baseURL: URL(string: "https://replacement.example")!) }
            let worker = PendingLocalDeletionController(dataStore: store, channelCommitHandler: { record, owner in
                try await fixture.controller.commitPendingChannelRemoval(record: record, leaseOwner: owner)
            })
            await worker.restoreAndReconcile()
            #expect(worker.recoveryRequiredCount == (originalGatewayUnavailable ? 1 : 0))
            #expect(worker.isDormant == !originalGatewayUnavailable)
            #expect(fixture.remote.calls == (originalGatewayUnavailable ? [] : [.unsubscribe(fixture.original.baseURL, fixture.original.token, fixture.subscription.channelId)]))
            #expect(try await store.pendingLocalDeletionRecoveryCount() == (originalGatewayUnavailable ? 1 : 0))
            #expect(try await store.loadChannelSubscriptions(gateway: fixture.original.gatewayKey, includeDeleted: false).count == (originalGatewayUnavailable ? 1 : 0))
        }
    }

    nonisolated private static func message(channel: String) -> PushMessage {
        let id = UUID()
        return PushMessage(id: id, messageId: id.uuidString, title: "history", body: "body", channel: channel, receivedAt: Date(timeIntervalSince1970: 1_741_572_800),
            rawPayload: ["message_id": AnyCodable(id.uuidString)])
    }

    private actor RequestCapture {
        var values: [URLRequest] = []
        func append(_ request: URLRequest) { values.append(request) }
    }

    @MainActor
    private final class ControlledSyncRemote: ChannelSubscriptionSyncRoundTrip {
        var events: [String] = []
        var requestedChannels: [[String]] = []
        private var startWaiter: CheckedContinuation<Void, Never>?
        private var releaseWaiter: CheckedContinuation<Void, Never>?
        func waitForStart() async {
            guard requestedChannels.isEmpty else { return }
            await withCheckedContinuation { startWaiter = $0 }
        }
        func release() { releaseWaiter?.resume(); releaseWaiter = nil }
        func sync(baseURL: URL, channels: [ChannelSubscriptionService.SyncItem]) async throws -> ChannelSubscriptionService.SyncPayload {
            requestedChannels.append(channels.map(\.channelId))
            events.append("sync.start")
            startWaiter?.resume(); startWaiter = nil
            if requestedChannels.count == 1 { await withCheckedContinuation { releaseWaiter = $0 } }
            events.append("sync.finish")
            return .init(success: channels.count, failed: 0, channels: channels.map {
                .init(channelId: $0.channelId, channelName: nil, subscribed: true, error: nil, errorCode: nil, problem: nil)
            })
        }
    }

    @MainActor
    private final class CurrentConfig {
        var config: ServerConfig?
        init(_ config: ServerConfig) { self.config = config }
    }

    @MainActor
    private final class Remote: ChannelMutationRoundTrip {
        enum Call: Equatable {
            case unsubscribe(URL, String?, String)
            case subscribe(URL, String?, String?, String)
        }
        var calls: [Call] = []
        var rejectUnsubscribe = false
        var afterUnsubscribe: (@MainActor () async throws -> Void)?
        func subscribe(baseURL: URL, token: String?, channelId: String?, channelName: String?, credential: String) async throws -> ChannelSubscriptionService.SubscribePayload {
            calls.append(.subscribe(baseURL, token, channelId, credential))
            return .init(channelId: channelId ?? "created", channelName: channelName ?? "name", created: false, subscribed: true)
        }
        func rename(baseURL: URL, token: String?, channelId: String, channelName: String, credential: String) async throws -> ChannelSubscriptionService.RenamePayload {
            .init(channelId: channelId, channelName: channelName)
        }
        func unsubscribe(baseURL: URL, token: String?, channelId: String) async throws {
            calls.append(.unsubscribe(baseURL, token, channelId))
            if rejectUnsubscribe {
                throw AppError.typedLocal(code: "test_remote_rejected", category: .network, message: "Remote rejected")
            }
            try await afterUnsubscribe?()
        }
    }

    @MainActor
    private struct Fixture {
        let original: ServerConfig
        let subscription: ChannelSubscription
        let credential: String
        let current: CurrentConfig
        let remote: Remote
        let controller: ChannelSubscriptionController
        let sync: ChannelSyncController

        func prepare() async throws -> PendingChannelRemovalTarget {
            try await controller.prepareChannelRemoval(subscription: subscription, originalConfig: original, keepHistory: false)
        }

        static func make(store: LocalDataStore, service: ChannelSubscriptionService = .init(), useRemote: Bool = true, syncRoundTrip: (any ChannelSubscriptionSyncRoundTrip)? = nil, configUpdatedAt: Date = Date()) async throws -> Fixture {
            // Canonical keys use this test's isolated storage root. An absent
            // key would fall through to defaults shared by parallel tests.
            try #require(ProviderDeviceKeyStore().save(deviceKey: UUID().uuidString, platform: "macos").didPersist)
            let original = ServerConfig(baseURL: URL(string: "https://original.example/GatewayA")!, token: UUID().uuidString, updatedAt: configUpdatedAt)
            let current = CurrentConfig(original)
            let remote = Remote()
            let credential = UUID().uuidString
            let subscription = try await store.upsertChannelSubscription(gateway: original.gatewayKey, channelId: "01ARZ3NDEKTSV4RRFFQ69G5FAV",
                displayName: "Original", password: credential, lastSyncedAt: nil)
            let localization = LocalizationManager()
            let route = ProviderRouteController(platform: "macos", dataStore: store, channelSubscriptionService: service,
                localizationManager: localization, refreshAutomationState: {}, runtimeMessageRecorder: { _, _, _, _ in })
            let sync = ChannelSyncController(platform: "macos", dataStore: store, pushRegistrationService: .testing(),
                channelSubscriptionService: service, providerRouteController: route, subscriptionSyncRoundTrip: syncRoundTrip, localizationManager: localization,
                serverConfigProvider: { current.config }, requestWatchStandaloneProvisioningSync: { _ in },
                recordRuntimeError: { _, _ in }, showToast: { _ in }, showChannelEntryFeedback: { _ in })
            let controller = ChannelSubscriptionController(platform: "macos", dataStore: store, channelSubscriptionService: service,
                providerRouteController: route, channelSyncController: sync, localizationManager: localization,
                serverConfigProvider: { current.config }, channelMutationRoundTrip: useRemote ? remote : nil)
            return Fixture(original: original, subscription: subscription, credential: credential, current: current, remote: remote, controller: controller, sync: sync)
        }
    }
}
