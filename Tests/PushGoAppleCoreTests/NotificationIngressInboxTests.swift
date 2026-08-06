import Foundation
import Testing
@testable import PushGoAppleCore

private func testDeliveryIdentity(
    deliveryId: String,
    baseURL: String = "https://sandbox.pushgo.dev",
    deviceKey: String = "provider-device-key",
    ackContract: ProviderDeliveryAckFailureStore.AckContract = .v2Batch
) -> ProviderDeliveryAckFailureStore.DeliveryIdentity {
    ProviderDeliveryAckFailureStore.DeliveryIdentity(
        deliveryId: deliveryId,
        baseURL: URL(string: baseURL)!,
        deviceKey: deviceKey,
        ackContract: ackContract
    )!
}

struct NotificationIngressInboxTests {
    @Test
    func notificationIngressInboxPersistsBinaryCodableEntries() async throws {
        try await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let inbox = NotificationIngressInbox(appGroupIdentifier: appGroupIdentifier)
            let payload: [AnyHashable: Any] = [
                "message_id": "inbox-msg-001",
                "delivery_id": "inbox-delivery-001",
                "entity_type": "message",
                "title": "Inbox Title",
                "body": "Inbox Body",
                "metadata": [
                    "source": "nse",
                    "attempt": 1,
                ],
            ]

            #expect(
                await inbox.enqueue(
                    payload: payload,
                    requestIdentifier: "req-inbox-001",
                    source: "nse"
                )
            )

            let pending = await inbox.pendingEntries()
            #expect(pending.count == 1)
            guard let first = pending.first else { return }
            #expect(first.record.source == "nse")
            #expect(first.record.requestIdentifier == "req-inbox-001")
            #expect(first.payload["message_id"] as? String == "inbox-msg-001")
            #expect(first.payload["delivery_id"] as? String == "inbox-delivery-001")

            let rawData = try Data(contentsOf: first.fileURL)
            #expect(rawData.starts(with: Data("bplist00".utf8)))

