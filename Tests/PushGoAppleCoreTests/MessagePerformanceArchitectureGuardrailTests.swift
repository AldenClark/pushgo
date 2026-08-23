import Foundation
import Testing

struct MessagePerformanceArchitectureGuardrailTests {
    @Test
    func summaryProjectionQueryCannotRegressToFullMessageColumns() throws {
        let source = try readSource("Shared/Repositories/LocalDataStore.swift")
        let querySection = try section(
            in: source,
            from: "private func fetchProjectedMessageSummaries(",
            to: "private func loadMessages("
        )

        #expect(querySection.contains("JOIN message_summary_projection"))
        #expect(!querySection.contains("SELECT *"))
        #expect(!querySection.contains("m.body"))
        #expect(!querySection.contains("raw_payload_json"))
    }

    @Test
    func messageListCountsCannotRegressToLoadingFullEntities() throws {
        let source = try readSource("Shared/UI/MessageListViewModel.swift")
        let countSection = try section(
            in: source,
            from: "private func loadCurrentScopeUnreadCount()",
            to: "private func unreadMessageIDsInCurrentScope()"
        )

        #expect(countSection.contains("dataStore.unreadMessageCount"))
        #expect(!countSection.contains("loadMessages"))
        #expect(!countSection.contains("filter {"))
    }

    @Test
    func searchKeepsDisplayedResultsUntilTheCurrentRequestCommits() throws {
        let source = try readSource("Shared/UI/MessageSearchViewModel.swift")
        let queryUpdateSection = try section(
            in: source,
            from: "func updateQuery(",
            to: "func applySearchTextImmediately("
        )
        let firstPageSection = try section(
            in: source,
            from: "private func loadFirstPage(",
            to: "private func loadNextPage("
        )
        let beforeFirstFetch = try section(
            in: String(firstPageSection),
            from: "private func loadFirstPage(",
            to: "let count = try await dataStore.searchMessagesCount"
        )

        #expect(!queryUpdateSection.contains("hasSearched = true"))
        #expect(!beforeFirstFetch.contains("displayedResults = []"))
        #expect(firstPageSection.contains("guard isCurrentSearchRequest"))
        #expect(firstPageSection.contains("displayedQuery = trimmedQuery"))
        #expect(source.contains("searchDebounceDuration: Duration = .milliseconds(250)"))
    }

