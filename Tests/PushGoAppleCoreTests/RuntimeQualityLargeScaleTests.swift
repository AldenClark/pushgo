import Foundation
import Dispatch
import GRDB
#if canImport(Darwin)
import Darwin
#endif
import Testing
@testable import PushGoAppleCore

@Suite(.serialized)
struct RuntimeQualityLargeScaleTests {
    @Test
    func localDataStoreRejectsStaleLateDuplicateMessageUpdates() async throws {
        try await withIsolatedLocalDataStore { store, appGroupIdentifier in
            let generator = RuntimeQualityFixtureGenerator(seed: 0x5151, platform: .iOS)
            let pair = generator.makeStaleDuplicatePair()

            try await store.saveMessagesBatch([pair.newer])
            try await store.saveMessagesBatch([pair.stale])

            let stored = try #require(try await store.loadMessage(messageId: pair.newer.messageId ?? ""))
            #expect(stored.title == "Newer stored title")
            #expect(stored.body == "Newer stored body")
            #expect(stored.receivedAt == pair.newer.receivedAt)

            let newerSearch = try await store.searchMessagesCount(query: "Newer stored title")
            let staleSearch = try await store.searchMessagesCount(query: "Stale late title")
            #expect(newerSearch == 1)
            #expect(staleSearch == 0)
        }
    }

    @Test
    func metadataIndexReceivesGeneratedTaskTags() async throws {
        try await withIsolatedLocalDataStore { store, appGroupIdentifier in
            let generator = RuntimeQualityFixtureGenerator(seed: 0x5152, platform: .iOS)
            let dataset = generator.makeDataset(count: 1_000)
            let generatedTask = try #require(dataset.messages.first { $0.tags.contains("task") })
            #expect(generatedTask.tags.contains("task"))

            try await store.saveMessagesBatch(dataset.messages)
            let reloadedTask = try #require(try await store.loadMessage(id: generatedTask.id))
            #expect(reloadedTask.tags.contains("task"))

            let metadataIndex = try MessageMetadataIndex(appGroupIdentifier: appGroupIdentifier)
            let tagCounts = try await metadataIndex.tagCounts()
            let taskCount = tagCounts.first(where: { $0.tag == "task" })?.totalCount ?? 0
            #expect(taskCount == dataset.taskLikeMessageCount)
        }
    }

    @Test
    func tagFilterPageUsesMetadataIndexWithoutMainStoreTableDependency() async throws {
        try await withIsolatedLocalDataStore { store, _ in
            let generator = RuntimeQualityFixtureGenerator(seed: 0x5153, platform: .macOS)
            let dataset = generator.makeDataset(count: 1_000)

            try await store.saveMessagesBatch(dataset.messages)
            let firstPage = try await store.loadMessageSummariesPage(
                before: nil,
                limit: 50,
                filter: .all,
                channel: nil,
                tag: "runtimequality"
            )
            #expect(firstPage.count == 50)
            #expect(firstPage.map(\.id) == dataset.expectedFirstSummaryIDs)

            let cursor = try #require(firstPage.last.map {
                MessagePageCursor(receivedAt: $0.receivedAt, id: $0.id, isRead: $0.isRead)
            })
            let secondPage = try await store.loadMessageSummariesPage(
                before: cursor,
                limit: 50,
                filter: .all,
                channel: nil,
                tag: "runtimequality"
            )
            #expect(secondPage.count == 50)
            #expect(Set(firstPage.map(\.id)).isDisjoint(with: Set(secondPage.map(\.id))))

