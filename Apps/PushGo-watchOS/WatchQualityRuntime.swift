#if DEBUG
import Foundation
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
        "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAFElEQVR42mNkYPj/n4GBgYGJAQoAHgQCAf2fP6sAAAAASUVORK5CYII="

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
                0,
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
                || scenario == "watch.migration"
                || scenario == "watch.message-load-failure"
                || scenario == "watch.gateway-cleanup-seed"
                || scenario == "watch.gateway-cleanup-recover"
                || scenario == "watch.provisioning-interrupted-seed"
                || scenario == "watch.provisioning-interrupted-recover"
        else {
            throw WatchQualityRuntimeError.unsupportedScenario(
                scenario ?? "<missing>"
            )
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

        let defaults = UserDefaults.standard
        if defaults.string(forKey: preparedSessionDefaultsKey) != sessionID {
            if scenario != "watch.migration" {
                try await environment.dataStore.clearWatchLightStore()
            }
            try await prepareStandardImage()
            let snapshot = standardSnapshot()
            try await environment.dataStore.mergeWatchMirrorSnapshot(snapshot)
            defaults.set(sessionID, forKey: preparedSessionDefaultsKey)
        }

        if scenario == "watch.message-load-failure" {
            await environment.dataStore.enableQualityWatchMessageLoadFailure()
        }

        await environment.refreshWatchLightCountsAndNotify()
    }

    private static func writeGatewayRouteResult(
        status: String,
        scenario: String,
        sessionID: String,
        detail: String?,
        evidence: [String: Any] = [:]
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
            to: documents.appendingPathComponent("quality-gateway-route-result.json"),
            options: .atomic
        )
    }

    private static func prepareStandardImage() async throws {
        guard let data = Data(base64Encoded: standardImagePNGBase64),
              await SharedImageCache.store(data: data, for: standardImageURL) != nil,
              await SharedImageCache.cachedData(for: standardImageURL) == data
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

        await environment.qualityChangeMode(.mirror)
        await environment.waitForQualityGatewayOperations()
        let mirrorCleanups = try await environment.dataStore.pendingWatchGatewayRouteCleanups()
        guard mirrorCleanups.contains(where: {
            $0.baseURL == a.normalizedBaseURL && $0.deviceKey == newKey
        }) else {
            throw WatchQualityRuntimeError.gatewayRouteInvariant("mirror transition did not journal route")
        }
        await environment.qualityChangeMode(.standalone)
        guard let resumedKey = await environment.qualityEnsureDeviceKey(config: a),
              resumedKey != oldKey, resumedKey != newKey
        else {
            throw WatchQualityRuntimeError.gatewayRouteInvariant("standalone resumed with retired route key")
        }
        await environment.qualitySyncRoute(config: a)
        guard QualityWatchGatewayTransport.probe.count(
            path: ChannelSubscriptionService.deviceChannelDeletePath,
            host: a.baseURL.host,
            deviceKey: resumedKey
        ) == 0 else {
            throw WatchQualityRuntimeError.gatewayRouteInvariant("cleanup deleted resumed route")
        }
        return [
            "active_gateway": (try await environment.dataStore.loadWatchProvisioningServerConfig())?.gatewayKey ?? "",
            "provisioning_generation": (await environment.dataStore.loadWatchProvisioningState())?.generation ?? 0,
            "old_device_key": oldKey,
            "returned_device_key": newKey,
            "resumed_device_key": resumedKey,
            "old_cleanup_last_succeeded_at": recovered.first(where: {
                $0.baseURL == a.normalizedBaseURL && $0.deviceKey == oldKey
            })?.lastSucceededAt?.timeIntervalSince1970 ?? 0,
            "mirror_cleanup_journaled": true,
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
        channels: [WatchStandaloneChannelCredential] = []
    ) -> WatchStandaloneProvisioningSnapshot {
        WatchStandaloneProvisioningSnapshot(
            generation: generation,
            mode: .standalone,
            serverConfig: config,
            notificationKeyMaterial: nil,
            channels: channels,
            contentDigest: WatchStandaloneProvisioningSnapshot.contentDigest(
                serverConfig: config, notificationKeyMaterial: nil, channels: channels
            )
        )
    }

    private static func standardSnapshot() -> WatchMirrorSnapshot {
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
        return WatchMirrorSnapshot(
            generation: 1,
            mode: .standalone,
            messages: messages,
            events: events,
            things: things,
            exportedAt: receivedAt,
            contentDigest: WatchMirrorSnapshot.contentDigest(
                messages: messages,
                events: events,
                things: things
            )
        )
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

private enum QualityWatchGatewayTransport {
    struct RecordedRequest: Sendable {
        let path: String
        let host: String?
        let deviceKey: String?
        let freshRegistration: Bool
    }

    final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [RecordedRequest] = []
        private var oldKey = ""
        private var failOldDelete = false
        private var nextKey = 0

        func configure(oldKey: String, failOldDelete: Bool) {
            lock.lock()
            defer { lock.unlock() }
            requests = []
            self.oldKey = oldKey
            self.failOldDelete = failOldDelete
            nextKey = 0
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
                freshRegistration: freshRegistration
            ))
            if path == ChannelSubscriptionService.deviceChannelDeletePath,
               key == oldKey, failOldDelete {
                return (503, ["success": false, "error": "temporary failure"])
            }
            if path == ChannelSubscriptionService.deviceRegisterPath {
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
