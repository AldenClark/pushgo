#if DEBUG
import Foundation
import ImageIO
import SQLite3

enum WatchQualityRuntime {
    private static let profileEnvironmentKey = "PUSHGO_QUALITY_PROFILE"
    private static let scenarioEnvironmentKey = "PUSHGO_QUALITY_SCENARIO"
    private static let sessionEnvironmentKey = "PUSHGO_QUALITY_SESSION_ID"
    private static let preparedSessionDefaultsKey = "io.ethan.pushgo.watch.quality.prepared-session"
    private static let standardImageURL = URL(
        string: "https://quality-media.pushgo.dev/watch-standard.png"
    )!
    private static let standardImagePNGBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4nGPQqLgDRAwQCgAmzgXxe7wbGAAAAABJRU5ErkJggg=="

    static var isHermeticRequested: Bool {
        normalizedEnvironmentValue(profileEnvironmentKey) == "hermetic"
    }

    static func prepareLegacyStoreIfRequested(
        fileManager: FileManager,
        appGroupIdentifier: String
    ) throws {
        guard isHermeticRequested,
              normalizedEnvironmentValue(scenarioEnvironmentKey) == "watch.migration",
              let sessionID = normalizedEnvironmentValue(sessionEnvironmentKey)
        else { return }

        let defaults = UserDefaults.standard
        guard defaults.string(forKey: preparedSessionDefaultsKey) != sessionID else { return }

        let directory = try AppConstants.appLocalDatabaseDirectory(
            fileManager: fileManager,
            appGroupIdentifier: appGroupIdentifier
        )
        let storeURL = directory.appendingPathComponent(AppConstants.databaseStoreFilename)
        for suffix in ["", "-wal", "-shm"] {
            let member = URL(fileURLWithPath: storeURL.path + suffix)
            if fileManager.fileExists(atPath: member.path) {
                try fileManager.removeItem(at: member)
            }
        }

        var db: OpaquePointer?
        let openResult = sqlite3_open_v2(
            storeURL.path,
            &db,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw WatchQualityRuntimeError.legacyStorePreparationFailed("open code \(openResult)")
        }
        defer { sqlite3_close(db) }

        try executeLegacySQL(
            """
            CREATE TABLE watch_light_messages (
                message_id TEXT PRIMARY KEY NOT NULL,
                title TEXT NOT NULL,
                body TEXT NOT NULL,
                image_url TEXT,
                url TEXT,
                severity TEXT,
                received_at REAL NOT NULL,
                is_read INTEGER NOT NULL,
                entity_type TEXT NOT NULL,
                entity_id TEXT,
                notification_request_id TEXT
            );
            INSERT INTO watch_light_messages (
                message_id, title, body, severity, received_at, is_read, entity_type
            ) VALUES (
                'quality-watch-legacy-message',
                'Legacy watch alert',
                'Persisted before the upgrade.',
                'normal',
                1788000120,
                1,
                'message'
            );

            CREATE TABLE watch_light_events (
                event_id TEXT PRIMARY KEY NOT NULL,
                title TEXT NOT NULL,
                summary TEXT,
                state TEXT,
                severity TEXT,
                image_url TEXT,
                updated_at REAL NOT NULL
            );
            INSERT INTO watch_light_events (
                event_id, title, summary, state, severity, updated_at
            ) VALUES (
                'quality-watch-legacy-event',
                'Legacy payments incident',
                'Legacy checkout errors remain visible.',
                'RESOLVED',
                'high',
                1788000120
            );

            CREATE TABLE watch_light_things (
                thing_id TEXT PRIMARY KEY NOT NULL,
                title TEXT NOT NULL,
                summary TEXT,
                attrs_json TEXT,
                image_url TEXT,
                updated_at REAL NOT NULL
            );
            INSERT INTO watch_light_things (
                thing_id, title, summary, attrs_json, updated_at
            ) VALUES (
                'quality-watch-legacy-thing',
                'Legacy checkout API',
                'Legacy region remains available.',
                '{"region":"legacy-eu","version":"17"}',
                1788000120
            );

            CREATE TABLE watch_mirror_action_queue (action_id TEXT PRIMARY KEY, kind TEXT, message_id TEXT, issued_at REAL);
            INSERT INTO watch_mirror_action_queue VALUES ('legacy-delete', 'delete', 'quality-watch-legacy-message', 1788000120);
            CREATE TABLE watch_delivery_records (gateway_key TEXT, delivery_id TEXT, message_id TEXT, ingress_source TEXT, persisted_at REAL, server_ack_state TEXT);
            INSERT INTO watch_delivery_records VALUES ('quality-migration-gateway', 'legacy-pending-ack', 'quality-watch-legacy-message', 'watch_apns', 1788000120, 'pending');

            CREATE TABLE app_settings (
                id TEXT PRIMARY KEY NOT NULL,
                updated_at REAL NOT NULL DEFAULT 0
            );
            """,
            db: db
        )
    }

