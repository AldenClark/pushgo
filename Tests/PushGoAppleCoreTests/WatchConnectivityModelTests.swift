import Foundation
import Testing
@testable import PushGoAppleCore

struct WatchConnectivityModelTests {
    @Test
    func manifestRoundTripsThroughApplicationContext() throws {
        let createdAt = Date(timeIntervalSince1970: 1_732_000_000)
        let manifest = WatchSyncManifest(
            schemaVersion: WatchConnectivitySchema.currentVersion,
            mode: .standalone,
            controlGeneration: 42,
            mirrorPackage: MirrorPackageRef(
                packageID: "mirror-package",
                generation: 41,
                createdAt: createdAt
            ),
            standalonePackage: StandalonePackageRef(
                packageID: "standalone-package",
                generation: 42,
                createdAt: createdAt
            ),
            effectiveModeStatus: WatchEffectiveModeStatus(
                effectiveMode: .standalone,
                sourceControlGeneration: 42,
                appliedAt: Date(timeIntervalSince1970: 1_732_000_009),
                noop: false,
                status: .applied,
                failureReason: nil
            ),
            standaloneReadinessStatus: WatchStandaloneReadinessStatus(
                effectiveMode: .standalone,
                standaloneReady: true,
                sourceControlGeneration: 42,
                provisioningGeneration: 42,
                reportedAt: Date(timeIntervalSince1970: 1_732_000_009),
                failureReason: nil
            ),
            ackCursor: AckCursorRef(
                generation: 9,
                lastEventID: "event-9"
            ),
            mirrorSnapshotAck: AppliedPackageAckRef(
                generation: 41,
                contentDigest: "mirror-digest-41",
                appliedAt: Date(timeIntervalSince1970: 1_732_000_010)
            ),
            standaloneProvisioningAck: AppliedPackageAckRef(
                generation: 42,
                contentDigest: "standalone-digest-42",
                appliedAt: Date(timeIntervalSince1970: 1_732_000_011)
            ),
            inlineMirrorSnapshot: nil,
            inlineStandaloneProvisioning: nil
        )

        let decoded = try #require(WatchSyncManifest.fromApplicationContext(manifest.applicationContext()))
        #expect(decoded == manifest)
        #expect(decoded.isCurrentSchema)
    }

    @Test
    func manifestRoundTripsEffectiveModeStatusThroughDictionaryPayload() throws {
        let manifest = WatchSyncManifest(
            schemaVersion: WatchConnectivitySchema.currentVersion,
            mode: .mirror,
            controlGeneration: 88,
            mirrorPackage: nil,
            standalonePackage: nil,
            effectiveModeStatus: WatchEffectiveModeStatus(
                effectiveMode: .mirror,
                sourceControlGeneration: 88,
                appliedAt: Date(timeIntervalSince1970: 1_732_100_000),
                noop: true,
                status: .applied,
                failureReason: nil
            ),
            standaloneReadinessStatus: WatchStandaloneReadinessStatus(
                effectiveMode: .mirror,
                standaloneReady: false,
                sourceControlGeneration: 88,
                provisioningGeneration: 0,
                reportedAt: Date(timeIntervalSince1970: 1_732_100_001),
                failureReason: "waiting_for_standalone"
            ),
            ackCursor: nil,
            mirrorSnapshotAck: nil,
            standaloneProvisioningAck: nil,
            inlineMirrorSnapshot: nil,
            inlineStandaloneProvisioning: nil
        )

        let context = manifest.applicationContext()
        let decoded = try #require(WatchSyncManifest.fromApplicationContext(context))

        #expect(decoded.effectiveModeStatus == manifest.effectiveModeStatus)
        #expect(decoded.standaloneReadinessStatus == manifest.standaloneReadinessStatus)
        #expect(decoded == manifest)
    }