            await inbox.markCompleted(first)
            #expect(await inbox.pendingEntries().isEmpty)
        }
    }

    @Test
    func notificationIngressInboxUsesAtomicRenameWithoutLeavingTmpFiles() async throws {
        await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let inbox = NotificationIngressInbox(appGroupIdentifier: appGroupIdentifier)
            let payload: [AnyHashable: Any] = [
                "message_id": "inbox-msg-atomic-001",
                "entity_type": "message",
            ]
            #expect(
                await inbox.enqueue(
                    payload: payload,
                    requestIdentifier: nil,
                    source: "nse"
                )
            )

            guard let appGroupURL = AppConstants.appGroupContainerURL(identifier: appGroupIdentifier) else {
                Issue.record("Missing app-group URL for automation storage.")
                return
            }
            let inboxDirectory = appGroupURL
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("notification-ingress-inbox", isDirectory: true)
            let files = (try? FileManager.default.contentsOfDirectory(
                at: inboxDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []

            #expect(files.allSatisfy { $0.pathExtension == "inboxbin" })
        }
    }

    @Test
    func notificationIngressInboxDropsUnreadableCorruptedFilesDuringScan() async throws {
        try await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let inbox = NotificationIngressInbox(appGroupIdentifier: appGroupIdentifier)

            guard let appGroupURL = AppConstants.appGroupContainerURL(identifier: appGroupIdentifier) else {
                Issue.record("Missing app-group URL for automation storage.")
                return
            }
            let inboxDirectory = appGroupURL
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("notification-ingress-inbox", isDirectory: true)
            try FileManager.default.createDirectory(at: inboxDirectory, withIntermediateDirectories: true)

            let corruptedFileURL = inboxDirectory.appendingPathComponent("999999-bad.inboxbin", isDirectory: false)
            try Data([0x01, 0x02, 0x03, 0x04]).write(to: corruptedFileURL, options: .atomic)

            let pending = await inbox.pendingEntries()

            #expect(pending.isEmpty)
            #expect(FileManager.default.fileExists(atPath: corruptedFileURL.path) == false)
        }
    }

    @Test
    func providerDeliveryAckFailureStorePersistsPendingOrFailedMarkersByFullIdentity() async throws {
        try await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let store = ProviderDeliveryAckFailureStore(appGroupIdentifier: appGroupIdentifier)
            let identity = testDeliveryIdentity(deliveryId: "delivery-ack-failure-001")

            #expect(
                await store.markPreparing(
                    identity: identity,
                    source: "nse_preparing"
                )
            )
            #expect(await store.pendingMarkers().isEmpty)

            #expect(
                await store.markInboxDurable(
                    identity: identity,
                    source: "nse_inbox_durable"
                )
            )

            var pending = await store.pendingMarkers()
            #expect(pending.count == 1)
            #expect(pending.first?.record.deliveryId == "delivery-ack-failure-001")
            #expect(pending.first?.record.stage == .inboxDurable)
            #expect(pending.first?.record.source == "nse_inbox_durable")
            #expect(pending.first?.baseURL?.absoluteString == "https://sandbox.pushgo.dev")
            #expect(pending.first?.identity == identity)

            let first = try #require(pending.first)
            let rawData = try Data(contentsOf: first.fileURL)
            #expect(rawData.starts(with: Data("bplist00".utf8)))

            let lease = await store.acquireAckLease(
                first,
                owner: "app.ios",
                leaseDuration: 30
            )
            #expect(lease?.record.stage == .ackInFlight)
            #expect(await store.pendingMarkers().isEmpty)

            if let lease {
                await store.markAckFailed(
                    lease,
                    source: "app.failed",
                    retryAfter: Date(timeIntervalSinceNow: -1),
                    postNotification: false
                )
            }
            pending = await store.pendingMarkers()
            #expect(pending.count == 1)
            #expect(pending.first?.record.stage == .inboxDurable)

            await store.markCompleted(identity: identity)
            pending = await store.pendingMarkers()
            #expect(pending.isEmpty)
        }
    }

    @Test
    func providerDeliveryAckFailureStoreHidesFreshInboxDurableMarkersFromAppDrain() async throws {
        await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let store = ProviderDeliveryAckFailureStore(appGroupIdentifier: appGroupIdentifier)
            let identity = testDeliveryIdentity(deliveryId: "delivery-young-marker-001")
            let now = Date()

            #expect(
                await store.markInboxDurable(
                    identity: identity,
                    source: "nse_inbox_durable",
                    postNotification: false
                )
            )

            #expect(await store.pendingMarkers(minimumAge: 120, now: now).isEmpty)
            #expect(await store.pendingMarkers(minimumAge: 120, now: now.addingTimeInterval(121)).count == 1)
        }
    }

    @Test
    func providerDeliveryAckFailureStoreDoesNotRecreateRecentlyCompletedMarkers() async throws {
        try await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let store = ProviderDeliveryAckFailureStore(appGroupIdentifier: appGroupIdentifier)
            let identity = testDeliveryIdentity(deliveryId: "delivery-completed-marker-001")

            #expect(
                await store.markInboxDurable(
                    identity: identity,
                    source: "nse_inbox_durable",
                    postNotification: false
                )
            )

            let marker = try #require(await store.pendingMarkers().first)
            await store.markCompleted(marker)

            guard let appGroupURL = AppConstants.appGroupContainerURL(identifier: appGroupIdentifier) else {
                Issue.record("Missing app-group URL for automation storage.")
                return
            }
            let ackDirectory = appGroupURL
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("provider-delivery-ack-failures", isDirectory: true)
            let files = (try? FileManager.default.contentsOfDirectory(
                at: ackDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            let ackbinFiles = files.filter { $0.pathExtension == "ackbin" }
            let ackdoneFiles = files.filter { $0.pathExtension == "ackdone" }
            #expect(ackbinFiles.count == 1)
            #expect(ackdoneFiles.isEmpty)

            let completedFile = try #require(ackbinFiles.first)
            let completedData = try Data(contentsOf: completedFile)
            let completedMarker = try PropertyListDecoder().decode(
                ProviderDeliveryAckFailureStore.StoredMarker.self,
                from: completedData
            )
            #expect(completedMarker.stage == .completed)

            #expect(
                await store.markInboxDurable(
                    identity: identity,
                    source: "second_nse_inbox_durable",
                    postNotification: false
                ) == false
            )
            #expect(await store.pendingMarkers().isEmpty)
        }
    }

    @Test
    func providerDeliveryAckFailureStoreKeepsActiveLeaseFromBeingOverwritten() async throws {
        try await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let store = ProviderDeliveryAckFailureStore(appGroupIdentifier: appGroupIdentifier)
            let identity = testDeliveryIdentity(deliveryId: "delivery-active-lease-001")

            #expect(
                await store.markInboxDurable(
                    identity: identity,
                    source: "nse_inbox_durable",
                    postNotification: false
                )
            )
            let marker = try #require(await store.pendingMarkers().first)
            let lease = await store.acquireAckLease(
                marker,
                owner: "nse",
                leaseDuration: 120
            )
            #expect(lease != nil)

            #expect(
                await store.markInboxDurable(
                    identity: identity,
                    source: "second_nse_inbox_durable",
                    postNotification: false
                ) == false
            )
            #expect(await store.pendingMarkers().isEmpty)
        }
    }

    @Test
    func providerDeliveryAckFailureStoreIsolatesSameDeliveryAcrossGatewaysAndDevices() async throws {
        await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let store = ProviderDeliveryAckFailureStore(appGroupIdentifier: appGroupIdentifier)
            let identityA = testDeliveryIdentity(
                deliveryId: "shared-delivery-id",
                baseURL: "https://gateway.example/GatewayA",
                deviceKey: "device-a",
                ackContract: .legacySingle
            )
            let identityB = testDeliveryIdentity(
                deliveryId: "shared-delivery-id",
                baseURL: "https://gateway.example/GatewayB",
                deviceKey: "device-b",
                ackContract: .legacySingle
            )

            #expect(await store.markInboxDurable(
                identity: identityA,
                source: "gateway-a",
                postNotification: false
            ))
            #expect(await store.markInboxDurable(
                identity: identityB,
                source: "gateway-b",
                postNotification: false
            ))
            #expect(await store.pendingMarkers().count == 2)

            await store.markCompleted(identity: identityA)
            let remaining = await store.pendingMarkers()
            #expect(remaining.count == 1)
            #expect(remaining.first?.identity == identityB)
        }
    }

    @Test
    func providerDeliveryAckFailureStoreDeletesUnattributedV2Marker() async throws {
        try await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let store = ProviderDeliveryAckFailureStore(appGroupIdentifier: appGroupIdentifier)
            let appGroupURL = try #require(AppConstants.appGroupContainerURL(identifier: appGroupIdentifier))
            let directory = appGroupURL
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("provider-delivery-ack-failures", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent("legacy-delivery.ackbin")
            let now = Int64(Date().timeIntervalSince1970 * 1_000)
            let legacy = ProviderDeliveryAckFailureStore.StoredMarker(
                schemaVersion: 2,
                deliveryId: "legacy-delivery",
                baseURLString: "https://gateway.example/GatewayA",
                deviceKey: nil,
                ackContract: nil,
                attemptCount: nil,
                stage: .inboxDurable,
                owner: nil,
                leaseUntilEpochMs: nil,
                retryAfterEpochMs: nil,
                createdAtEpochMs: now,
                updatedAtEpochMs: now,
                source: "legacy-v2"
            )
            try PropertyListEncoder().encode(legacy).write(to: fileURL)

            #expect(await store.pendingMarkers().isEmpty)
            #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        }
    }

    @Test
    func providerWakeupPullClaimStoreAllowsOnlyOneActiveClaimPerIdentity() async throws {
        await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let store = ProviderWakeupPullClaimStore(appGroupIdentifier: appGroupIdentifier)
            let identity = testDeliveryIdentity(deliveryId: "delivery-pull-claim-001")
            let otherGatewayIdentity = testDeliveryIdentity(
                deliveryId: "delivery-pull-claim-001",
                baseURL: "https://other.pushgo.dev",
                deviceKey: "other-device"
            )
            let firstLease = await store.acquireLease(
                identity: identity,
                owner: "nse.macos",
                leaseDuration: 30
            )
            #expect(firstLease?.record.deliveryId == "delivery-pull-claim-001")

            let secondLease = await store.acquireLease(
                identity: identity,
                owner: "app.macos",
                leaseDuration: 30
            )
            #expect(secondLease == nil)
            #expect(await store.acquireLease(
                identity: otherGatewayIdentity,
                owner: "app.other-gateway",
                leaseDuration: 30
            ) != nil)

            if let firstLease {
                await store.markCompleted(firstLease)
            }

            let completedLease = await store.acquireLease(
                identity: identity,
                owner: "app.retry",
                leaseDuration: 30
            )
            #expect(completedLease == nil)
        }
    }

    @Test
    func providerWakeupPullClaimStorePurgesLegacyDeliveryOnlyClaim() async throws {
        try await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let store = ProviderWakeupPullClaimStore(appGroupIdentifier: appGroupIdentifier)
            let appGroupURL = try #require(AppConstants.appGroupContainerURL(identifier: appGroupIdentifier))
            let directory = appGroupURL
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("provider-wakeup-pull-claims", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let legacyFileURL = directory.appendingPathComponent("legacy-delivery.pullclaim")
            let now = Int64(Date().timeIntervalSince1970 * 1_000)
            let legacy = ProviderWakeupPullClaimStore.StoredClaim(
                schemaVersion: 1,
                deliveryId: "legacy-delivery",
                baseURLString: nil,
                deviceKey: nil,
                ackContract: nil,
                state: .claimed,
                owner: "legacy",
                leaseUntilEpochMs: now + 30_000,
                createdAtEpochMs: now,
                updatedAtEpochMs: now
            )
            try PropertyListEncoder().encode(legacy).write(to: legacyFileURL)

            let identity = testDeliveryIdentity(deliveryId: "new-delivery")
            #expect(await store.acquireLease(
                identity: identity,
                owner: "new-owner",
                leaseDuration: 30
            ) != nil)
            #expect(!FileManager.default.fileExists(atPath: legacyFileURL.path))
        }
    }

    @Test
    func providerWakeupPullClaimStoreAllowsRetryAfterReleaseOrLeaseExpiry() async throws {
        try await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let store = ProviderWakeupPullClaimStore(appGroupIdentifier: appGroupIdentifier)
            let retryIdentity = testDeliveryIdentity(deliveryId: "delivery-pull-claim-retry-001")

            let firstLease = try #require(
                await store.acquireLease(
                    identity: retryIdentity,
                    owner: "nse.macos",
                    leaseDuration: 30
                )
            )

            await store.releaseLease(firstLease)
            let retryLease = await store.acquireLease(
                identity: retryIdentity,
                owner: "app.macos",
                leaseDuration: 30
            )
            #expect(retryLease != nil)

            let expiredStore = ProviderWakeupPullClaimStore(appGroupIdentifier: appGroupIdentifier)
            let expiryIdentity = testDeliveryIdentity(deliveryId: "delivery-pull-claim-expiry-001")
            let leaseAtNow = try #require(
                await expiredStore.acquireLease(
                    identity: expiryIdentity,
                    owner: "nse.expiry",
                    leaseDuration: 5,
                    now: Date(timeIntervalSince1970: 1_000)
                )
            )
            #expect(leaseAtNow.record.state == .claimed)

            let takeoverLease = await expiredStore.acquireLease(
                identity: expiryIdentity,
                owner: "app.expiry",
                leaseDuration: 5,
                now: Date(timeIntervalSince1970: 1_007)
            )
            #expect(takeoverLease != nil)
        }
    }

    @Test
    func expiredPullOwnerCannotCompletePeerTakeoverAfterCrash() async throws {
        try await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let store = ProviderWakeupPullClaimStore(appGroupIdentifier: appGroupIdentifier)
            let identity = testDeliveryIdentity(deliveryId: "delivery-pull-crash-001")
            let crashedLease = try #require(
                await store.acquireLease(
                    identity: identity,
                    owner: "nse.crashed",
                    leaseDuration: 5,
                    now: Date(timeIntervalSince1970: 1_000)
                )
            )
            let peerLease = try #require(
                await store.acquireLease(
                    identity: identity,
                    owner: "app.peer",
                    leaseDuration: 30,
                    now: Date(timeIntervalSince1970: 1_007)
                )
            )

            await store.markCompleted(crashedLease, now: Date(timeIntervalSince1970: 1_008))
            await store.releaseLease(peerLease, now: Date(timeIntervalSince1970: 1_009))

            let retryAfterPeerFailure = await store.acquireLease(
                identity: identity,
                owner: "app.retry",
                leaseDuration: 30,
                now: Date(timeIntervalSince1970: 1_010)
            )
            #expect(retryAfterPeerFailure != nil)
        }
    }

    @Test
    func providerWakeupPullClaimStoreWaitsForPeerCompletionBeforeGivingUp() async throws {
        try await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let store = ProviderWakeupPullClaimStore(appGroupIdentifier: appGroupIdentifier)
            let identity = testDeliveryIdentity(deliveryId: "delivery-pull-claim-peer-001")
            let lease = try #require(
                await store.acquireLease(
                    identity: identity,
                    owner: "app.peer",
                    leaseDuration: 30
                )
            )

            async let observedCompletion = store.waitForPeerCompletion(
                identity: identity,
                timeout: 1.0,
                pollInterval: 0.02
            )
            try await Task.sleep(nanoseconds: 100_000_000)
            await store.markCompleted(lease)

            #expect(await observedCompletion == true)
        }
    }

    @Test
    func notificationIngressInboxCoalescesProviderDeliveryEntries() async throws {
        await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let inbox = NotificationIngressInbox(appGroupIdentifier: appGroupIdentifier)

            #expect(await inbox.enqueue(
                payload: [
                    "delivery_id": "delivery-idempotent-001",
                    "message_id": "message-before",
                    "title": "Before",
                ],
                requestIdentifier: "delivery-idempotent-001",
                source: "nse"
            ))
            #expect(await inbox.enqueue(
                payload: [
                    "delivery_id": "delivery-idempotent-001",
                    "message_id": "message-after",
                    "title": "After",
                ],
                requestIdentifier: "delivery-idempotent-001",
                source: "nse"
            ))

            let pending = await inbox.pendingEntries()
            #expect(pending.count == 1)
            #expect(pending.first?.payload["message_id"] as? String == "message-after")
        }
    }
}