    @MainActor
    static func prepareIfRequested(environment: AppEnvironment) async throws {
        guard isHermeticRequested else { return }

        guard let sessionID = normalizedEnvironmentValue(sessionEnvironmentKey) else {
            throw WatchQualityRuntimeError.missingSession
        }
        let scenario = normalizedEnvironmentValue(scenarioEnvironmentKey)
        guard scenario == "watch.standard"
                || scenario == "watch.delete-guards"
                || scenario == "watch.notification-delete-confirmation"
                || scenario == "watch.migration"
                || scenario == "watch.message-load-failure"
                || scenario == "watch.gateway-cleanup-seed"
                || scenario == "watch.gateway-cleanup-recover"
                || scenario == "watch.provisioning-interrupted-seed"
                || scenario == "watch.provisioning-interrupted-recover"
                || scenario == "watch.v2-wakeup"
                || scenario == "watch.v2-wakeup-unsupported"
        else {
            throw WatchQualityRuntimeError.unsupportedScenario(
                scenario ?? "<missing>"
            )
        }

        if scenario == "watch.v2-wakeup" || scenario == "watch.v2-wakeup-unsupported" {
            try writeGatewayRouteResult(status: "RUNNING", scenario: scenario!, sessionID: sessionID, detail: nil)
            do {
                let evidence = try await verifyV2Wakeup(
                    environment: environment, sessionID: sessionID,
                    unsupported: scenario == "watch.v2-wakeup-unsupported"
                )
                try writeGatewayRouteResult(status: "PASS", scenario: scenario!, sessionID: sessionID, detail: nil, evidence: evidence)
            } catch {
                try? writeGatewayRouteResult(status: "FAIL", scenario: scenario!, sessionID: sessionID, detail: error.localizedDescription)
                throw error
            }
            await environment.refreshWatchLightCountsAndNotify()
            return
        }

        if scenario == "watch.gateway-cleanup-seed"
            || scenario == "watch.gateway-cleanup-recover" {
            let scenario = scenario!
            try writeGatewayRouteResult(
                status: "RUNNING", scenario: scenario, sessionID: sessionID, detail: nil
            )
            do {
                let evidence = try await verifyGatewayRouteRecovery(
                    environment: environment,
                    sessionID: sessionID,
                    recovering: scenario == "watch.gateway-cleanup-recover"
                )
                try writeGatewayRouteResult(
                    status: "PASS", scenario: scenario, sessionID: sessionID,
                    detail: nil, evidence: evidence
                )
            } catch {
                let cleanups = (try? await environment.dataStore.pendingWatchGatewayRouteCleanups()) ?? []
                try? writeGatewayRouteResult(
                    status: "FAIL", scenario: scenario, sessionID: sessionID,
                    detail: error.localizedDescription,
                    evidence: [
                        "pending_cleanup_keys": cleanups.map(\.deviceKey),
                        "cleanup_attempts": environment.qualityGatewayCleanupAttempts,
                        "cleanup_error": environment.qualityGatewayCleanupError ?? "",
                        "http_requests": QualityWatchGatewayTransport.probe.recordedRequests(),
                    ]
                )
                throw error
            }
            environment.setQualityGatewayRouteResult(
                scenario == "watch.gateway-cleanup-seed"
                    ? "Gateway cleanup seed passed"
                    : "Gateway cleanup recovery passed"
            )
            return
        }
        if scenario == "watch.provisioning-interrupted-seed"
            || scenario == "watch.provisioning-interrupted-recover" {
            let scenario = scenario!
            try writeGatewayRouteResult(
                status: "RUNNING", scenario: scenario, sessionID: sessionID, detail: nil
            )
            do {
                let evidence = try await verifyInterruptedProvisioning(
                    environment: environment,
                    sessionID: sessionID,
                    recovering: scenario == "watch.provisioning-interrupted-recover"
                )
                try writeGatewayRouteResult(
                    status: "PASS", scenario: scenario, sessionID: sessionID,
                    detail: nil, evidence: evidence
                )
            } catch {
                try? writeGatewayRouteResult(
                    status: "FAIL", scenario: scenario, sessionID: sessionID,
                    detail: error.localizedDescription,
                    evidence: [
                        "http_requests": QualityWatchGatewayTransport.probe.recordedRequests(),
                        "committed_generation": (await environment.dataStore.loadWatchProvisioningState())?.generation ?? 0,
                        "pending_generation": (try? await environment.dataStore.pendingWatchProvisioningGeneration()) ?? 0,
                    ]
                )
                throw error
            }
            environment.setQualityGatewayRouteResult(
                scenario == "watch.provisioning-interrupted-seed"
                    ? "Provisioning interruption seed passed"
                    : "Provisioning interruption recovery passed"
            )
            return
        }

        if scenario == "watch.migration" {
            guard let retained = try await environment.dataStore.loadWatchLightMessage(messageId: "quality-watch-legacy-message"), retained.isRead,
                  try await environment.dataStore.loadWatchDeliveryRecord(gatewayKey: "quality-migration-gateway", deliveryId: "legacy-pending-ack")?.serverAckState == .pending else {
                throw WatchQualityRuntimeError.legacyStorePreparationFailed("Upgrade lost content, local read state, or pending Gateway ACK")
            }
            let directory = try AppConstants.appLocalDatabaseDirectory(fileManager: .default, appGroupIdentifier: AppConstants.appGroupIdentifier)
            var db: OpaquePointer?
            guard sqlite3_open_v2(directory.appendingPathComponent(AppConstants.databaseStoreFilename).path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
                throw WatchQualityRuntimeError.legacyStorePreparationFailed("Cannot inspect upgraded queue")
            }
            defer { sqlite3_close(db) }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT count(*) FROM sqlite_master WHERE name = 'watch_mirror_action_queue';", -1, &statement, nil) == SQLITE_OK else {
                throw WatchQualityRuntimeError.legacyStorePreparationFailed("Cannot inspect retired queue")
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_int(statement, 0) == 0 else {
                throw WatchQualityRuntimeError.legacyStorePreparationFailed("Obsolete actions remain executable after upgrade")
            }
        }

        let defaults = UserDefaults.standard
        if defaults.string(forKey: preparedSessionDefaultsKey) != sessionID {
            if scenario != "watch.migration" {
                try await environment.dataStore.clearWatchLightStore()
            }
            try await prepareStandardImage()
            let snapshot = standardSnapshot()
            for message in snapshot.messages { try await environment.dataStore.upsertWatchLightPayload(.message(message)) }
            for event in snapshot.events { try await environment.dataStore.upsertWatchLightPayload(.event(event)) }
            for thing in snapshot.things { try await environment.dataStore.upsertWatchLightPayload(.thing(thing)) }
            defaults.set(sessionID, forKey: preparedSessionDefaultsKey)
        }

        if scenario == "watch.delete-guards" {
            try await verifyDeletionGuards(store: environment.dataStore)
        }

        if scenario == "watch.message-load-failure" {
            await environment.dataStore.enableQualityWatchMessageLoadFailure()
        }

        await environment.refreshWatchLightCountsAndNotify()
        if scenario == "watch.notification-delete-confirmation",
           let message = try await environment.dataStore.loadWatchLightMessage(messageId: "quality-watch-message-001") {
            environment.handleNotificationDelete(message)
        }
    }