    @Test
    func manifestApplicationContextSupportsNilAckCursorEventID() throws {
        let manifest = WatchSyncManifest(
            schemaVersion: WatchConnectivitySchema.currentVersion,
            mode: .mirror,
            controlGeneration: 100,
            mirrorPackage: MirrorPackageRef(
                packageID: "mirror-package",
                generation: 99,
                createdAt: Date(timeIntervalSince1970: 1_732_000_111)
            ),
            standalonePackage: nil,
            ackCursor: AckCursorRef(
                generation: 100,
                lastEventID: nil
            ),
            mirrorSnapshotAck: nil,
            standaloneProvisioningAck: nil,
            inlineMirrorSnapshot: nil,
            inlineStandaloneProvisioning: nil
        )

        let context = manifest.applicationContext()
        #expect(PropertyListSerialization.propertyList(context, isValidFor: .binary))
        let ackCursor = try #require(context["watch_manifest_ack_cursor"] as? [String: Any])
        #expect(ackCursor["lastEventID"] == nil)

        let decoded = try #require(WatchSyncManifest.fromApplicationContext(context))
        #expect(decoded.ackCursor?.lastEventID == nil)
        #expect(decoded == manifest)
    }

    @Test
    func manifestDecodesFromEncodedBlobFallbackWhenDictionaryFieldsAreMissing() throws {
        let createdAt = Date(timeIntervalSince1970: 1_732_000_333)
        let manifest = WatchSyncManifest(
            schemaVersion: WatchConnectivitySchema.currentVersion,
            mode: .standalone,
            controlGeneration: 333,
            mirrorPackage: MirrorPackageRef(
                packageID: "mirror-blob-fallback",
                generation: 332,
                createdAt: createdAt
            ),
            standalonePackage: StandalonePackageRef(
                packageID: "standalone-blob-fallback",
                generation: 333,
                createdAt: createdAt
            ),
            ackCursor: AckCursorRef(generation: 12, lastEventID: "event-12"),
            mirrorSnapshotAck: nil,
            standaloneProvisioningAck: nil,
            inlineMirrorSnapshot: nil,
            inlineStandaloneProvisioning: nil
        )

        var context = manifest.applicationContext()
        context.removeValue(forKey: "watch_manifest_mode")
        context.removeValue(forKey: "watch_manifest_control_generation")
        #expect(PropertyListSerialization.propertyList(context, isValidFor: .binary))

        let decoded = try #require(WatchSyncManifest.fromApplicationContext(context))
        #expect(decoded == manifest)
    }

    @Test
    func manifestRoundTripsInlineSnapshotPayloadThroughApplicationContext() throws {
        let package = MirrorSnapshotPackage(
            manifest: WatchTransferPackageManifest(
                schemaVersion: WatchConnectivitySchema.currentVersion,
                packageID: "inline-manifest-mirror",
                kind: .mirrorSnapshot,
                generation: 444,
                createdAt: Date(timeIntervalSince1970: 1_732_000_444)
            ),
            snapshot: WatchMirrorSnapshot(
                generation: 444,
                mode: .mirror,
                messages: [],
                events: [],
                things: [],
                exportedAt: Date(timeIntervalSince1970: 1_732_000_445),
                contentDigest: "inline-manifest-digest"
            )
        )
        let inlinePayload = try #require(WatchConnectivityWire.encode(package))
        let manifest = WatchSyncManifest(
            schemaVersion: WatchConnectivitySchema.currentVersion,
            mode: .mirror,
            controlGeneration: 444,
            mirrorPackage: MirrorPackageRef(
                packageID: package.manifest.packageID,
                generation: package.manifest.generation,
                createdAt: package.manifest.createdAt
            ),
            standalonePackage: nil,
            ackCursor: AckCursorRef(generation: 0, lastEventID: nil),
            mirrorSnapshotAck: AppliedPackageAckRef(
                generation: 444,
                contentDigest: "inline-manifest-digest",
                appliedAt: Date(timeIntervalSince1970: 1_732_000_446)
            ),
            standaloneProvisioningAck: nil,
            inlineMirrorSnapshot: inlinePayload,
            inlineStandaloneProvisioning: nil
        )

        let decoded = try #require(WatchSyncManifest.fromApplicationContext(manifest.applicationContext()))
        let decodedInlinePayload = try #require(decoded.inlineMirrorSnapshot)
        let decodedPackage = try #require(
            WatchConnectivityWire.decode(MirrorSnapshotPackage.self, from: decodedInlinePayload)
        )