            let filteredChannel = try #require(firstPage.first?.channel)
            let channelAndTagPage = try await store.loadMessagesPage(
                before: nil,
                limit: 20,
                filter: .all,
                channel: filteredChannel,
                tag: "runtimequality"
            )
            #expect(!channelAndTagPage.isEmpty)
            #expect(channelAndTagPage.allSatisfy { $0.channel == filteredChannel })
            #expect(channelAndTagPage.allSatisfy { $0.tags.contains("runtimequality") })
        }
    }

    @Test
    func malformedOptionalFieldsDoNotPolluteNormalStoreAndProjectionPaths() async throws {
        try await withIsolatedLocalDataStore { store, _ in
            let normalMessage = runtimeQualityTestMessage(
                id: "11111111-1111-1111-1111-111111111111",
                messageID: "runtime-quality-normal-message",
                title: "runtimequality normal message",
                body: "runtimequality normal body",
                rawPayload: [
                    "entity_type": "message",
                    "entity_id": "normal-message",
                    "tags": #"["runtimequality","normal"]"#,
                    "metadata": #"{"kind":"normal"}"#,
                ]
            )
            let normalEvent = runtimeQualityTestMessage(
                id: "22222222-2222-2222-2222-222222222222",
                messageID: "runtime-quality-normal-event",
                title: "runtimequality normal event",
                body: "runtimequality normal event body",
                rawPayload: [
                    "entity_type": "event",
                    "entity_id": "event-normal-001",
                    "event_id": "event-normal-001",
                    "event_time": "1800000100000",
                    "tags": #"["runtimequality","event"]"#,
                    "metadata": #"{"kind":"event"}"#,
                ]
            )
            let normalThing = runtimeQualityTestMessage(
                id: "33333333-3333-3333-3333-333333333333",
                messageID: "runtime-quality-normal-thing",
                title: "runtimequality normal thing",
                body: "runtimequality normal thing body",
                rawPayload: [
                    "entity_type": "thing",
                    "entity_id": "thing-normal-001",
                    "thing_id": "thing-normal-001",
                    "observed_time": "1800000100000",
                    "tags": #"["runtimequality","thing"]"#,
                    "metadata": #"{"kind":"thing"}"#,
                ]
            )
            let malformedEvent = runtimeQualityTestMessage(
                id: "44444444-4444-4444-4444-444444444444",
                messageID: "runtime-quality-malformed-event",
                title: "malformed event without semantic id",
                body: "malformed event body",
                rawPayload: [
                    "entity_type": "event",
                    "entity_id": "   ",
                    "event_id": "",
                    "event_time": "not-a-date",
                    "tags": #"not-json"#,
                    "metadata": #"{"kind":"malformed","bad":{}}"#,
                    "images": #"["not-a-url","http://example.com/not-https.png"]"#,
                ]
            )
            let malformedThing = runtimeQualityTestMessage(
                id: "55555555-5555-5555-5555-555555555555",
                messageID: "runtime-quality-malformed-thing",
                title: "malformed thing without semantic id",
                body: "malformed thing body",
                rawPayload: [
                    "entity_type": "thing",
                    "entity_id": "",
                    "thing_id": "   ",
                    "observed_time": "invalid",
                    "tags": ["runtimequality", "array-is-ignored"],
                    "metadata": ["kind": "array-is-ignored"],
                    "open_url": "file:///tmp/not-allowed",
                ]
            )
            let malformedTopLevel = runtimeQualityTestMessage(
                id: "66666666-6666-6666-6666-666666666666",
                messageID: nil,
                title: "malformed top level",
                body: "bad optional fields do not match runtime search",
                rawPayload: [
                    "entity_type": "unknown",
                    "entity_id": "",
                    "event_id": "",
                    "thing_id": "",
                    "tags": #"["bad optional"]"#,
                    "metadata": #"not-json"#,
                    "open_url": "notaurl",
                ]
            )

            try await store.saveMessagesBatch([
                malformedEvent,
                normalEvent,
                malformedThing,
                normalThing,
                malformedTopLevel,
                normalMessage,
            ])

            let counts = try await store.messageCounts()
            #expect(counts.total == 2)
            #expect(counts.unread == 2)

            let summaries = try await store.loadMessageSummariesPage(
                before: nil,
                limit: 10,
                filter: .all,
                channel: nil,
                tag: nil
            )
            #expect(Set(summaries.map(\.id)) == Set([normalMessage.id, malformedTopLevel.id]))
            #expect(summaries.allSatisfy { $0.id != malformedEvent.id && $0.id != malformedThing.id })

            let eventProjection = try await store.loadEventMessagesForProjection()
            #expect(eventProjection.map(\.id) == [normalEvent.id])
            let thingProjection = try await store.loadThingMessagesForProjection()
            #expect(thingProjection.map(\.id) == [normalThing.id])

            let runtimeSearch = try await store.searchMessagesCount(query: "runtimequality")
            #expect(runtimeSearch == 1)
            let runtimeTagSearch = try await store.searchMessagesCount(query: "tag:runtimequality")
            #expect(runtimeTagSearch == 1)

            let malformedReloaded = try #require(try await store.loadMessage(id: malformedTopLevel.id))
            #expect(malformedReloaded.tags == ["bad optional"])
            #expect(malformedReloaded.metadata.isEmpty)
            #expect(malformedEvent.imageURLs.isEmpty)
        }
    }

    @Test
    func legacyUpgradeTenThousandOpensRebuildsAndServesCanonicalQueries() async throws {
        try await runLegacyUpgradeScenario(
            scale: 10_000,
            metricPrefix: "upgrade10k",
            seed: 0x5154,
            assertThresholds: true
        )
    }

    @Test
    func legacyUpgradeHundredThousandOpensRebuildsAndServesCanonicalQueries() async throws {
        let configuration = RuntimeQualityConfiguration.fromEnvironment()
        guard configuration.enabled else {
            print("[runtime-quality] skipped; run with PUSHGO_RUNTIME_QUALITY=1 swift test --filter legacyUpgradeHundredThousandOpensRebuildsAndServesCanonicalQueries")
            return
        }

        try await runLegacyUpgradeScenario(
            scale: max(100_000, configuration.coreScale),
            metricPrefix: "upgrade100k",
            seed: configuration.seed ^ 0xABCD_1000,
            assertThresholds: true
        )
    }

    @Test
    func largeScaleCoreStorePathsHaveStableCorrectnessAndPerformance() async throws {
        let configuration = RuntimeQualityConfiguration.fromEnvironment()
        guard configuration.enabled else {
            print("[runtime-quality] skipped; run with PUSHGO_RUNTIME_QUALITY=1 swift test --filter RuntimeQualityLargeScaleTests")
            return
        }

        try await withIsolatedLocalDataStore { store, appGroupIdentifier in
            let generator = RuntimeQualityFixtureGenerator(seed: configuration.seed, platform: .iOS)
            let dataset = generator.makeDataset(count: configuration.coreScale)

            let write = try await RuntimeQualityMainThreadProbe.measure("core.mainThread.saveMessagesBatch") {
                try await RuntimeQualityMetric.measure("core.write.saveMessagesBatch", count: dataset.messages.count) {
                    try await store.saveMessagesBatch(dataset.messages)
                }
            }
            #expect(write.value.seconds < configuration.maxCoreWriteSeconds)
            #expect(write.tickCount > 0)
            #expect(write.maxStallSeconds < configuration.maxMainThreadStallSeconds)

            let counts = try await RuntimeQualityMetric.measure("core.read.messageCounts", count: dataset.topLevelMessageCount) {
                try await store.messageCounts()
            }
            #expect(counts.value.total == dataset.topLevelMessageCount)
            #expect(counts.value.unread == dataset.unreadTopLevelMessageCount)
            #expect(counts.seconds < configuration.maxShortReadSeconds)

            let firstPage = try await RuntimeQualityMetric.measure("core.read.firstSummaryPage", count: 50) {
                try await store.loadMessageSummariesPage(
                    before: nil,
                    limit: 50,
                    filter: .all,
                    channel: nil,
                    tag: nil
                )
            }
            #expect(firstPage.value.map(\.id) == dataset.expectedFirstSummaryIDs)
            #expect(firstPage.seconds < configuration.maxShortReadSeconds)

            let paged = try await RuntimeQualityMetric.measure("core.read.paginateSummaries", count: 1_000) {
                try await loadSummaryPages(store: store, pageSize: 100, pageCount: 10)
            }
            #expect(Set(paged.value.map(\.id)).count == paged.value.count)
            #expect(isDescendingByTimeAndID(paged.value))
            #expect(paged.seconds < configuration.maxPaginationSeconds)

            let unreadFirstPage = try await RuntimeQualityMetric.measure("core.read.unreadFirstPage", count: 100) {
                try await store.loadMessageSummariesPage(
                    before: nil,
                    limit: 100,
                    filter: .all,
                    channel: nil,
                    tag: nil,
                    sortMode: .unreadFirst
                )
            }
            #expect(isUnreadFirstThenDescendingByTimeAndID(unreadFirstPage.value))
            #expect(unreadFirstPage.seconds < configuration.maxShortReadSeconds)

            let unreadPage = try await RuntimeQualityMetric.measure("core.read.unreadPage", count: 100) {
                try await store.loadMessageSummariesPage(
                    before: nil,
                    limit: 100,
                    filter: .unreadOnly,
                    channel: nil,
                    tag: nil
                )
            }
            #expect(unreadPage.value.allSatisfy { !$0.isRead })
            #expect(unreadPage.seconds < configuration.maxShortReadSeconds)

            let filteredChannel = try #require(firstPage.value.first?.channel)
            let channelPage = try await RuntimeQualityMetric.measure("core.read.channelFilterPage", count: 100) {
                try await store.loadMessageSummariesPage(
                    before: nil,
                    limit: 100,
                    filter: .all,
                    channel: filteredChannel,
                    tag: nil
                )
            }
            #expect(channelPage.value.allSatisfy { $0.channel == filteredChannel })
            #expect(channelPage.seconds < configuration.maxShortReadSeconds)

            let urlPage = try await RuntimeQualityMetric.measure("core.read.urlPage", count: 100) {
                try await store.loadMessagesPage(
                    before: nil,
                    limit: 100,
                    filter: .withURLOnly,
                    channel: nil,
                    tag: nil
                )
            }
            #expect(urlPage.value.allSatisfy { $0.url != nil })
            #expect(dataset.urlTopLevelMessageCount >= urlPage.value.count)
            #expect(urlPage.seconds < configuration.maxShortReadSeconds)

            let tagFilterPage = try await RuntimeQualityMetric.measure("core.read.tagFilterPage", count: 100) {
                try await store.loadMessagesPage(
                    before: nil,
                    limit: 100,
                    filter: .all,
                    channel: nil,
                    tag: "runtimequality"
                )
            }
            #expect(tagFilterPage.value.count == 100)
            #expect(tagFilterPage.value.allSatisfy { $0.tags.contains("runtimequality") })
            #expect(tagFilterPage.seconds < configuration.maxShortReadSeconds)

            let searchCount = try await RuntimeQualityMetric.measure("core.search.count", count: dataset.runtimeQualitySearchCount) {
                try await store.searchMessagesCount(query: "runtimequality")
            }
            #expect(searchCount.value == dataset.runtimeQualitySearchCount)
            #expect(searchCount.seconds < configuration.maxSearchSeconds)

            let tagCount = try await RuntimeQualityMetric.measure("core.search.tagTaskCount", count: dataset.taskLikeMessageCount) {
                try await store.searchMessagesCount(query: "tag:task")
            }
            #expect(tagCount.value == dataset.taskLikeMessageCount)
            #expect(tagCount.seconds < configuration.maxSearchSeconds)

            let tagSearch = try await RuntimeQualityMetric.measure("core.search.tagTaskPage", count: dataset.taskLikeMessageCount) {
                try await store.searchMessageSummariesPage(
                    query: "tag:task",
                    before: nil,
                    limit: 100
                )
            }
            #expect(tagSearch.value.count == min(100, dataset.taskLikeMessageCount))
            #expect(tagSearch.seconds < configuration.maxSearchSeconds)

            let eventPage = try await RuntimeQualityMetric.measure("core.projection.eventFirstPage", count: dataset.eventProjectionCount) {
                try await store.loadEventMessagesForProjectionPage(before: nil, limit: 100)
            }
            #expect(eventPage.value.count == min(100, dataset.eventProjectionCount))
            #expect(eventPage.seconds < configuration.maxShortReadSeconds)

            let thingPage = try await RuntimeQualityMetric.measure("core.projection.thingFirstPage", count: dataset.thingProjectionCount) {
                try await store.loadThingMessagesForProjectionPage(before: nil, limit: 100)
            }
            #expect(thingPage.value.count == min(100, dataset.thingProjectionCount))
            #expect(thingPage.seconds < configuration.maxShortReadSeconds)

            let markdownMessage = try #require(dataset.messages.first { $0.body.contains("```swift") && isTopLevelMessage($0) })
            let markdownDetail = try await RuntimeQualityMetric.measure("core.detail.longMarkdown", count: markdownMessage.body.utf8.count) {
                try await store.loadMessage(id: markdownMessage.id)
            }
            #expect(markdownDetail.value?.body == markdownMessage.body)
            #expect(markdownDetail.seconds < configuration.maxShortReadSeconds)

            let mediaMessage = try #require(dataset.messages.first { $0.rawPayload.keys.contains("images") && isTopLevelMessage($0) })
            let mediaDetail = try await RuntimeQualityMetric.measure("core.detail.mediaReferences", count: mediaMessage.rawPayload.count) {
                try await store.loadMessage(id: mediaMessage.id)
            }
            #expect(mediaDetail.value?.rawPayload.keys.contains("images") == true)
            #expect(mediaDetail.seconds < configuration.maxShortReadSeconds)

            let eventMessage = try #require(dataset.messages.first { $0.eventId != nil && $0.thingId == nil })
            let eventID = try #require(eventMessage.eventId)
            let eventDetail = try await RuntimeQualityMetric.measure("core.detail.eventTimeline", count: 1) {
                try await store.loadEventMessagesForProjection(eventId: eventID)
            }
            #expect(!eventDetail.value.isEmpty)
            #expect(eventDetail.value.allSatisfy { $0.eventId == eventID })
            #expect(eventDetail.seconds < configuration.maxShortReadSeconds)

            let thingMessage = try #require(dataset.messages.first { $0.thingId != nil })
            let thingID = try #require(thingMessage.thingId)
            let thingDetail = try await RuntimeQualityMetric.measure("core.detail.thingTimeline", count: 1) {
                try await store.loadThingMessagesForProjection(thingId: thingID)
            }
            #expect(!thingDetail.value.isEmpty)
            #expect(thingDetail.value.allSatisfy { $0.thingId == thingID })
            #expect(thingDetail.seconds < configuration.maxShortReadSeconds)

            let markedRead = try await RuntimeQualityMetric.measure("core.update.markFirstPageRead", count: firstPage.value.count) {
                try await store.markMessagesRead(ids: firstPage.value.map(\.id))
            }
            #expect(markedRead.value <= firstPage.value.count)
            #expect(markedRead.seconds < configuration.maxShortWriteSeconds)

            let deleted = try await RuntimeQualityMetric.measure("core.delete.deleteFirstPage", count: firstPage.value.count) {
                try await store.deleteMessages(ids: firstPage.value.map(\.id))
            }
            #expect(deleted.value == firstPage.value.count)
            #expect(deleted.seconds < configuration.maxSmallDeleteSeconds)

            let reloadedStore = LocalDataStore(appGroupIdentifier: appGroupIdentifier)
            let afterDeleteCounts = try await reloadedStore.messageCounts()
            #expect(afterDeleteCounts.total == dataset.topLevelMessageCount - firstPage.value.count)

            if let residentMemoryBytes = RuntimeQualityResourceSnapshot.current().residentMemoryBytes {
                print("[runtime-quality] metric=core.resource.residentMemory count=\(configuration.coreScale) resident_memory_bytes=\(residentMemoryBytes)")
                #expect(residentMemoryBytes < configuration.maxCoreResidentMemoryBytes)
            }
        }
    }

    @Test
    func watchLightStoreHandlesTenThousandItemSnapshot() async throws {
        let configuration = RuntimeQualityConfiguration.fromEnvironment()
        guard configuration.enabled else {
            print("[runtime-quality] skipped; run with PUSHGO_RUNTIME_QUALITY=1 swift test --filter RuntimeQualityLargeScaleTests")
            return
        }

        try await withIsolatedLocalDataStore { store, _ in
            let generator = RuntimeQualityFixtureGenerator(seed: configuration.seed, platform: .watchOS)
            let snapshot = generator.makeWatchSnapshot(
                messageCount: configuration.watchScale,
                eventCount: max(1, configuration.watchScale / 10),
                thingCount: max(1, configuration.watchScale / 10)
            )

            let merge = try await RuntimeQualityMetric.measure("watch.merge.mirrorSnapshot", count: snapshot.messages.count) {
                try await store.mergeWatchMirrorSnapshot(snapshot)
            }
            #expect(merge.seconds < configuration.maxWatchMergeSeconds)

            let messages = try await RuntimeQualityMetric.measure("watch.read.messages", count: snapshot.messages.count) {
                try await store.loadWatchLightMessages()
            }
            #expect(messages.value.count == snapshot.messages.count)
            #expect(messages.seconds < configuration.maxWatchReadSeconds)

            let events = try await RuntimeQualityMetric.measure("watch.read.events", count: snapshot.events.count) {
                try await store.loadWatchLightEvents()
            }
            #expect(events.value.count == snapshot.events.count)
            #expect(events.seconds < configuration.maxWatchReadSeconds)

            let things = try await RuntimeQualityMetric.measure("watch.read.things", count: snapshot.things.count) {
                try await store.loadWatchLightThings()
            }
            #expect(things.value.count == snapshot.things.count)
            #expect(things.seconds < configuration.maxWatchReadSeconds)

            let repeatedReloads = try await RuntimeQualityMetric.measure("watch.read.repeatedReloads", count: snapshot.messages.count * 10) {
                for _ in 0 ..< 10 {
                    let reloadedMessages = try await store.loadWatchLightMessages()
                    let reloadedEvents = try await store.loadWatchLightEvents()
                    let reloadedThings = try await store.loadWatchLightThings()
                    #expect(reloadedMessages.count == snapshot.messages.count)
                    #expect(reloadedEvents.count == snapshot.events.count)
                    #expect(reloadedThings.count == snapshot.things.count)
                }
            }
            #expect(repeatedReloads.seconds < configuration.maxWatchReadSeconds * 10)

            if let residentMemoryBytes = RuntimeQualityResourceSnapshot.current().residentMemoryBytes {
                print("[runtime-quality] metric=watch.resource.residentMemory count=\(configuration.watchScale) resident_memory_bytes=\(residentMemoryBytes)")
                #expect(residentMemoryBytes < configuration.maxWatchResidentMemoryBytes)
            }
        }
    }

    @Test
    func concurrentOutOfOrderBatchesConvergeWithoutDuplicates() async throws {
        let configuration = RuntimeQualityConfiguration.fromEnvironment()
        guard configuration.enabled else {
            print("[runtime-quality] skipped; run with PUSHGO_RUNTIME_QUALITY=1 swift test --filter RuntimeQualityLargeScaleTests")
            return
        }

        try await withIsolatedLocalDataStore { store, _ in
            let batchCount = 8
            let batchSize = max(1, configuration.concurrentScale / batchCount)
            let datasets = (0 ..< batchCount).map { batch in
                let generator = RuntimeQualityFixtureGenerator(
                    seed: (configuration.seed ^ 0xC0FFEE) &+ UInt64(batch),
                    platform: .macOS,
                    scenarios: [.normal, .outOfOrderTimestamp, .duplicateIdentity, .concurrentArrival]
                )
                return generator.makeDataset(count: batchSize).messages.map { message in
                    var mutable = message
                    mutable.messageId = "concurrent-\(batch)-\(message.messageId ?? message.id.uuidString)"
                    return mutable
                }
            }

            let write = try await RuntimeQualityMetric.measure("core.concurrent.writeBatches", count: batchCount * batchSize) {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for dataset in datasets.shuffledDeterministically(seed: configuration.seed) {
                        group.addTask {
                            try await store.saveMessagesBatch(dataset)
                        }
                    }
                    try await group.waitForAll()
                }
            }
            #expect(write.seconds < configuration.maxConcurrentWriteSeconds)

            let counts = try await store.messageCounts()
            var expectedTopLevel = 0
            for dataset in datasets {
                for message in dataset where message.entityType == "message" && message.eventId == nil && message.thingId == nil {
                    expectedTopLevel += 1
                }
            }
            #expect(counts.total == expectedTopLevel)
        }
    }

    private func loadSummaryPages(
        store: LocalDataStore,
        pageSize: Int,
        pageCount: Int
    ) async throws -> [PushMessageSummary] {
        var output: [PushMessageSummary] = []
        var cursor: MessagePageCursor?
        for _ in 0 ..< pageCount {
            let page = try await store.loadMessageSummariesPage(
                before: cursor,
                limit: pageSize,
                filter: .all,
                channel: nil,
                tag: nil
            )
            guard !page.isEmpty else { break }
            output.append(contentsOf: page)
            let last = page[page.count - 1]
            cursor = MessagePageCursor(receivedAt: last.receivedAt, id: last.id, isRead: last.isRead)
        }
        return output
    }

    private func runLegacyUpgradeScenario(
        scale: Int,
        metricPrefix: String,
        seed: UInt64,
        assertThresholds: Bool
    ) async throws {
        let configuration = RuntimeQualityConfiguration.fromEnvironment()
        try await withIsolatedAutomationStorage { root, appGroupIdentifier in
            let generator = RuntimeQualityFixtureGenerator(seed: seed, platform: .iOS)
            let dataset = generator.makeDataset(count: scale)
            let stagingStore = LocalDataStore(appGroupIdentifier: appGroupIdentifier)
            let seedWrite = try await RuntimeQualityMetric.measure("\(metricPrefix).fixture.seedWrite", count: scale) {
                try await stagingStore.saveMessagesBatch(dataset.messages)
            }
            if assertThresholds {
                #expect(seedWrite.seconds < configuration.maxCoreWriteSeconds)
            }
            let stagingIndexURL = try upgradeIndexDatabaseURL(appGroupIdentifier: appGroupIdentifier)
            try removeUpgradeSQLiteArtifacts(at: stagingIndexURL)
            let upgradeAppGroupIdentifier = "group.ethan.pushgo.tests.\(UUID().uuidString.lowercased())"
            try cloneUpgradeAutomationStorageFixture(
                root: root,
                sourceAppGroupIdentifier: appGroupIdentifier,
                destinationAppGroupIdentifier: upgradeAppGroupIdentifier
            )

            let opened = await RuntimeQualityMetric.measure("\(metricPrefix).open.store", count: scale) {
                LocalDataStore(appGroupIdentifier: upgradeAppGroupIdentifier)
            }
            let store = opened.value
            if assertThresholds {
                #expect(opened.seconds < configuration.maxShortReadSeconds)
            }

            let searchDetect = try await RuntimeQualityMetric.measure("\(metricPrefix).detect.searchIndexEmpty", count: scale) {
                let index = try MessageSearchIndex(appGroupIdentifier: upgradeAppGroupIdentifier)
                return try await index.isEmpty()
            }
            #expect(searchDetect.value == true)
            if assertThresholds {
                #expect(searchDetect.seconds < configuration.maxShortReadSeconds)
            }

            let metadataDetect = try await RuntimeQualityMetric.measure("\(metricPrefix).detect.metadataIndexEmpty", count: scale) {
                let index = try MessageMetadataIndex(appGroupIdentifier: upgradeAppGroupIdentifier)
                return try await index.isEmpty()
            }
            #expect(metadataDetect.value == true)
            if assertThresholds {
                #expect(metadataDetect.seconds < configuration.maxShortReadSeconds)
            }

            let firstPage = try await RuntimeQualityMetric.measure("\(metricPrefix).read.firstSummaryPage", count: 50) {
                try await store.loadMessageSummariesPage(
                    before: nil,
                    limit: 50,
                    filter: .all,
                    channel: nil,
                    tag: nil
                )
            }
            #expect(firstPage.value.map(\.id) == dataset.expectedFirstSummaryIDs)
            if assertThresholds {
                #expect(firstPage.seconds < configuration.maxShortReadSeconds)
            }

            let searchCount = try await RuntimeQualityMetric.measure("\(metricPrefix).rebuild.searchCount", count: dataset.runtimeQualitySearchCount) {
                try await store.searchMessagesCount(query: "runtimequality")
            }
            #expect(searchCount.value == dataset.runtimeQualitySearchCount)
            if assertThresholds {
                #expect(searchCount.seconds < configuration.maxSearchSeconds)
            }

            let searchRows = try upgradeSearchIndexRowCount(appGroupIdentifier: upgradeAppGroupIdentifier)
            #expect(searchRows == dataset.topLevelMessageCount)

            let searchPage = try await RuntimeQualityMetric.measure("\(metricPrefix).read.searchPage", count: 100) {
                try await store.searchMessageSummariesPage(
                    query: "runtimequality",
                    before: nil,
                    limit: 100
                )
            }
            #expect(searchPage.value.count == min(100, dataset.runtimeQualitySearchCount))
            #expect(isDescendingByTimeAndID(searchPage.value))
            if assertThresholds {
                #expect(searchPage.seconds < configuration.maxSearchSeconds)
            }

            let tagCounts = try await RuntimeQualityMetric.measure("\(metricPrefix).rebuild.tagCounts", count: dataset.topLevelMessageCount) {
                try await store.messageTagCounts()
            }
            #expect(tagCounts.value.first(where: { $0.tag == "runtimequality" })?.totalCount == dataset.topLevelMessageCount)
            #expect(tagCounts.value.contains(where: { $0.tag == "metadata_tag" }) == false)
            if assertThresholds {
                #expect(tagCounts.seconds < configuration.maxSearchSeconds)
            }

            let runtimeTagRows = try upgradeRealTagRowCount(
                appGroupIdentifier: upgradeAppGroupIdentifier,
                value: "runtimequality"
            )
            #expect(runtimeTagRows == dataset.topLevelMessageCount)

            let tagPage = try await RuntimeQualityMetric.measure("\(metricPrefix).read.tagPage", count: 50) {
                try await store.loadMessageSummariesPage(
                    before: nil,
                    limit: 50,
                    filter: .all,
                    channel: nil,
                    tag: "runtimequality"
                )
            }
            #expect(tagPage.value.map(\.id) == dataset.expectedFirstSummaryIDs)
            if assertThresholds {
                #expect(tagPage.seconds < configuration.maxSearchSeconds)
            }

            let tagSearchPage = try await RuntimeQualityMetric.measure("\(metricPrefix).read.tagSearchPage", count: 50) {
                try await store.searchMessageSummariesPage(
                    query: "tag:runtimequality",
                    before: nil,
                    limit: 50
                )
            }
            #expect(tagSearchPage.value.map(\.id) == dataset.expectedFirstSummaryIDs)
            if assertThresholds {
                #expect(tagSearchPage.seconds < configuration.maxSearchSeconds)
            }

            let eventPage = try await RuntimeQualityMetric.measure("\(metricPrefix).projection.eventFirstPage", count: dataset.eventProjectionCount) {
                try await store.loadEventMessagesForProjectionPage(before: nil, limit: 100)
            }
            #expect(eventPage.value.count == min(100, dataset.eventProjectionCount))
            if assertThresholds {
                #expect(eventPage.seconds < configuration.maxShortReadSeconds)
            }

            let thingPage = try await RuntimeQualityMetric.measure("\(metricPrefix).projection.thingFirstPage", count: dataset.thingProjectionCount) {
                try await store.loadThingMessagesForProjectionPage(before: nil, limit: 100)
            }
            #expect(thingPage.value.count == min(100, dataset.thingProjectionCount))
            if assertThresholds {
                #expect(thingPage.seconds < configuration.maxShortReadSeconds)
            }

            let reloadAppGroupIdentifier = "group.ethan.pushgo.tests.\(UUID().uuidString.lowercased())"
            try cloneUpgradeAutomationStorageFixture(
                root: root,
                sourceAppGroupIdentifier: upgradeAppGroupIdentifier,
                destinationAppGroupIdentifier: reloadAppGroupIdentifier
            )
            let reloadedStore = LocalDataStore(appGroupIdentifier: reloadAppGroupIdentifier)
            let reloadedPage = try await reloadedStore.loadMessageSummariesPage(
                before: nil,
                limit: 50,
                filter: .all,
                channel: nil,
                tag: nil
            )
            #expect(reloadedPage.map(\.id) == dataset.expectedFirstSummaryIDs)
            #expect(try await reloadedStore.searchMessagesCount(query: "runtimequality") == dataset.runtimeQualitySearchCount)
            #expect(try await reloadedStore.searchMessagesCount(query: "tag:runtimequality") == dataset.topLevelMessageCount)

            if let residentMemoryBytes = RuntimeQualityResourceSnapshot.current().residentMemoryBytes {
                print("[runtime-quality] metric=\(metricPrefix).resource.residentMemory count=\(scale) resident_memory_bytes=\(residentMemoryBytes)")
                #expect(residentMemoryBytes < configuration.maxCoreResidentMemoryBytes)
            }
        }
    }

    private func createLegacyUpgradeMainStoreFixture(
        appGroupIdentifier: String,
        messages: [PushMessage]
    ) throws {
        let databaseDirectory = try AppConstants.appLocalDatabaseDirectory(
            fileManager: .default,
            appGroupIdentifier: appGroupIdentifier
        )
        try FileManager.default.createDirectory(
            at: databaseDirectory,
            withIntermediateDirectories: true
        )
        let databaseURL = databaseDirectory.appendingPathComponent(AppConstants.databaseStoreFilename)
        let dbQueue = try DatabaseQueue(path: databaseURL.path)
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS messages (
                    id TEXT PRIMARY KEY NOT NULL,
                    message_id TEXT NOT NULL,
                    title TEXT NOT NULL,
                    body TEXT NOT NULL,
                    channel TEXT,
                    url TEXT,
                    is_read INTEGER NOT NULL,
                    received_at REAL NOT NULL,
                    raw_payload_json TEXT NOT NULL,
                    status TEXT NOT NULL,
                    decryption_state TEXT,
                    notification_request_id TEXT,
                    delivery_id TEXT,
                    operation_id TEXT,
                    entity_type TEXT NOT NULL,
                    entity_id TEXT,
                    event_id TEXT,
                    thing_id TEXT,
                    projection_destination TEXT,
                    event_state TEXT,
                    event_time_epoch INTEGER,
                    observed_time_epoch INTEGER,
                    occurred_at_epoch INTEGER,
                    is_top_level_message INTEGER NOT NULL,
                    CHECK (length(trim(message_id)) > 0)
                );
                """)
            try db.execute(sql: "CREATE UNIQUE INDEX IF NOT EXISTS idx_messages_message_id_unique ON messages(message_id);")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_messages_received_at ON messages(received_at DESC, id DESC);")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_messages_top_level_received_at ON messages(is_top_level_message, received_at DESC, id DESC);")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_messages_notification_request_id ON messages(notification_request_id);")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_messages_channel_received_at ON messages(channel, received_at DESC, id DESC);")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_messages_read_state_received_at ON messages(is_read, received_at DESC, id DESC);")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_messages_entity_projection ON messages(entity_type, event_time_epoch DESC, occurred_at_epoch DESC, received_at DESC, id DESC);")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_messages_event_projection ON messages(event_id, event_time_epoch DESC, received_at DESC, id DESC);")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_messages_thing_projection ON messages(thing_id, occurred_at_epoch DESC, observed_time_epoch DESC, event_time_epoch DESC, received_at DESC, id DESC);")
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS grdb_migrations (
                    identifier TEXT NOT NULL PRIMARY KEY
                );
                """)
            for identifier in [
                "v1_grdb_primary_store",
                "v2_watch_sync_state_columns",
                "v3_watch_provisioning_columns",
                "v4_watch_mode_control_state_columns",
                "v5_watch_mode_control_readiness_column",
                "v6_watch_publication_digest_columns",
                "v7_watch_light_notify_columns",
                "v8_rebuild_snake_case_schema",
                "v9_message_occurred_at_epoch",
                "v10_pending_inbound_messages",
                "v11_projection_epoch_millis",
                "v12_all_epoch_millis",
                "v13_watch_light_decryption_state_columns",
                "v14_provider_delivery_ack_outbox",
                "v15_drop_provider_delivery_ack_outbox",
            ] {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO grdb_migrations(identifier) VALUES (?);",
                    arguments: [identifier]
                )
            }

            for message in messages {
                try db.execute(
                    sql: """
                        INSERT INTO messages (
                            id, message_id, title, body, channel, url, is_read, received_at,
                            raw_payload_json, status, decryption_state, notification_request_id,
                            delivery_id, operation_id, entity_type, entity_id, event_id, thing_id,
                            projection_destination, event_state, event_time_epoch, observed_time_epoch,
                            occurred_at_epoch, is_top_level_message
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                        """,
                    arguments: [
                        message.id.uuidString,
                        message.messageId ?? "",
                        message.title,
                        message.body,
                        message.channel,
                        message.url?.absoluteString,
                        message.isRead ? 1 : 0,
                        message.receivedAt.timeIntervalSince1970,
                        try upgradeRawPayloadJSONString(from: message.rawPayload),
                        message.status.rawValue,
                        message.decryptionState?.rawValue,
                        message.notificationRequestId,
                        message.deliveryId,
                        message.operationId,
                        message.entityType,
                        message.entityId,
                        message.eventId,
                        message.thingId,
                        message.projectionDestination,
                        message.eventState,
                        upgradeEpochMillis(message.rawPayload["event_time"]?.value),
                        upgradeEpochMillis(message.rawPayload["observed_time"]?.value),
                        upgradeEpochMillis(message.rawPayload["occurred_at"]?.value),
                        isTopLevelMessage(message) ? 1 : 0,
                    ]
                )
            }
        }
    }

    private func upgradeRawPayloadJSONString(from rawPayload: [String: AnyCodable]) throws -> String {
        let jsonObject = try upgradeNormalizeJSONObject(rawPayload.mapValues(\.value))
        let data = try JSONSerialization.data(withJSONObject: jsonObject, options: [.sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return json
    }

    private func upgradeNormalizeJSONObject(_ value: Any) throws -> Any {
        switch value {
        case let dictionary as [String: Any]:
            return try dictionary.mapValues { try upgradeNormalizeJSONObject($0) }
        case let array as [Any]:
            return try array.map { try upgradeNormalizeJSONObject($0) }
        case let string as String:
            return string
        case let number as NSNumber:
            return number
        case let bool as Bool:
            return bool
        case let int as Int:
            return int
        case let int64 as Int64:
            return int64
        case let double as Double:
            return double
        case let uuid as UUID:
            return uuid.uuidString
        case Optional<Any>.none:
            return NSNull()
        default:
            throw CocoaError(.coderInvalidValue)
        }
    }

    private func upgradeEpochMillis(_ raw: Any?) -> Int64? {
        switch raw {
        case let text as String:
            return Int64(text.trimmingCharacters(in: .whitespacesAndNewlines))
        case let value as Int64:
            return value
        case let value as Int:
            return Int64(value)
        default:
            return nil
        }
    }

    private func upgradeIndexDatabaseURL(appGroupIdentifier: String) throws -> URL {
        try AppConstants.appLocalDatabaseDirectory(
            fileManager: .default,
            appGroupIdentifier: appGroupIdentifier
        )
        .appendingPathComponent(AppConstants.messageIndexDatabaseFilename)
    }

    private func removeUpgradeSQLiteArtifacts(at fileURL: URL) throws {
        let sidecars = [
            fileURL,
            URL(fileURLWithPath: fileURL.path + "-wal"),
            URL(fileURLWithPath: fileURL.path + "-shm"),
        ]
        for url in sidecars where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func upgradeSearchIndexRowCount(appGroupIdentifier: String) throws -> Int {
        let dbQueue = try DatabaseQueue(path: upgradeIndexDatabaseURL(appGroupIdentifier: appGroupIdentifier).path)
        return try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message_search;") ?? 0
        }
    }

    private func upgradeRealTagRowCount(appGroupIdentifier: String, value: String) throws -> Int {
        let dbQueue = try DatabaseQueue(path: upgradeIndexDatabaseURL(appGroupIdentifier: appGroupIdentifier).path)
        return try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(DISTINCT message_id)
                    FROM message_metadata_index
                    WHERE key_name = 'tag' AND value_norm = ?;
                    """,
                arguments: [value]
            ) ?? 0
        }
    }

    private func cloneUpgradeAutomationStorageFixture(
        root: URL,
        sourceAppGroupIdentifier: String,
        destinationAppGroupIdentifier: String
    ) throws {
        let fileManager = FileManager.default
        let sourceAppLocal = root
            .appendingPathComponent("app-local", isDirectory: true)
            .appendingPathComponent(sourceAppGroupIdentifier, isDirectory: true)
        let destinationAppLocal = root
            .appendingPathComponent("app-local", isDirectory: true)
            .appendingPathComponent(destinationAppGroupIdentifier, isDirectory: true)
        let sourceAppGroup = root
            .appendingPathComponent("app-groups", isDirectory: true)
            .appendingPathComponent(sourceAppGroupIdentifier, isDirectory: true)
        let destinationAppGroup = root
            .appendingPathComponent("app-groups", isDirectory: true)
            .appendingPathComponent(destinationAppGroupIdentifier, isDirectory: true)
        if fileManager.fileExists(atPath: destinationAppLocal.path) {
            try fileManager.removeItem(at: destinationAppLocal)
        }
        if fileManager.fileExists(atPath: destinationAppGroup.path) {
            try fileManager.removeItem(at: destinationAppGroup)
        }
        try fileManager.createDirectory(
            at: destinationAppLocal.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: destinationAppGroup.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.copyItem(at: sourceAppLocal, to: destinationAppLocal)
        if fileManager.fileExists(atPath: sourceAppGroup.path) {
            try fileManager.copyItem(at: sourceAppGroup, to: destinationAppGroup)
        }
    }

    private func isDescendingByTimeAndID(_ summaries: [PushMessageSummary]) -> Bool {
        guard summaries.count > 1 else { return true }
        for index in 1 ..< summaries.count {
            let previous = summaries[index - 1]
            let current = summaries[index]
            if previous.receivedAt < current.receivedAt {
                return false
            }
            if previous.receivedAt == current.receivedAt,
               previous.id.uuidString < current.id.uuidString
            {
                return false
            }
        }
        return true
    }

    private func isUnreadFirstThenDescendingByTimeAndID(_ summaries: [PushMessageSummary]) -> Bool {
        guard summaries.count > 1 else { return true }
        for index in 1 ..< summaries.count {
            let previous = summaries[index - 1]
            let current = summaries[index]
            if previous.isRead != current.isRead {
                if previous.isRead && !current.isRead {
                    return false
                }
                continue
            }
            if previous.receivedAt < current.receivedAt {
                return false
            }
            if previous.receivedAt == current.receivedAt,
               previous.id.uuidString < current.id.uuidString
            {
                return false
            }
        }
        return true
    }

    private func isTopLevelMessage(_ message: PushMessage) -> Bool {
        message.entityType == "message" && message.eventId == nil && message.thingId == nil
    }

    private func runtimeQualityTestMessage(
        id: String,
        messageID: String?,
        title: String,
        body: String,
        rawPayload: [String: Any],
        receivedAt: Date = Date(timeIntervalSince1970: 1_800_000_100)
    ) -> PushMessage {
        PushMessage(
            id: UUID(uuidString: id)!,
            messageId: messageID,
            title: title,
            body: body,
            channel: "runtime-quality-regression",
            url: nil,
            isRead: false,
            receivedAt: receivedAt,
            rawPayload: rawPayload.reduce(into: [String: AnyCodable]()) { result, item in
                result[item.key] = AnyCodable(item.value)
            }
        )
    }
}

private struct RuntimeQualityConfiguration {
    let enabled: Bool
    let seed: UInt64
    let coreScale: Int
    let watchScale: Int
    let concurrentScale: Int
    let maxCoreWriteSeconds: Double
    let maxShortReadSeconds: Double
    let maxShortWriteSeconds: Double
    let maxSmallDeleteSeconds: Double
    let maxPaginationSeconds: Double
    let maxSearchSeconds: Double
    let maxWatchMergeSeconds: Double
    let maxWatchReadSeconds: Double
    let maxConcurrentWriteSeconds: Double
    let maxMainThreadStallSeconds: Double
    let maxCoreResidentMemoryBytes: UInt64
    let maxWatchResidentMemoryBytes: UInt64

    static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> RuntimeQualityConfiguration {
        RuntimeQualityConfiguration(
            enabled: ["1", "true", "yes"].contains(environment["PUSHGO_RUNTIME_QUALITY"]?.lowercased() ?? ""),
            seed: UInt64(environment["PUSHGO_RUNTIME_QUALITY_SEED"] ?? "") ?? 0x5EED_2026,
            coreScale: Int(environment["PUSHGO_RUNTIME_QUALITY_CORE_SCALE"] ?? "") ?? 100_000,
            watchScale: Int(environment["PUSHGO_RUNTIME_QUALITY_WATCH_SCALE"] ?? "") ?? 10_000,
            concurrentScale: Int(environment["PUSHGO_RUNTIME_QUALITY_CONCURRENT_SCALE"] ?? "") ?? 10_000,
            maxCoreWriteSeconds: Double(environment["PUSHGO_RUNTIME_QUALITY_MAX_CORE_WRITE_SECONDS"] ?? "") ?? 120,
            maxShortReadSeconds: Double(environment["PUSHGO_RUNTIME_QUALITY_MAX_SHORT_READ_SECONDS"] ?? "") ?? 5,
            maxShortWriteSeconds: Double(environment["PUSHGO_RUNTIME_QUALITY_MAX_SHORT_WRITE_SECONDS"] ?? "") ?? 10,
            maxSmallDeleteSeconds: Double(environment["PUSHGO_RUNTIME_QUALITY_MAX_SMALL_DELETE_SECONDS"] ?? "") ?? 2,
            maxPaginationSeconds: Double(environment["PUSHGO_RUNTIME_QUALITY_MAX_PAGINATION_SECONDS"] ?? "") ?? 20,
            maxSearchSeconds: Double(environment["PUSHGO_RUNTIME_QUALITY_MAX_SEARCH_SECONDS"] ?? "") ?? 20,
            maxWatchMergeSeconds: Double(environment["PUSHGO_RUNTIME_QUALITY_MAX_WATCH_MERGE_SECONDS"] ?? "") ?? 60,
            maxWatchReadSeconds: Double(environment["PUSHGO_RUNTIME_QUALITY_MAX_WATCH_READ_SECONDS"] ?? "") ?? 5,
            maxConcurrentWriteSeconds: Double(environment["PUSHGO_RUNTIME_QUALITY_MAX_CONCURRENT_WRITE_SECONDS"] ?? "") ?? 60,
            maxMainThreadStallSeconds: Double(environment["PUSHGO_RUNTIME_QUALITY_MAX_MAIN_THREAD_STALL_SECONDS"] ?? "") ?? 2,
            maxCoreResidentMemoryBytes: UInt64(environment["PUSHGO_RUNTIME_QUALITY_MAX_CORE_RSS_BYTES"] ?? "") ?? 1_500_000_000,
            maxWatchResidentMemoryBytes: UInt64(environment["PUSHGO_RUNTIME_QUALITY_MAX_WATCH_RSS_BYTES"] ?? "") ?? 900_000_000
        )
    }
}

private struct RuntimeQualityMetric<Value> {
    let value: Value
    let seconds: Double

    static func measure(
        _ name: String,
        count: Int,
        operation: () async throws -> Value
    ) async rethrows -> RuntimeQualityMetric<Value> {
        let resourcesBefore = RuntimeQualityResourceSnapshot.current()
        let start = ContinuousClock.now
        let value = try await operation()
        let elapsed = start.duration(to: .now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000
        let resourcesAfter = RuntimeQualityResourceSnapshot.current()
        let memoryFields: String
        if let before = resourcesBefore.residentMemoryBytes,
           let after = resourcesAfter.residentMemoryBytes
        {
            let delta = Int64(after) - Int64(before)
            memoryFields = " resident_memory_before_bytes=\(before) resident_memory_after_bytes=\(after) resident_memory_delta_bytes=\(delta)"
        } else {
            memoryFields = ""
        }
        print("[runtime-quality] metric=\(name) count=\(count) elapsed_seconds=\(String(format: "%.6f", seconds))\(memoryFields)")
        return RuntimeQualityMetric(value: value, seconds: seconds)
    }
}

private struct RuntimeQualityResourceSnapshot {
    let residentMemoryBytes: UInt64?

    static func current() -> RuntimeQualityResourceSnapshot {
        RuntimeQualityResourceSnapshot(residentMemoryBytes: currentResidentMemoryBytes())
    }

    private static func currentResidentMemoryBytes() -> UInt64? {
        #if canImport(Darwin)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    rebound,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.resident_size)
        #else
        return nil
        #endif
    }
}

private struct RuntimeQualityMainThreadObservation<Value> {
    let value: Value
    let tickCount: Int
    let maxStallSeconds: Double
}

private final class RuntimeQualityMainThreadProbe: @unchecked Sendable {
    private let intervalNanoseconds: UInt64
    private let lock = NSLock()
    private var running = false
    private var tickCount = 0
    private var maxStallSeconds = 0.0

    init(intervalSeconds: Double = 0.02) {
        intervalNanoseconds = UInt64(intervalSeconds * 1_000_000_000)
    }

    static func measure<Value>(
        _ name: String,
        operation: () async throws -> Value
    ) async rethrows -> RuntimeQualityMainThreadObservation<Value> {
        let probe = RuntimeQualityMainThreadProbe()
        probe.start()
        let value = try await operation()
        await MainActor.run {}
        let observation = probe.stop()
        print("[runtime-quality] metric=\(name) main_thread_ticks=\(observation.tickCount) max_stall_seconds=\(String(format: "%.6f", observation.maxStallSeconds))")
        return RuntimeQualityMainThreadObservation(
            value: value,
            tickCount: observation.tickCount,
            maxStallSeconds: observation.maxStallSeconds
        )
    }

    private func start() {
        lock.lock()
        running = true
        tickCount = 0
        maxStallSeconds = 0
        lock.unlock()
        scheduleNextTick(expectedUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + intervalNanoseconds)
    }

    private func stop() -> (tickCount: Int, maxStallSeconds: Double) {
        lock.lock()
        running = false
        let result = (tickCount, maxStallSeconds)
        lock.unlock()
        return result
    }

    private func scheduleNextTick(expectedUptimeNanoseconds: UInt64) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .nanoseconds(Int(intervalNanoseconds))) { [self] in
            tick(expectedUptimeNanoseconds: expectedUptimeNanoseconds)
        }
    }

    private func tick(expectedUptimeNanoseconds: UInt64) {
        let now = DispatchTime.now().uptimeNanoseconds
        let stallSeconds = now > expectedUptimeNanoseconds
            ? Double(now - expectedUptimeNanoseconds) / 1_000_000_000
            : 0

        lock.lock()
        tickCount += 1
        maxStallSeconds = max(maxStallSeconds, stallSeconds)
        let shouldContinue = running
        lock.unlock()

        if shouldContinue {
            scheduleNextTick(expectedUptimeNanoseconds: now + intervalNanoseconds)
        }
    }
}

private extension Array {
    func shuffledDeterministically(seed: UInt64) -> [Element] {
        guard count > 1 else { return self }
        var result = self
        var state = seed
        for index in stride(from: result.count - 1, through: 1, by: -1) {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            let swapIndex = Int(state % UInt64(index + 1))
            result.swapAt(index, swapIndex)
        }
        return result
    }
}