    static func recordDeletionDiagnostic(_ evidence: [String: Any]) {
        guard isHermeticRequested, let root = PushGoAutomationContext.storageRootURL,
              let data = try? JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]) else { return }
        try? data.write(to: root.appendingPathComponent("watch-delete-diagnostic.json"), options: .atomic)
    }

    private static func verifyDeletionGuards(store: LocalDataStore) async throws {
        let original = standardSnapshot().messages[0]
        let config = try await store.loadServerConfig()?.normalized()
        let mode = await store.loadWatchMode()
        let generations = await store.loadWatchSyncGenerationState()
        let context = WatchControlContext(
            mode: mode, controlGeneration: generations.controlGeneration,
            standaloneProvisioningGeneration: generations.standaloneProvisioningGeneration
        )
        let changed = WatchLightMessage(
            messageId: original.messageId, title: "Replacement must survive", body: "New content under the same ID.",
            imageURL: original.imageURL, url: original.url, severity: original.severity,
            receivedAt: original.receivedAt, isRead: original.isRead, entityType: original.entityType,
            entityId: original.entityId, notificationRequestId: original.notificationRequestId
        )
        try await store.upsertWatchLightPayload(.message(changed))
        guard try await !store.deleteWatchLightMessage(matching: original, context: context, config: config),
              try await store.loadWatchLightMessage(messageId: original.messageId) == changed else {
            throw WatchQualityRuntimeError.gatewayRouteInvariant("Stale confirmation deleted replacement content")
        }
        let staleContext = WatchControlContext(
            mode: mode, controlGeneration: generations.controlGeneration + 1,
            standaloneProvisioningGeneration: generations.standaloneProvisioningGeneration
        )
        guard try await !store.deleteWatchLightMessage(matching: changed, context: staleContext, config: config),
              try await store.loadWatchLightMessage(messageId: original.messageId) == changed else {
            throw WatchQualityRuntimeError.gatewayRouteInvariant("Stale Watch configuration deleted content")
        }
        guard try await store.deleteWatchLightMessage(matching: changed, context: context, config: config),
              try await store.loadWatchLightMessage(messageId: original.messageId) == nil,
              try await !store.deleteWatchLightMessage(matching: changed, context: context, config: config),
              try await store.loadWatchLightMessage(messageId: standardSnapshot().messages[1].messageId) == standardSnapshot().messages[1] else {
            throw WatchQualityRuntimeError.gatewayRouteInvariant("Confirmed direct delete did not preserve independent content")
        }
        try await store.upsertWatchLightPayload(.message(original))
    }

    private static func writeGatewayRouteResult(
        status: String,
        scenario: String,
        sessionID: String,
        detail: String?,
        evidence: [String: Any] = [:],
        filename: String = "quality-gateway-route-result.json"
    ) throws {
        let documents = try FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let payload: [String: Any] = [
            "status": status,
            "scenario": scenario,
            "session_id": sessionID,
            "detail": (detail as Any?) ?? NSNull(),
            "evidence": evidence,
            "recorded_at": Date().timeIntervalSince1970,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try data.write(
            to: documents.appendingPathComponent(filename),
            options: .atomic
        )
    }

    @MainActor
    private static func verifyV2Wakeup(
        environment: AppEnvironment, sessionID: String, unsupported: Bool
    ) async throws -> [String: Any] {
        let store = environment.dataStore
        let deliveryID = "quality-watch-v2-\(sessionID)"
        let deviceKey = "quality-watch-v2-device-\(sessionID)"
        let messageID = "quality-watch-v2-message"
        let config = ServerConfig(baseURL: URL(string: "https://quality-watch-v2.pushgo.dev")!, token: "quality-v2-token", notificationKeyMaterial: nil, updatedAt: Date())
        if !unsupported {
            try await store.clearWatchLightStore()
            try await store.saveWatchProvisioningServerConfig(config)
            // The configured receiver owns a Gateway-scoped credential cache.
            // Direct Store setup bypasses normal runtime sync, so prepare that
            // existing cache too; otherwise the resolver sees nil-token and
            // configured-token candidates for the same Gateway.
            let gatewayTokenStore = ProviderGatewayTokenStore()
            guard gatewayTokenStore.save(token: config.token, baseURL: config.baseURL),
                  gatewayTokenStore.load(baseURL: config.baseURL) == config.token else {
                throw WatchQualityRuntimeError.gatewayRouteInvariant("V2 fixture Gateway credential cache did not persist")
            }
            guard (await store.saveCachedDeviceKey(deviceKey, for: "watchos")).didPersist else {
                throw WatchQualityRuntimeError.gatewayRouteInvariant("V2 device key did not persist")
            }
        }
        try await environment.loadQualityServerConfigFromStore()
        let originalSentAt = Int64(Date().addingTimeInterval(-2 * 60 * 60).timeIntervalSince1970 * 1_000)
        // The existing Watch light quantizer stores receivedAt at whole-second
        // precision. Keep millisecond input on the wire, and assert that exact
        // supported representation rather than inventing a new time policy.
        let expectedStoredSentAt = (originalSentAt / 1_000) * 1_000
        let probe = QualityWatchV2WakeupProbe()
        environment.installQualityGatewayTransport { request in
            try await probe.respond(request, store: store, messageID: messageID, deliveryID: deliveryID,
                                    deviceKey: deviceKey, expectedToken: config.token,
                                    sentAtMilliseconds: originalSentAt, unsupported: unsupported)
        }
        let wakeupID = unsupported ? "\(deliveryID)-unsupported" : deliveryID
        let advertisedBody = "Unverified APNs advertisement must not become saved content."
        let hint: [String: AnyCodable] = [
            "provider_mode": AnyCodable("direct"),
            "delivery_id": AnyCodable(wakeupID), "base_url": AnyCodable(config.baseURL.absoluteString),
            "provider_device_key": AnyCodable(deviceKey),
            "message_id": AnyCodable(messageID), "watch_light_kind": AnyCodable("message"),
            "title": AnyCodable("Unverified APNs preview"), "body": AnyCodable(advertisedBody),
            "aps": AnyCodable(["alert": ["title": "Unverified APNs preview", "body": advertisedBody]]),
        ]
        await environment.qualityReceiveDurableWakeup(hint)
        let factBeforeDuplicate = try await store.loadWatchDeliveryRecord(gatewayKey: config.normalizedBaseURL.absoluteString, deliveryId: deliveryID)
        if !unsupported { await environment.qualityReceiveDurableWakeup(hint) }
        let requests = await probe.recordedPaths()
        let authorizationChecks = await probe.recordedAuthorizationChecks()
        let targetedIDs = await probe.recordedTargetedDeliveryIDs()
        guard authorizationChecks.count == requests.count, authorizationChecks.allSatisfy({ $0 }),
              targetedIDs == [wakeupID]
        else { throw WatchQualityRuntimeError.gatewayRouteInvariant("Full APNs hint lost authenticated targeted V2 request context") }
        let messages = try await store.loadWatchLightMessages()
        guard messages.count == 1, let message = messages.first,
              message.messageId == messageID, message.title == "Silent V2 delivery",
              message.body == "Pulled content survives duplicate wakeups and reopen."
        else { throw WatchQualityRuntimeError.gatewayRouteInvariant("V2 wakeup lost or duplicated accurate content") }
        let storedSentAt = Int64((message.receivedAt.timeIntervalSince1970 * 1_000).rounded())
        guard (unsupported || storedSentAt == expectedStoredSentAt),
              !WatchNotificationFreshness.shouldPresent(
                payload: ["sent_at": String(storedSentAt)], configuredMinutes: 30)
        else { throw WatchQualityRuntimeError.gatewayRouteInvariant("Delayed V2 content must retain its original time without renewing Watch reminder freshness") }
        if unsupported {
            try writeGatewayRouteResult(
                status: "DIAGNOSTIC", scenario: "watch.v2-wakeup-unsupported", sessionID: sessionID, detail: nil,
                evidence: ["read": message.isRead, "http_paths": requests,
                           "toast_expected": environment.localizationManager.localized("gateway_v2_pull_required"),
                           "toast_actual": environment.toastMessage?.text ?? "<missing>"],
                filename: "quality-v2-wakeup-diagnostic.json"
            )
            guard message.isRead, requests == [ChannelSubscriptionService.pullV2Path],
                  environment.toastMessage?.text == environment.localizationManager.localized("gateway_v2_pull_required")
            else {
                throw WatchQualityRuntimeError.gatewayRouteInvariant(
                    "Unsupported V2 must retain read content and visibly require Gateway upgrade without ACK/legacy Pull; read=\(message.isRead), paths=\(requests), toast=\(environment.toastMessage?.text ?? "<missing>")"
                )
            }
        } else {
            let deliveryFact = try await store.loadWatchDeliveryRecord(gatewayKey: config.normalizedBaseURL.absoluteString, deliveryId: deliveryID)
            guard requests == [ChannelSubscriptionService.pullV2Path, ChannelSubscriptionService.batchAckV2Path],
                  let before = factBeforeDuplicate,
                  let after = deliveryFact, after.persistedAt == before.persistedAt
            else { throw WatchQualityRuntimeError.gatewayRouteInvariant("V2 wakeup must Pull once and ACK once after durable Store, including duplicate hint") }
        }
        return ["http_paths": requests, "authorization_matches_expected": authorizationChecks,
                "targeted_delivery_ids": targetedIDs, "input": "full_apns_direct_hint",
                "message_id": message.messageId, "body": message.body, "message_count": messages.count,
                "configured_fixture_sent_at_ms": originalSentAt,
                "stored_original_sent_at_ms": storedSentAt, "stored_time_precision": "seconds",
                "watch_reminder_fresh_at_30_minutes": false,
                "read_after_reopen": message.isRead, "unsupported": unsupported]
    }

    private static func prepareStandardImage() async throws {
        guard let data = Data(base64Encoded: standardImagePNGBase64),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil,
              let file = await SharedImageCache.store(data: data, for: standardImageURL),
              (try? Data(contentsOf: file)) == data
        else {
            throw WatchQualityRuntimeError.mediaPreparationFailed
        }
    }

    @MainActor
    private static func verifyGatewayRouteRecovery(
        environment: AppEnvironment,
        sessionID: String,
        recovering: Bool
    ) async throws -> [String: Any] {
        let oldKey = "quality-watch-old-\(sessionID)"
        let a = ServerConfig(
            id: UUID(), name: "Quality Gateway A",
            baseURL: URL(string: "https://quality-watch-a.pushgo.dev")!,
            token: "quality-token-a", notificationKeyMaterial: nil,
            updatedAt: Date()
        )
        let b = ServerConfig(
            id: UUID(), name: "Quality Gateway B",
            baseURL: URL(string: "https://quality-watch-b.pushgo.dev")!,
            token: "quality-token-b", notificationKeyMaterial: nil,
            updatedAt: Date()
        )
        QualityWatchGatewayTransport.probe.configure(
            oldKey: oldKey,
            failOldDelete: !recovering
        )
        environment.installQualityGatewayTransport { request in
            try QualityWatchGatewayTransport.response(for: request)
        }

        if !recovering {
            try await environment.updateServerConfig(a)
            guard (await environment.dataStore.saveCachedDeviceKey(oldKey, for: "watchos")).didPersist else {
                throw WatchQualityRuntimeError.gatewayRouteInvariant("old key was not persisted")
            }
            await environment.applyStandaloneProvisioningFromPhone(
                provisioningSnapshot(generation: 1, config: b)
            )
            await environment.waitForQualityGatewayOperations()
            let config = try await environment.dataStore.loadWatchProvisioningServerConfig()
            let cleanups = try await environment.dataStore.pendingWatchGatewayRouteCleanups()
            guard config?.gatewayKey == b.gatewayKey,
                  await environment.dataStore.loadWatchProvisioningState()?.generation == 1,
                  cleanups.contains(where: {
                      $0.baseURL == a.normalizedBaseURL
                          && $0.deviceKey == oldKey
                          && $0.lastSucceededAt == nil
                  }),
                  try await environment.dataStore.isRetiredWatchGatewayRouteKey(
                      baseURL: a.normalizedBaseURL, deviceKey: oldKey
                  ),
                  QualityWatchGatewayTransport.probe.count(
                      path: ChannelSubscriptionService.deviceChannelDeletePath,
                      host: a.baseURL.host,
                      deviceKey: oldKey
                  ) == 1
            else {
                throw WatchQualityRuntimeError.gatewayRouteInvariant("failed delete was not journaled")
            }
            return [
                "active_gateway": config?.gatewayKey ?? "",
                "provisioning_generation": 1,
                "old_device_key": oldKey,
                "pending_cleanup_keys": cleanups.map(\.deviceKey),
                "old_route_delete_attempts": QualityWatchGatewayTransport.probe.count(
                    path: ChannelSubscriptionService.deviceChannelDeletePath,
                    host: a.baseURL.host, deviceKey: oldKey
                ),
                "http_requests": QualityWatchGatewayTransport.probe.recordedRequests(),
            ]
        }

        let persisted = try await environment.dataStore.loadWatchProvisioningServerConfig()
        guard persisted?.gatewayKey == b.gatewayKey,
              await environment.dataStore.loadWatchProvisioningState()?.generation == 1
        else {
            throw WatchQualityRuntimeError.gatewayRouteInvariant("provisioning did not survive relaunch")
        }
        try await environment.updateServerConfig(b)
        await environment.waitForQualityGatewayOperations()
        let recovered = try await environment.dataStore.pendingWatchGatewayRouteCleanups()
        guard recovered.contains(where: {
            $0.baseURL == a.normalizedBaseURL
                && $0.deviceKey == oldKey
                && $0.lastSucceededAt != nil
        }) else {
            throw WatchQualityRuntimeError.gatewayRouteInvariant("old route was not retried after relaunch")
        }

        await environment.applyStandaloneProvisioningFromPhone(
            provisioningSnapshot(generation: 2, config: a)
        )
        await environment.waitForQualityGatewayOperations()
        guard let newKey = await environment.qualityEnsureDeviceKey(config: a),
              newKey != oldKey
        else {
            throw WatchQualityRuntimeError.gatewayRouteInvariant("returned gateway reused retired key")
        }
        await environment.qualitySyncRoute(config: a)
        await environment.qualitySyncRoute(config: b)
        await environment.waitForQualityGatewayOperations()
        guard QualityWatchGatewayTransport.probe.hasFreshRegistration(on: a.baseURL.host),
              QualityWatchGatewayTransport.probe.count(
                  path: ChannelSubscriptionService.deviceRoutePath,
                  host: a.baseURL.host,
                  deviceKey: newKey
              ) == 1,
              QualityWatchGatewayTransport.probe.count(
                  path: ChannelSubscriptionService.deviceRoutePath,
                  host: b.baseURL.host,
                  deviceKey: nil
              ) == 0,
              QualityWatchGatewayTransport.probe.count(
                  path: ChannelSubscriptionService.deviceChannelDeletePath,
                  host: a.baseURL.host,
                  deviceKey: newKey
              ) == 0
        else {
            throw WatchQualityRuntimeError.gatewayRouteInvariant("new route or stale writer escaped fence")
        }

        let controlledNow = Date(timeIntervalSince1970: 1_800_000_000)
        guard AppEnvironment.canReuseDeviceRegistration(lastRegisteredAt: controlledNow, registeredWindowMinutes: 5, currentWindowMinutes: 5, interval: 45, now: controlledNow.addingTimeInterval(1)),
              !AppEnvironment.canReuseDeviceRegistration(lastRegisteredAt: controlledNow, registeredWindowMinutes: 5, currentWindowMinutes: 15, interval: 45, now: controlledNow.addingTimeInterval(1)),
              !AppEnvironment.canReuseDeviceRegistration(lastRegisteredAt: controlledNow, registeredWindowMinutes: nil, currentWindowMinutes: 30, interval: 45, now: controlledNow.addingTimeInterval(1)),
              !AppEnvironment.canReuseDeviceRegistration(lastRegisteredAt: controlledNow, registeredWindowMinutes: 5, currentWindowMinutes: 5, interval: 45, now: controlledNow.addingTimeInterval(45)) else {
            throw WatchQualityRuntimeError.gatewayRouteInvariant("registration cache ignored window identity or interval")
        }
        await environment.applyStandaloneProvisioningFromPhone(provisioningSnapshot(generation: 3, config: a, watchAlertWindowMinutes: 5))
        await environment.waitForQualityGatewayOperations()
        guard let fiveMinuteKey = await environment.qualityEnsureDeviceKey(config: a),
              QualityWatchGatewayTransport.probe.hasRegistration(windowMinutes: 5, on: a.baseURL.host) else {
            throw WatchQualityRuntimeError.gatewayRouteInvariant("five minute window was not registered")
        }
        let fiveMinuteRequestCount = QualityWatchGatewayTransport.probe.count(path: ChannelSubscriptionService.deviceRegisterPath, host: a.baseURL.host, deviceKey: nil)
        guard await environment.qualityEnsureDeviceKey(config: a) == fiveMinuteKey,
              QualityWatchGatewayTransport.probe.count(path: ChannelSubscriptionService.deviceRegisterPath, host: a.baseURL.host, deviceKey: nil) == fiveMinuteRequestCount else {
            throw WatchQualityRuntimeError.gatewayRouteInvariant("confirmed same-window registration was not cached")
        }
        QualityWatchGatewayTransport.probe.failRegistration(windowMinutes: 15)
        await environment.applyStandaloneProvisioningFromPhone(provisioningSnapshot(generation: 4, config: a, watchAlertWindowMinutes: 15))
        await environment.waitForQualityGatewayOperations()
        let failedKey = await environment.qualityEnsureDeviceKey(config: a)
        guard failedKey == nil, !environment.standaloneReady,
              await environment.dataStore.cachedDeviceKey(for: "watchos") == fiveMinuteKey,
              QualityWatchGatewayTransport.probe.hasRegistration(windowMinutes: 15, on: a.baseURL.host),
              QualityWatchGatewayTransport.probe.count(path: ChannelSubscriptionService.deviceRegisterPath, host: a.baseURL.host, deviceKey: nil) > fiveMinuteRequestCount else {
            throw WatchQualityRuntimeError.gatewayRouteInvariant("changed window skipped registration or failed registration claimed readiness")
        }
        QualityWatchGatewayTransport.probe.failRegistration(windowMinutes: nil)

        return [
            "active_gateway": (try await environment.dataStore.loadWatchProvisioningServerConfig())?.gatewayKey ?? "",
            "provisioning_generation": (await environment.dataStore.loadWatchProvisioningState())?.generation ?? 0,
            "old_device_key": oldKey,
            "returned_device_key": newKey,
            "resumed_device_key": newKey,
            "alert_window_cache_matrix": "passed",
            "five_minute_registration_confirmed": true,
            "fifteen_minute_registration_failure_preserved_old_key": true,
            "failed_window_standalone_ready": environment.standaloneReady,
            "old_cleanup_last_succeeded_at": recovered.first(where: {
                $0.baseURL == a.normalizedBaseURL && $0.deviceKey == oldKey
            })?.lastSucceededAt?.timeIntervalSince1970 ?? 0,
            "stale_gateway_upsert_count": QualityWatchGatewayTransport.probe.count(
                path: ChannelSubscriptionService.deviceRoutePath,
                host: b.baseURL.host, deviceKey: nil
            ),
            "http_requests": QualityWatchGatewayTransport.probe.recordedRequests(),
        ]
    }

    @MainActor
    private static func verifyInterruptedProvisioning(
        environment: AppEnvironment,
        sessionID: String,
        recovering: Bool
    ) async throws -> [String: Any] {
        let a = ServerConfig(
            id: UUID(), name: "Quality Provisioning Gateway",
            baseURL: URL(string: "https://quality-watch-provisioning.pushgo.dev")!,
            token: nil, notificationKeyMaterial: nil,
            updatedAt: Date()
        )
        QualityWatchGatewayTransport.probe.configure(oldKey: "", failOldDelete: false)
        environment.installQualityGatewayTransport { request in
            try QualityWatchGatewayTransport.response(for: request)
        }
        let first = WatchStandaloneChannelCredential(
            gateway: a.gatewayKey, channelId: "quality-old-\(sessionID)",
            displayName: "Old channel", password: sessionID,
            updatedAt: Date()
        )
        let second = WatchStandaloneChannelCredential(
            gateway: a.gatewayKey, channelId: "quality-new-\(sessionID)",
            displayName: "New channel", password: sessionID,
            updatedAt: Date()
        )
        let newer = provisioningSnapshot(generation: 2, config: a, channels: [second])
        if !recovering {
            _ = try await environment.dataStore.applyWatchStandaloneProvisioning(
                provisioningSnapshot(generation: 1, config: a, channels: [first]),
                sourceControlGeneration: 0
            )
            try await environment.loadQualityServerConfigFromStore()
            await environment.dataStore.enableQualityProvisioningInterruption()
            do {
                _ = try await environment.dataStore.applyWatchStandaloneProvisioning(
                    newer, sourceControlGeneration: 0
                )
                throw WatchQualityRuntimeError.gatewayRouteInvariant("injected interruption did not fire")
            } catch let error as WatchQualityRuntimeError {
                throw error
            } catch {}
        } else {
            try await environment.loadQualityServerConfigFromStore()
        }

        let beforeConfig = try await environment.dataStore.loadWatchProvisioningServerConfig()
        let beforeGeneration = await environment.dataStore.loadWatchProvisioningState()?.generation
        let pending = try await environment.dataStore.pendingWatchProvisioningGeneration()
        let credentials = try await environment.dataStore.activeChannelCredentials(gateway: a.gatewayKey)
        guard beforeConfig?.gatewayKey == a.gatewayKey,
              beforeGeneration == 1,
              pending == 2,
              credentials.contains(where: { $0.channelId == second.channelId }),
              !environment.standaloneReady
        else {
            throw WatchQualityRuntimeError.gatewayRouteInvariant("mixed Keychain state was not fenced")
        }
        await environment.qualitySyncRoute(config: a)
        guard QualityWatchGatewayTransport.probe.count(
            path: ChannelSubscriptionService.deviceRoutePath,
            host: a.baseURL.host, deviceKey: nil
        ) == 0 else {
            throw WatchQualityRuntimeError.gatewayRouteInvariant("pending snapshot wrote old-generation route")
        }
        if !recovering {
            return [
                "committed_generation": beforeGeneration ?? 0,
                "pending_generation": pending ?? 0,
                "active_channel_ids": credentials.map(\.channelId),
                "upsert_count_while_pending": 0,
                "http_requests": QualityWatchGatewayTransport.probe.recordedRequests(),
            ]
        }

        await environment.applyStandaloneProvisioningFromPhone(newer)
        await environment.waitForQualityGatewayOperations()
        let afterGeneration = await environment.dataStore.loadWatchProvisioningState()?.generation
        let afterPending = try await environment.dataStore.pendingWatchProvisioningGeneration()
        guard afterGeneration == 2, afterPending == nil else {
            throw WatchQualityRuntimeError.gatewayRouteInvariant("phone replay did not commit and clear barrier")
        }
        await environment.qualitySyncRoute(config: a)
        guard QualityWatchGatewayTransport.probe.count(
            path: ChannelSubscriptionService.deviceRoutePath,
            host: a.baseURL.host, deviceKey: nil
        ) == 1 else {
            throw WatchQualityRuntimeError.gatewayRouteInvariant("completed replay did not restore route")
        }
        return [
            "committed_generation_before_replay": beforeGeneration ?? 0,
            "pending_generation_before_replay": pending ?? 0,
            "committed_generation_after_replay": afterGeneration ?? 0,
            "pending_cleared_after_replay": true,
            "active_channel_ids_before_replay": credentials.map(\.channelId),
            "http_requests": QualityWatchGatewayTransport.probe.recordedRequests(),
        ]
    }

    private static func provisioningSnapshot(
        generation: Int64,
        config: ServerConfig,
        channels: [WatchStandaloneChannelCredential] = [],
        watchAlertWindowMinutes: Int = 30
    ) -> WatchStandaloneProvisioningSnapshot {
        WatchStandaloneProvisioningSnapshot(
            generation: generation,
            mode: .standalone,
            serverConfig: config,
            notificationKeyMaterial: nil,
            channels: channels,
            contentDigest: WatchStandaloneProvisioningSnapshot.contentDigest(
                serverConfig: config, notificationKeyMaterial: nil, channels: channels,
                watchAlertWindowMinutes: watchAlertWindowMinutes
            ),
            watchAlertWindowMinutes: watchAlertWindowMinutes
        )
    }

    private static func standardSnapshot() -> (messages: [WatchLightMessage], events: [WatchLightEvent], things: [WatchLightThing]) {
        let receivedAt = Date(timeIntervalSince1970: 1_788_000_000)
        let messages = [
            WatchLightMessage(
                messageId: "quality-watch-message-001",
                title: "Gateway health warning",
                body: "Primary API latency is above budget.",
                imageURL: standardImageURL,
                url: URL(string: "https://pushgo.dev/quality-message"),
                severity: "critical",
                receivedAt: receivedAt,
                isRead: false,
                entityType: "message",
                entityId: nil,
                notificationRequestId: "quality-watch-request-001"
            ),
            WatchLightMessage(
                messageId: "quality-watch-message-002",
                title: "Database recovered",
                body: "Replica lag returned to normal.",
                imageURL: nil,
                url: nil,
                severity: "normal",
                receivedAt: receivedAt.addingTimeInterval(-60),
                isRead: false,
                entityType: "message",
                entityId: nil,
                notificationRequestId: "quality-watch-request-002"
            ),
        ]
        let events = [
            WatchLightEvent(
                eventId: "quality-watch-event-001",
                title: "Payments incident",
                summary: "Checkout errors exceeded threshold.",
                state: "ONGOING",
                severity: "high",
                decryptionState: nil,
                imageURL: standardImageURL,
                updatedAt: receivedAt.addingTimeInterval(-120)
            ),
        ]
        let things = [
            WatchLightThing(
                thingId: "quality-watch-thing-001",
                title: "Checkout API",
                summary: "Degraded in eu-west.",
                attrsJSON: #"{"region":"eu-west","version":"42"}"#,
                decryptionState: nil,
                imageURL: standardImageURL,
                updatedAt: receivedAt.addingTimeInterval(-180)
            ),
        ]
        return (messages, events, things)
    }

    private static func normalizedEnvironmentValue(_ key: String) -> String? {
        let value = ProcessInfo.processInfo.environment[key]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private static func executeLegacySQL(_ sql: String, db: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message: String
            if let errorMessage {
                message = String(cString: errorMessage)
            } else {
                message = "code \(result)"
            }
            sqlite3_free(errorMessage)
            throw WatchQualityRuntimeError.legacyStorePreparationFailed(message)
        }
    }
}