        #expect(decoded == manifest)
        #expect(decodedPackage.manifest == package.manifest)
        #expect(decodedPackage.snapshot == package.snapshot)
    }

    @Test
    func manifestDecodeFailsWhenDictionaryFieldsMissingAndBlobUnavailable() {
        let manifest = makeManifest(
            mirrorPackageID: "mirror-missing",
            standalonePackageID: "standalone-missing"
        )
        var context = manifest.applicationContext()
        context.removeValue(forKey: "watch_manifest_blob")
        context.removeValue(forKey: "watch_manifest_mode")
        context.removeValue(forKey: "watch_manifest_control_generation")

        #expect(WatchSyncManifest.fromApplicationContext(context) == nil)
    }

    @Test
    func reliableEventRoundTripsThroughUserInfo() throws {
        let payload = try #require(WatchConnectivityWire.encode(["token": "abc123"]))
        let envelope = WatchEventEnvelope(
            eventID: "event-1",
            schemaVersion: WatchConnectivitySchema.currentVersion,
            createdAt: Date(timeIntervalSince1970: 1_732_000_123),
            kind: .pushTokenUpdate,
            payload: payload
        )

        let decoded = try #require(WatchEventEnvelope.fromUserInfo(envelope.userInfo()))
        #expect(decoded == envelope)
    }

    @Test
    func mirrorSnapshotInlineEventRoundTripsThroughReliableEvent() throws {
        let snapshot = WatchMirrorSnapshot(
            generation: 200,
            mode: .mirror,
            messages: [],
            events: [],
            things: [],
            exportedAt: Date(timeIntervalSince1970: 1_732_000_200),
            contentDigest: "mirror-inline-digest"
        )
        let package = MirrorSnapshotPackage(
            manifest: WatchTransferPackageManifest(
                schemaVersion: WatchConnectivitySchema.currentVersion,
                packageID: "mirror-inline-package",
                kind: .mirrorSnapshot,
                generation: 200,
                createdAt: Date(timeIntervalSince1970: 1_732_000_201)
            ),
            snapshot: snapshot
        )
        let payload = try #require(WatchConnectivityWire.encode(package))
        let envelope = WatchEventEnvelope(
            eventID: "event-mirror-inline-1",
            schemaVersion: WatchConnectivitySchema.currentVersion,
            createdAt: Date(timeIntervalSince1970: 1_732_000_202),
            kind: .mirrorSnapshotInline,
            payload: payload
        )

        let decodedEnvelope = try #require(WatchEventEnvelope.fromUserInfo(envelope.userInfo()))
        let decodedPackage = try #require(
            WatchConnectivityWire.decode(MirrorSnapshotPackage.self, from: decodedEnvelope.payload)
        )

        #expect(decodedEnvelope == envelope)
        #expect(decodedPackage.manifest == package.manifest)
        #expect(decodedPackage.snapshot == package.snapshot)
    }

    @Test
    func standaloneProvisioningInlineEventRoundTripsThroughReliableEvent() throws {
        let snapshot = WatchStandaloneProvisioningSnapshot(
            generation: 300,
            mode: .standalone,
            serverConfig: nil,
            notificationKeyMaterial: nil,
            channels: [],
            contentDigest: "standalone-inline-digest"
        )
        let package = StandaloneProvisioningPackage(
            manifest: WatchTransferPackageManifest(
                schemaVersion: WatchConnectivitySchema.currentVersion,
                packageID: "standalone-inline-package",
                kind: .standaloneProvisioning,
                generation: 300,
                createdAt: Date(timeIntervalSince1970: 1_732_000_301)
            ),
            snapshot: snapshot
        )
        let payload = try #require(WatchConnectivityWire.encode(package))
        let envelope = WatchEventEnvelope(
            eventID: "event-standalone-inline-1",
            schemaVersion: WatchConnectivitySchema.currentVersion,
            createdAt: Date(timeIntervalSince1970: 1_732_000_302),
            kind: .standaloneProvisioningInline,
            payload: payload
        )

        let decodedEnvelope = try #require(WatchEventEnvelope.fromUserInfo(envelope.userInfo()))
        let decodedPackage = try #require(
            WatchConnectivityWire.decode(StandaloneProvisioningPackage.self, from: decodedEnvelope.payload)
        )

        #expect(decodedEnvelope == envelope)
        #expect(decodedPackage.manifest == package.manifest)
        #expect(decodedPackage.snapshot.generation == package.snapshot.generation)
        #expect(decodedPackage.snapshot.contentDigest == package.snapshot.contentDigest)
        #expect(decodedPackage.snapshot.channels == package.snapshot.channels)
    }

    @Test
    func standaloneProvisioningDigestIgnoresGenerationAndChannelOrder() {
        let material = ServerConfig.NotificationKeyMaterial(
            algorithm: .aesGcm,
            keyData: Data([0x01, 0x02, 0x03, 0x04]),
            ivBase64: "iv-value",
            updatedAt: Date(timeIntervalSince1970: 1_732_000_777)
        )
        let serverConfig = ServerConfig(
            name: "Primary",
            baseURL: URL(string: "https://example.com/api/")!,
            token: "gateway-token",
            notificationKeyMaterial: material,
            updatedAt: Date(timeIntervalSince1970: 1_732_000_888)
        )
        let orderedChannels = [
            WatchStandaloneChannelCredential(
                gateway: "https://example.com/api",
                channelId: "alpha",
                displayName: "Alpha",
                password: "pw-a",
                updatedAt: Date(timeIntervalSince1970: 1_732_000_100)
            ),
            WatchStandaloneChannelCredential(
                gateway: "https://example.com/api",
                channelId: "beta",
                displayName: "Beta",
                password: "pw-b",
                updatedAt: Date(timeIntervalSince1970: 1_732_000_200)
            ),
        ]
        let reversedChannels = Array(orderedChannels.reversed())

        let digestA = WatchStandaloneProvisioningSnapshot.contentDigest(
            serverConfig: serverConfig,
            notificationKeyMaterial: material,
            channels: orderedChannels
        )
        let digestB = WatchStandaloneProvisioningSnapshot.contentDigest(
            serverConfig: serverConfig,
            notificationKeyMaterial: material,
            channels: reversedChannels
        )

        let snapshotA = WatchStandaloneProvisioningSnapshot(
            generation: 101,
            mode: .standalone,
            serverConfig: serverConfig,
            notificationKeyMaterial: material,
            channels: orderedChannels,
            contentDigest: digestA
        )
        let snapshotB = WatchStandaloneProvisioningSnapshot(
            generation: 202,
            mode: .standalone,
            serverConfig: serverConfig,
            notificationKeyMaterial: material,
            channels: reversedChannels,
            contentDigest: digestB
        )

        #expect(snapshotA.contentDigest == snapshotB.contentDigest)
    }

    @Test
    func standaloneProvisioningAckRoundTripsThroughReliableEvent() throws {
        let ack = WatchStandaloneProvisioningAck(
            generation: 77,
            contentDigest: "digest-77",
            appliedAt: Date(timeIntervalSince1970: 1_732_000_555)
        )
        let payload = try #require(WatchConnectivityWire.encode(ack))
        let envelope = WatchEventEnvelope(
            eventID: "event-ack-1",
            schemaVersion: WatchConnectivitySchema.currentVersion,
            createdAt: Date(timeIntervalSince1970: 1_732_000_556),
            kind: .standaloneProvisioningAck,
            payload: payload
        )

        let decodedEnvelope = try #require(WatchEventEnvelope.fromUserInfo(envelope.userInfo()))
        let decodedAck = try #require(
            WatchConnectivityWire.decode(WatchStandaloneProvisioningAck.self, from: decodedEnvelope.payload)
        )

        #expect(decodedEnvelope == envelope)
        #expect(decodedAck == ack)
    }

    @Test
    func mirrorSnapshotDigestIgnoresGenerationAndExportTime() {
        let messages = [
            WatchLightMessage(
                messageId: "msg-1",
                title: "CPU high",
                body: "Node overloaded",
                imageURL: URL(string: "https://example.com/msg-1.png"),
                url: URL(string: "https://example.com/msg-1"),
                severity: "high",
                receivedAt: Date(timeIntervalSince1970: 1_732_000_100),
                isRead: false,
                entityType: "message",
                entityId: "msg-1",
                notificationRequestId: "req-1"
            )
        ]
        let events = [
            WatchLightEvent(
                eventId: "evt-1",
                title: "Disk pressure",
                summary: "Node above threshold",
                state: "OPEN",
                severity: "critical",
                decryptionState: nil,
                imageURL: URL(string: "https://example.com/evt-1.png"),
                updatedAt: Date(timeIntervalSince1970: 1_732_000_101)
            )
        ]
        let things = [
            WatchLightThing(
                thingId: "thing-1",
                title: "Router",
                summary: "Core router",
                attrsJSON: #"{"role":"edge"}"#,
                decryptionState: nil,
                imageURL: URL(string: "https://example.com/thing-1.png"),
                updatedAt: Date(timeIntervalSince1970: 1_732_000_102)
            )
        ]

        let digestA = WatchMirrorSnapshot.contentDigest(messages: messages, events: events, things: things)
        let digestB = WatchMirrorSnapshot.contentDigest(messages: messages, events: events, things: things)

        let snapshotA = WatchMirrorSnapshot(
            generation: 1,
            mode: .mirror,
            messages: messages,
            events: events,
            things: things,
            exportedAt: Date(timeIntervalSince1970: 1_732_000_200),
            contentDigest: digestA
        )
        let snapshotB = WatchMirrorSnapshot(
            generation: 99,
            mode: .mirror,
            messages: messages,
            events: events,
            things: things,
            exportedAt: Date(timeIntervalSince1970: 1_732_000_300),
            contentDigest: digestB
        )

        #expect(snapshotA.contentDigest == snapshotB.contentDigest)
    }

    @Test
    func mirrorSnapshotAckRoundTripsThroughReliableEvent() throws {
        let ack = WatchMirrorSnapshotAck(
            generation: 55,
            contentDigest: "mirror-digest-55",
            appliedAt: Date(timeIntervalSince1970: 1_732_000_559)
        )
        let payload = try #require(WatchConnectivityWire.encode(ack))
        let envelope = WatchEventEnvelope(
            eventID: "event-mirror-ack-1",
            schemaVersion: WatchConnectivitySchema.currentVersion,
            createdAt: Date(timeIntervalSince1970: 1_732_000_560),
            kind: .mirrorSnapshotAck,
            payload: payload
        )

        let decodedEnvelope = try #require(WatchEventEnvelope.fromUserInfo(envelope.userInfo()))
        let decodedAck = try #require(
            WatchConnectivityWire.decode(WatchMirrorSnapshotAck.self, from: decodedEnvelope.payload)
        )

        #expect(decodedEnvelope == envelope)
        #expect(decodedAck == ack)
    }

    @Test
    func mirrorSnapshotNackRoundTripsThroughReliableEvent() throws {
        let nack = WatchMirrorSnapshotNack(
            generation: 56,
            contentDigest: "mirror-digest-56",
            failedStage: "replace_watch_mirror_snapshot",
            errorDescription: "database busy",
            reportedAt: Date(timeIntervalSince1970: 1_732_000_561)
        )
        let payload = try #require(WatchConnectivityWire.encode(nack))
        let envelope = WatchEventEnvelope(
            eventID: "event-mirror-nack-1",
            schemaVersion: WatchConnectivitySchema.currentVersion,
            createdAt: Date(timeIntervalSince1970: 1_732_000_562),
            kind: .mirrorSnapshotNack,
            payload: payload
        )

        let decodedEnvelope = try #require(WatchEventEnvelope.fromUserInfo(envelope.userInfo()))
        let decodedNack = try #require(
            WatchConnectivityWire.decode(WatchMirrorSnapshotNack.self, from: decodedEnvelope.payload)
        )

        #expect(decodedEnvelope == envelope)
        #expect(decodedNack == nack)
    }

    @Test
    func standaloneProvisioningNackRoundTripsThroughReliableEvent() throws {
        let nack = WatchStandaloneProvisioningNack(
            generation: 78,
            contentDigest: "digest-78",
            failedStage: "sync_subscriptions",
            errorDescription: "unauthorized",
            reportedAt: Date(timeIntervalSince1970: 1_732_000_557)
        )
        let payload = try #require(WatchConnectivityWire.encode(nack))
        let envelope = WatchEventEnvelope(
            eventID: "event-nack-1",
            schemaVersion: WatchConnectivitySchema.currentVersion,
            createdAt: Date(timeIntervalSince1970: 1_732_000_558),
            kind: .standaloneProvisioningNack,
            payload: payload
        )

        let decodedEnvelope = try #require(WatchEventEnvelope.fromUserInfo(envelope.userInfo()))
        let decodedNack = try #require(
            WatchConnectivityWire.decode(WatchStandaloneProvisioningNack.self, from: decodedEnvelope.payload)
        )

        #expect(decodedEnvelope == envelope)
        #expect(decodedNack == nack)
    }

    @Test
    func transferMetadataRoundTrips() throws {
        let manifest = WatchTransferPackageManifest(
            schemaVersion: WatchConnectivitySchema.currentVersion,
            packageID: "package-1",
            kind: .mirrorSnapshot,
            generation: 77,
            createdAt: Date(timeIntervalSince1970: 1_732_000_456)
        )

        let decoded = try #require(WatchTransferPackageManifest.fromMetadata(manifest.metadataDictionary()))
        #expect(decoded.schemaVersion == manifest.schemaVersion)
        #expect(decoded.packageID == manifest.packageID)
        #expect(decoded.kind == manifest.kind)
        #expect(decoded.generation == manifest.generation)
    }

    @Test
    func transferPolicyRetainsCurrentPackageInNonAutomationMode() {
        let createdAt = Date(timeIntervalSince1970: 1_732_010_000)
        let manifest = makeManifest(
            mirrorPackageID: "mirror-current",
            standalonePackageID: "standalone-current"
        )
        let metadata = WatchTransferPackageManifest(
            schemaVersion: WatchConnectivitySchema.currentVersion,
            packageID: "mirror-current",
            kind: .mirrorSnapshot,
            generation: 10,
            createdAt: createdAt
        )

        let shouldRetain = WatchConnectivityTransferPolicy.shouldRetainOutstandingTransfer(
            metadata: metadata,
            transferFileURL: URL(fileURLWithPath: "/tmp/source.json"),
            manifest: manifest,
            automationActive: false,
            transferStagingRootURL: URL(fileURLWithPath: "/tmp/staging", isDirectory: true),
            fileExists: true,
            now: createdAt.addingTimeInterval(1)
        )

        #expect(shouldRetain)
    }

    @Test
    func transferPolicyDropsMismatchedOrMissingPackage() {
        let manifest = makeManifest(
            mirrorPackageID: "mirror-current",
            standalonePackageID: "standalone-current"
        )
        let staleMetadata = WatchTransferPackageManifest(
            schemaVersion: WatchConnectivitySchema.currentVersion,
            packageID: "mirror-stale",
            kind: .mirrorSnapshot,
            generation: 9,
            createdAt: Date(timeIntervalSince1970: 1_732_010_100)
        )

        let staleDecision = WatchConnectivityTransferPolicy.shouldRetainOutstandingTransfer(
            metadata: staleMetadata,
            transferFileURL: URL(fileURLWithPath: "/tmp/source.json"),
            manifest: manifest,
            automationActive: false,
            transferStagingRootURL: URL(fileURLWithPath: "/tmp/staging", isDirectory: true),
            fileExists: true
        )
        let missingMetadataDecision = WatchConnectivityTransferPolicy.shouldRetainOutstandingTransfer(
            metadata: nil,
            transferFileURL: URL(fileURLWithPath: "/tmp/source.json"),
            manifest: manifest,
            automationActive: false,
            transferStagingRootURL: URL(fileURLWithPath: "/tmp/staging", isDirectory: true),
            fileExists: true
        )

        #expect(staleDecision == false)
        #expect(missingMetadataDecision == false)
    }

    @Test
    func transferPolicyRetainsAutomationTransfersEvenWhenWCSessionRelocatesFileURL() {
        let createdAt = Date(timeIntervalSince1970: 1_732_010_200)
        let manifest = makeManifest(
            mirrorPackageID: "mirror-current",
            standalonePackageID: "standalone-current"
        )
        let metadata = WatchTransferPackageManifest(
            schemaVersion: WatchConnectivitySchema.currentVersion,
            packageID: "mirror-current",
            kind: .mirrorSnapshot,
            generation: 10,
            createdAt: createdAt
        )
        let stagingRoot = URL(fileURLWithPath: "/tmp/pushgo-watch-connectivity-transfer", isDirectory: true)
        let stagedFile = stagingRoot.appendingPathComponent("mirror-current.json")
        let rawOutboxFile = URL(fileURLWithPath: "/private/tmp/pushgo-phone-runtime/outbox/mirror-current.json")

        let stagedDecision = WatchConnectivityTransferPolicy.shouldRetainOutstandingTransfer(
            metadata: metadata,
            transferFileURL: stagedFile,
            manifest: manifest,
            automationActive: true,
            transferStagingRootURL: stagingRoot,
            fileExists: true,
            now: createdAt.addingTimeInterval(1)
        )
        let rawOutboxDecision = WatchConnectivityTransferPolicy.shouldRetainOutstandingTransfer(
            metadata: metadata,
            transferFileURL: rawOutboxFile,
            manifest: manifest,
            automationActive: true,
            transferStagingRootURL: stagingRoot,
            fileExists: true,
            now: createdAt.addingTimeInterval(1)
        )

        #expect(stagedDecision)
        #expect(rawOutboxDecision)
    }

    @Test
    func manifestPublishSignatureMatchesEquivalentManifestsAndDiffersAcrossChanges() {
        let baseManifest = makeManifest(
            mirrorPackageID: "mirror-current",
            standalonePackageID: "standalone-current"
        )
        let sameManifest = makeManifest(
            mirrorPackageID: "mirror-current",
            standalonePackageID: "standalone-current"
        )
        let changedManifest = WatchSyncManifest(
            schemaVersion: baseManifest.schemaVersion,
            mode: baseManifest.mode,
            controlGeneration: baseManifest.controlGeneration + 1,
            mirrorPackage: baseManifest.mirrorPackage,
            standalonePackage: baseManifest.standalonePackage,
            ackCursor: baseManifest.ackCursor,
            mirrorSnapshotAck: baseManifest.mirrorSnapshotAck,
            standaloneProvisioningAck: baseManifest.standaloneProvisioningAck,
            inlineMirrorSnapshot: nil,
            inlineStandaloneProvisioning: nil
        )

        let baseSignature = WatchConnectivityManifestPublishPolicy.signature(for: baseManifest)
        let sameSignature = WatchConnectivityManifestPublishPolicy.signature(for: sameManifest)
        let changedSignature = WatchConnectivityManifestPublishPolicy.signature(for: changedManifest)

        #expect(baseSignature == sameSignature)
        #expect(baseSignature != changedSignature)
    }

    @Test
    func transferPolicyDropsMissingFile() {
        let manifest = makeManifest(
            mirrorPackageID: "mirror-current",
            standalonePackageID: "standalone-current"
        )
        let metadata = WatchTransferPackageManifest(
            schemaVersion: WatchConnectivitySchema.currentVersion,
            packageID: "standalone-current",
            kind: .standaloneProvisioning,
            generation: 20,
            createdAt: Date(timeIntervalSince1970: 1_732_010_300)
        )

        let shouldRetain = WatchConnectivityTransferPolicy.shouldRetainOutstandingTransfer(
            metadata: metadata,
            transferFileURL: URL(fileURLWithPath: "/tmp/missing.json"),
            manifest: manifest,
            automationActive: false,
            transferStagingRootURL: URL(fileURLWithPath: "/tmp/staging", isDirectory: true),
            fileExists: false
        )

        #expect(shouldRetain == false)
    }

    @Test
    func transferPolicyDropsStaleOutstandingTransferSoReplayCanRequeue() {
        let createdAt = Date(timeIntervalSince1970: 1_732_010_400)
        let manifest = WatchSyncManifest(
            schemaVersion: WatchConnectivitySchema.currentVersion,
            mode: .mirror,
            controlGeneration: 200,
            mirrorPackage: MirrorPackageRef(
                packageID: "mirror-current",
                generation: 200,
                createdAt: createdAt
            ),
            standalonePackage: nil,
            ackCursor: AckCursorRef(generation: 0, lastEventID: nil),
            mirrorSnapshotAck: nil,
            standaloneProvisioningAck: nil,
            inlineMirrorSnapshot: nil,
            inlineStandaloneProvisioning: nil
        )
        let metadata = WatchTransferPackageManifest(
            schemaVersion: WatchConnectivitySchema.currentVersion,
            packageID: "mirror-current",
            kind: .mirrorSnapshot,
            generation: 200,
            createdAt: createdAt
        )

        let shouldRetain = WatchConnectivityTransferPolicy.shouldRetainOutstandingTransfer(
            metadata: metadata,
            transferFileURL: URL(fileURLWithPath: "/tmp/source.json"),
            manifest: manifest,
            automationActive: true,
            transferStagingRootURL: URL(fileURLWithPath: "/tmp/staging", isDirectory: true),
            fileExists: true,
            now: createdAt.addingTimeInterval(11)
        )

        #expect(shouldRetain == false)
    }