    @Test
    func notificationExtensionsCannotRegressToAckOrCanonicalDatabaseWork() throws {
        let sharedProcessor = try readSource("Shared/Services/NotificationServiceProcessor.swift")
        let watchProcessor = try readSource(
            "Extensions/PushGoNSE-watchOS/WatchNotificationServiceProcessor.swift"
        )
        let iosService = try readSource("Extensions/PushGoNSE-iOS/NotificationService.swift")
        let macService = try readSource("Extensions/PushGoNSE-macOS/NotificationService.swift")

        for source in [sharedProcessor, watchProcessor, iosService, macService] {
            #expect(!source.contains("LocalDataStore("))
            #expect(!source.contains("GRDB"))
            #expect(!source.contains("ackMessage("))
            #expect(!source.contains("ackMessages("))
        }
        #expect(sharedProcessor.contains("notificationIngressInbox.enqueue"))
        #expect(watchProcessor.contains("notificationIngressInbox.enqueue"))
        #expect(!sharedProcessor.contains("pullMessages("))
        #expect(!watchProcessor.contains("pullMessages("))
        #expect(!sharedProcessor.contains("URLSession"))
        #expect(!watchProcessor.contains("URLSession"))
        #expect(sharedProcessor.contains("PushGoNotificationProjectionUpdater.update("))
        #expect(sharedProcessor.contains("content.badge = NSNumber(value: update.unreadCount)"))
        #expect(sharedProcessor.contains("insertedUnread: enqueueResult.inserted"))

        let projectionUpdater = try readSource(
            "Shared/SystemIntegration/PushGoNotificationProjectionUpdater.swift"
        )
        #expect(projectionUpdater.contains("PushGoSystemSnapshotStore.updateAtomically("))
        #expect(!projectionUpdater.contains("loadMessages("))
        #expect(!projectionUpdater.contains("waitForWidgetReloadRequestDelivery"))

        let sharedHint = try #require(sharedProcessor.range(of: "source: \"nse.wakeup_hint\""))
        let sharedWakeupReturn = try #require(
            sharedProcessor.range(
                of: "return preparedContent",
                range: sharedHint.upperBound..<sharedProcessor.endIndex
            )
        )
        let sharedDirect = try #require(
            sharedProcessor.range(of: "let ingress = NotificationIngressResolution.direct")
        )
        #expect(sharedHint.lowerBound < sharedDirect.lowerBound)
        #expect(sharedWakeupReturn.lowerBound < sharedDirect.lowerBound)

        let watchHint = try #require(watchProcessor.range(of: "source: \"watch_nse.wakeup_hint\""))
        let watchWakeupReturn = try #require(
            watchProcessor.range(
                of: "return await contentPreparer.prepare(content, includeMediaAttachments: false)",
                range: watchHint.upperBound..<watchProcessor.endIndex
            )
        )
        let watchDirect = try #require(
            watchProcessor.range(of: "let ingress = WatchNotificationIngressResolution.direct")
        )
        #expect(watchHint.lowerBound < watchDirect.lowerBound)
        #expect(watchWakeupReturn.lowerBound < watchDirect.lowerBound)
    }

    @Test
    func normalIngressPathsCannotWriteLegacyQueueFiles() throws {
        let inbox = try readSource("Shared/Services/NotificationIngressInbox.swift")
        let ackAndClaim = try readSource(
            "Shared/Services/ProviderDeliveryAckFailureStore.swift"
        )

        #expect(!inbox.contains(".inboxbin"))
        #expect(!inbox.contains("data.write(to:"))
        #expect(!ackAndClaim.contains("data.write(to:"))
        #expect(!ackAndClaim.contains("replaceItemAt("))
    }

    @Test
    func canonicalNotificationCommitCannotAwaitDerivedProjectionWork() throws {
        let source = try readSource("Shared/Repositories/LocalDataStore.swift")
        let commitSection = try section(
            in: source,
            from: "func persistNotificationMessageIfNeeded(",
            to: "func messageStoreRevisionValues()"
        )

        #expect(commitSection.contains("scheduleDerivedWorkDrain()"))
        #expect(!commitSection.contains("await updateSearchIndex"))
        #expect(!commitSection.contains("await indexSystemSearchMessages"))
        #expect(!commitSection.contains("await PushGoLiveActivityCoordinator"))
    }

    @Test
    func healthyStoreInitializationCannotCopyTheCanonicalDatabase() throws {
        let source = try readSource("Shared/Repositories/LocalDataStore.swift")
        let probeSection = try section(
            in: source,
            from: "private static func writeStorageProbe(",
            to: "private var storeUnavailableError"
        )

        #expect(probeSection.contains("storageState.mode == .unavailable"))
        #expect(probeSection.contains("copySQLiteArtifactsForDiagnostics"))
    }

    @Test
    func iosBootstrapPresentsRecoveredCacheBeforeInboxAndNetworkReconciliation() throws {
        let source = try readSource("Apps/PushGo-iOS/App/AppEnvironment.swift")
        let bootstrapSection = try section(
            in: source,
            from: "private func performBootstrap() async",
            to: "private func startMessageStoreObservationIfNeeded()"
        )
        let ready = try #require(bootstrapSection.range(of: "isDeletionRecoveryReady = true"))
        let inbox = try #require(bootstrapSection.range(of: "mergeNotificationIngressInbox("))

        #expect(ready.lowerBound < inbox.lowerBound)
        #expect(source.contains("refreshChannelSubscriptions(syncWatch: false, syncProviderRoute: false)"))
    }

    @Test
    func iosInitialRefreshLoadsOnlyTheSelectedTab() throws {
        let source = try readSource("Apps/PushGo-iOS/UI/Screens/MainTabContainerView.swift")
        let refreshSection = try section(
            in: source,
            from: "private func refreshData(for tab: MainTab) async",
            to: "private func scheduleDataRefreshForStoreChange()"
        )

        #expect(refreshSection.contains("switch tab"))
        #expect(refreshSection.contains("entityViewModel.reloadEvents()"))
        #expect(refreshSection.contains("entityViewModel.reloadThings()"))
        #expect(!refreshSection.contains("entityViewModel.reload()"))
        #expect(source.contains(".task(id: isInitialSelectionResolved ? selection : nil)"))
    }

    @Test
    func pendingChannelRemovalKeepsRemoteCompensationOnLocalCommitFailure() throws {
        let source = try readSource("Shared/Application/ChannelSubscriptionController.swift")
        let pendingSection = try section(
            in: source,
            from: "private func finishPendingChannelRemoval(",
            to: "private func subscribeChannel("
        )
        let compensatedSection = try section(
            in: source,
            from: "func unsubscribeChannelAndDeleteLocalHistory(",
            to: "func commitPendingChannelRemoval("
        )

        #expect(pendingSection.contains("unsubscribeChannelAndDeleteLocalHistory("))
        #expect(compensatedSection.contains("subscribeWithDeviceKeyRecovery("))
        #expect(compensatedSection.contains("throw localError"))
    }

    private func readSource(_ relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func section(in source: String, from start: String, to end: String) throws -> Substring {
        let startRange = try #require(source.range(of: start))
        let endRange = try #require(source.range(of: end, range: startRange.upperBound..<source.endIndex))
        return source[startRange.lowerBound..<endRange.lowerBound]
    }
}