private enum WatchQualityRuntimeError: LocalizedError {
    case missingSession
    case unsupportedScenario(String)
    case legacyStorePreparationFailed(String)
    case mediaPreparationFailed
    case gatewayRouteInvariant(String)

    var errorDescription: String? {
        switch self {
        case .missingSession:
            return "Hermetic watch quality launch requires an App-owned session identifier."
        case let .unsupportedScenario(scenario):
            return "Unsupported hermetic watch quality scenario: \(scenario)."
        case let .legacyStorePreparationFailed(reason):
            return "Unable to prepare the App-owned legacy watch store: \(reason)."
        case .mediaPreparationFailed:
            return "Unable to prepare the App-owned watch media fixture."
        case let .gatewayRouteInvariant(reason):
            return "Watch gateway route recovery failed: \(reason)."
        }
    }
}

/// A bounded transport probe for the production Watch wakeup/Store/ACK path.
private actor QualityWatchV2WakeupProbe {
    private var paths: [String] = []
    private var authorizationChecks: [Bool] = []
    private var targetedDeliveryIDs: [String] = []

    func recordedPaths() -> [String] { paths }
    func recordedAuthorizationChecks() -> [Bool] { authorizationChecks }
    func recordedTargetedDeliveryIDs() -> [String] { targetedDeliveryIDs }

    func respond(
        _ request: URLRequest, store: LocalDataStore, messageID: String,
        deliveryID: String, deviceKey: String, expectedToken: String?, sentAtMilliseconds: Int64, unsupported: Bool
    ) async throws -> (Data, URLResponse) {
        guard let url = request.url, url.host == "quality-watch-v2.pushgo.dev",
              request.httpMethod == "POST",
              let bytes = request.httpBody,
              let body = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              body["device_key"] as? String == deviceKey
        else { throw WatchQualityRuntimeError.gatewayRouteInvariant("Unexpected V2 wakeup request identity") }
        paths.append(url.path)
        let authorizationMatches = expectedToken.map { request.value(forHTTPHeaderField: "Authorization") == "Bearer \($0)" } ?? false
        authorizationChecks.append(authorizationMatches)
        guard authorizationMatches else {
            throw WatchQualityRuntimeError.gatewayRouteInvariant("V2 request did not use the configured authentication context")
        }
        let data: [String: Any]
        let status: Int
        if url.path == ChannelSubscriptionService.pullV2Path {
            guard body["delivery_id"] as? String == (unsupported ? "\(deliveryID)-unsupported" : deliveryID) else {
                throw WatchQualityRuntimeError.gatewayRouteInvariant("Silent wakeup lost targeted delivery ID")
            }
            targetedDeliveryIDs.append(unsupported ? "\(deliveryID)-unsupported" : deliveryID)
            if !unsupported, try await store.loadWatchLightMessage(messageId: messageID) != nil {
                throw WatchQualityRuntimeError.gatewayRouteInvariant("Raw APNs content was saved before authenticated V2 content arrived")
            }
            status = unsupported ? 404 : 200
            data = unsupported
                ? ["success": false, "error": "route_not_found", "error_code": "route_not_found"]
                : ["success": true, "data": ["has_more": false, "items": [[
                    "delivery_id": deliveryID,
                    "payload": ["message_id": messageID, "watch_light_kind": "message",
                                "title": "Silent V2 delivery", "body": "Pulled content survives duplicate wakeups and reopen.",
                                "sent_at": String(sentAtMilliseconds), "severity": "normal"],
                ]]]]
        } else if url.path == ChannelSubscriptionService.batchAckV2Path {
            guard !unsupported, body["delivery_ids"] as? [String] == [deliveryID],
                  let stored = try await store.loadWatchLightMessage(messageId: messageID),
                  stored.body == "Pulled content survives duplicate wakeups and reopen.",
                  Int64((stored.receivedAt.timeIntervalSince1970 * 1_000).rounded()) == (sentAtMilliseconds / 1_000) * 1_000,
                  try await store.loadWatchDeliveryRecord(gatewayKey: "https://quality-watch-v2.pushgo.dev", deliveryId: deliveryID) != nil
            else { throw WatchQualityRuntimeError.gatewayRouteInvariant("Gateway ACK preceded accurate durable Watch content") }
            status = 200
            data = ["success": true, "data": ["requested_count": 1, "removed_count": 1]]
        } else {
            throw WatchQualityRuntimeError.gatewayRouteInvariant("Unexpected endpoint, including forbidden legacy Pull: \(url.path)")
        }
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else { throw URLError(.badServerResponse) }
        return (try JSONSerialization.data(withJSONObject: data), response)
    }
}