#if os(iOS) || os(watchOS)
    @Test
    func runtimeStoreReceivedManifestDoesNotOverrideOutboundManifest() async {
        let runtime = WatchConnectivityRuntime(role: .phone)
        await runtime.clearAllState()

        let outbound = await runtime.updateManifest(
            mode: .standalone,
            controlGeneration: 777,
            ackCursor: AckCursorRef(generation: 777, lastEventID: "ack-777")
        )
        let incoming = makeManifest(
            mirrorPackageID: "mirror-incoming",
            standalonePackageID: "standalone-incoming"
        )

        await runtime.storeReceivedManifest(incoming)
        let current = await runtime.currentManifest()

        #expect(current == outbound)
        await runtime.clearAllState()
    }
#endif

    private func makeManifest(
        mirrorPackageID: String,
        standalonePackageID: String
    ) -> WatchSyncManifest {
        let createdAt = Date(timeIntervalSince1970: 1_732_010_999)
        return WatchSyncManifest(
            schemaVersion: WatchConnectivitySchema.currentVersion,
            mode: .standalone,
            controlGeneration: 1,
            mirrorPackage: MirrorPackageRef(
                packageID: mirrorPackageID,
                generation: 1,
                createdAt: createdAt
            ),
            standalonePackage: StandalonePackageRef(
                packageID: standalonePackageID,
                generation: 1,
                createdAt: createdAt
            ),
            ackCursor: nil,
            mirrorSnapshotAck: nil,
            standaloneProvisioningAck: nil,
            inlineMirrorSnapshot: nil,
            inlineStandaloneProvisioning: nil
        )
    }
}
