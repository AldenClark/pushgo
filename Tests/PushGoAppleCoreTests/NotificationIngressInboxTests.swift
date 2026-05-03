import Foundation
import Testing
@testable import PushGoAppleCore

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
    func providerDeliveryAckFailureStorePersistsPendingOrFailedMarkersByDeliveryId() async throws {
        try await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let store = ProviderDeliveryAckFailureStore(appGroupIdentifier: appGroupIdentifier)
            let baseURL = try #require(URL(string: "https://sandbox.pushgo.dev"))

            #expect(
                await store.markPreparing(
                    deliveryId: " delivery-ack-failure-001 ",
                    baseURL: baseURL,
                    deviceKeyAccount: "provider.device_key.ios",
                    source: "nse_preparing"
                )
            )
            #expect(await store.pendingMarkers().isEmpty)

            #expect(
                await store.markInboxDurable(
                    deliveryId: "delivery-ack-failure-001",
                    baseURL: baseURL,
                    deviceKeyAccount: "provider.device_key.ios",
                    source: "nse_inbox_durable"
                )
            )

            var pending = await store.pendingMarkers()
            #expect(pending.count == 1)
            #expect(pending.first?.record.deliveryId == "delivery-ack-failure-001")
            #expect(pending.first?.record.stage == .inboxDurable)
            #expect(pending.first?.record.source == "nse_inbox_durable")
            #expect(pending.first?.baseURL?.absoluteString == "https://sandbox.pushgo.dev")

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

            await store.markCompleted(deliveryId: "delivery-ack-failure-001")
            pending = await store.pendingMarkers()
            #expect(pending.isEmpty)
        }
    }

    @Test
    func providerDeliveryAckFailureStoreHidesFreshInboxDurableMarkersFromAppDrain() async throws {
        try await withIsolatedAutomationStorage { _, appGroupIdentifier in
            let store = ProviderDeliveryAckFailureStore(appGroupIdentifier: appGroupIdentifier)
            let baseURL = try #require(URL(string: "https://sandbox.pushgo.dev"))
            let now = Date()

            #expect(
                await store.markInboxDurable(
                    deliveryId: "delivery-young-marker-001",
                    baseURL: baseURL,
                    deviceKeyAccount: "provider.device_key.macos",
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
            let baseURL = try #require(URL(string: "https://sandbox.pushgo.dev"))

            #expect(
                await store.markInboxDurable(
                    deliveryId: "delivery-completed-marker-001",
                    baseURL: baseURL,
                    deviceKeyAccount: "provider.device_key.macos",
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
                    deliveryId: "delivery-completed-marker-001",
                    baseURL: baseURL,
                    deviceKeyAccount: "provider.device_key.macos",
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
            let baseURL = try #require(URL(string: "https://sandbox.pushgo.dev"))

            #expect(
                await store.markInboxDurable(
                    deliveryId: "delivery-active-lease-001",
                    baseURL: baseURL,
                    deviceKeyAccount: "provider.device_key.macos",
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
                    deliveryId: "delivery-active-lease-001",
                    baseURL: baseURL,
                    deviceKeyAccount: "provider.device_key.macos",
                    source: "second_nse_inbox_durable",
                    postNotification: false
                ) == false
            )
            #expect(await store.pendingMarkers().isEmpty)
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