private enum QualityWatchGatewayTransport {
    struct RecordedRequest: Sendable {
        let path: String
        let host: String?
        let deviceKey: String?
        let freshRegistration: Bool
        let windowMinutes: Int?
    }

    final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [RecordedRequest] = []
        private var oldKey = ""
        private var failOldDelete = false
        private var nextKey = 0
        private var failedRegistrationWindowMinutes: Int?

        func configure(oldKey: String, failOldDelete: Bool) {
            lock.lock()
            defer { lock.unlock() }
            requests = []
            self.oldKey = oldKey
            self.failOldDelete = failOldDelete
            nextKey = 0
            failedRegistrationWindowMinutes = nil
        }

        func failRegistration(windowMinutes: Int?) {
            lock.lock()
            defer { lock.unlock() }
            failedRegistrationWindowMinutes = windowMinutes
        }

        func record(_ request: URLRequest) -> (status: Int, payload: [String: Any]) {
            let bodyData: Data?
            if let direct = request.httpBody {
                bodyData = direct
            } else if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var bytes = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    bytes.append(contentsOf: buffer.prefix(count))
                }
                bodyData = bytes
            } else {
                bodyData = nil
            }
            let body = bodyData.flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            } ?? [:]
            let path = request.url?.path ?? ""
            let key = body["device_key"] as? String
            let freshRegistration = path == ChannelSubscriptionService.deviceRegisterPath && key == nil
            lock.lock()
            defer { lock.unlock() }
            requests.append(RecordedRequest(
                path: path,
                host: request.url?.host,
                deviceKey: key,
                freshRegistration: freshRegistration,
                windowMinutes: body["watch_alert_window_minutes"] as? Int
            ))
            if path == ChannelSubscriptionService.deviceChannelDeletePath,
               key == oldKey, failOldDelete {
                return (503, ["success": false, "error": "temporary failure"])
            }
            if path == ChannelSubscriptionService.deviceRegisterPath {
                if let failedRegistrationWindowMinutes, body["watch_alert_window_minutes"] as? Int == failedRegistrationWindowMinutes {
                    return (503, ["success": false, "error": "injected window registration failure"])
                }
                nextKey += 1
                return (200, ["success": true, "data": ["device_key": "quality-watch-new-\(nextKey)"]])
            }
            if path == ChannelSubscriptionService.deviceRoutePath {
                return (200, ["success": true, "data": ["device_key": key ?? "", "channel_type": "apns"]])
            }
            if path == "/channel/sync" {
                return (200, ["success": true, "data": ["success": 0, "failed": 0, "channels": []]])
            }
            return (200, ["success": true, "data": [:]])
        }

        func count(path: String, host: String?, deviceKey: String?) -> Int {
            lock.lock()
            defer { lock.unlock() }
            return requests.filter {
                $0.path == path && $0.host == host
                    && (deviceKey == nil || $0.deviceKey == deviceKey)
            }.count
        }

        func hasRegistration(windowMinutes: Int, on host: String?) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return requests.contains { $0.path == ChannelSubscriptionService.deviceRegisterPath && $0.host == host && $0.windowMinutes == windowMinutes }
        }

        func hasFreshRegistration(on host: String?) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return requests.contains { $0.host == host && $0.freshRegistration }
        }

        func recordedRequests() -> [[String: Any]] {
            lock.lock()
            defer { lock.unlock() }
            return requests.map {
                [
                    "path": $0.path,
                    "host": $0.host ?? "",
                    "device_key": ($0.deviceKey as Any?) ?? NSNull(),
                    "fresh_registration": $0.freshRegistration,
                    "watch_alert_window_minutes": ($0.windowMinutes as Any?) ?? NSNull(),
                ]
            }
        }
    }

    static let probe = Probe()

    static func response(for request: URLRequest) throws -> (Data, URLResponse) {
        guard request.url?.host?.hasPrefix("quality-watch-") == true else {
            throw URLError(.unsupportedURL)
        }
        let result = probe.record(request)
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url, statusCode: result.status, httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"]
              ),
              let data = try? JSONSerialization.data(withJSONObject: result.payload)
        else {
            throw URLError(.badServerResponse)
        }
        return (data, response)
    }
}
#endif
