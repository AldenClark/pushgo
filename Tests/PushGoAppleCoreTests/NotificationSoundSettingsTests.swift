import AudioToolbox
import Darwin
import Foundation
import Testing
@testable import PushGoAppleCore

@Suite(.serialized)
struct NotificationSoundSettingsTests {
    @Test
    func defaultRulesMatchPrioritySoundPolicy() {
        let settings = NotificationSoundSettings()

        #if os(macOS)
        for level in [NotificationSoundLevel.critical, .high, .normal] {
            let rule = settings.rule(for: level)
            #expect(rule.mode == .systemDefault)
            #expect(rule.builtinSoundID == nil)
            #expect(rule.durationSeconds == nil)
            #expect(rule.gain == 1)
        }

        let low = settings.rule(for: .low)
        #expect(low.mode == .silent)
        #expect(low.builtinSoundID == nil)
        #expect(low.durationSeconds == nil)
        #expect(low.gain == 1)
        #else
        let critical = settings.rule(for: .critical)
        #expect(critical.mode == .builtin)
        #expect(critical.builtinSoundID == "alert")
        #expect(critical.durationSeconds == 30)
        #expect(critical.gain == 1)

        let high = settings.rule(for: .high)
        #expect(high.mode == .builtin)
        #expect(high.builtinSoundID == "notification-sound")
        #expect(high.durationSeconds == 10)
        #expect(high.gain == 0.8)

        let normal = settings.rule(for: .normal)
        #expect(normal.mode == .builtin)
        #expect(normal.builtinSoundID == "bubble-pop")
        #expect(normal.durationSeconds == nil)
        #expect(normal.gain == 0.5)

        let low = settings.rule(for: .low)
        #expect(low.mode == .silent)
        #expect(low.builtinSoundID == nil)
        #endif
    }

    #if os(macOS)
    @Test
    func macOSResolverTrustsPersistedCompiledFilenameWithoutDirectoryAccess() {
        var settings = NotificationSoundSettings()
        var normal = settings.rule(for: .normal)
        normal.mode = .builtin
        normal.builtinSoundID = "bubble-pop"
        normal.compiledFilename = "pushgo-normal.caf"
        settings.rules[.normal] = normal

        let resolved = NotificationSoundResolver.resolve(for: .normal, settings: settings)

        #expect(resolved?.filename == "pushgo-normal.caf")
        #expect(resolved?.usesSystemDefault == false)
    }

    @Test
    func effectiveSettingsManifestRoundTripsThroughAppGroupStorage() async throws {
        try await withIsolatedAutomationStorage { root, appGroupIdentifier in
            defer {
                try? FileManager.default.removeItem(at: root)
            }
            var settings = NotificationSoundSettings()
            var high = settings.rule(for: .high)
            high.mode = .builtin
            high.builtinSoundID = "notification-sound"
            high.compiledFilename = "pushgo-high.caf"
            high.durationSeconds = 10
            high.gain = 0.8
            settings.rules[.high] = high

            try NotificationSoundSharedState.saveEffectiveSettingsManifest(
                settings,
                appGroupIdentifier: appGroupIdentifier
            )

            let restored = NotificationSoundSharedState.loadEffectiveSettingsManifest(
                appGroupIdentifier: appGroupIdentifier
            )?.settings
            #expect(restored?.rule(for: .high).mode == .builtin)
            #expect(restored?.rule(for: .high).compiledFilename == "pushgo-high.caf")
            #expect(restored?.rule(for: .high).gain == 0.8)
        }
    }

    @Test
    func lowPriorityDefaultsToSilentResolution() {
        let resolved = NotificationSoundResolver.resolve(for: .low, settings: nil)

        #expect(resolved == nil)
    }

    @Test
    func resolverDoesNotTreatNonLowSilentRulesAsSilentNotifications() {
        var settings = NotificationSoundSettings()
        var high = settings.rule(for: .high)
        high.mode = .silent
        settings.rules[.high] = high

        let resolved = NotificationSoundResolver.resolve(for: .high, settings: settings)

        #if os(macOS)
        #expect(resolved?.usesSystemDefault == true)
        #else
        #expect(resolved?.filename == "notification-sound.caf")
        #endif
    }
    #endif

    @Test
    func compilerWritesCAFLPCM16BitStereo() throws {
        let sourceURL = sourceRoot
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("Sounds", isDirectory: true)
            .appendingPathComponent("bubble-pop.caf", isDirectory: false)
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pushgo-sound-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: outputDirectory)
        }
        let outputURL = outputDirectory.appendingPathComponent("pushgo-normal.caf", isDirectory: false)

        try NotificationSoundCompiler().compile(
            from: sourceURL,
            to: outputURL,
            targetDurationSeconds: 1,
            gain: 1
        )

        var audioFile: AudioFileID?
        #expect(AudioFileOpenURL(outputURL as CFURL, .readPermission, 0, &audioFile) == noErr)
        guard let audioFile else {
            Issue.record("Compiled CAF could not be opened.")
            return
        }
        defer {
            AudioFileClose(audioFile)
        }

        var fileType = AudioFileTypeID(0)
        var fileTypeSize = UInt32(MemoryLayout<AudioFileTypeID>.size)
        #expect(AudioFileGetProperty(audioFile, kAudioFilePropertyFileFormat, &fileTypeSize, &fileType) == noErr)
        #expect(fileType == kAudioFileCAFType)

        var dataFormat = AudioStreamBasicDescription()
        var dataFormatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        #expect(AudioFileGetProperty(audioFile, kAudioFilePropertyDataFormat, &dataFormatSize, &dataFormat) == noErr)
        #expect(dataFormat.mFormatID == kAudioFormatLinearPCM)
        #expect(dataFormat.mSampleRate == 48_000)
        #expect(dataFormat.mChannelsPerFrame == 2)
        #expect(dataFormat.mBitsPerChannel == 16)
        #expect(dataFormat.mBytesPerPacket == 4)
        #expect(dataFormat.mBytesPerFrame == 4)
        #expect(dataFormat.mFramesPerPacket == 1)
        #expect(dataFormat.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0)
        #expect(dataFormat.mFormatFlags & kAudioFormatFlagIsFloat == 0)

        var packetCount: Int64 = 0
        var packetCountSize = UInt32(MemoryLayout<Int64>.size)
        #expect(AudioFileGetProperty(audioFile, kAudioFilePropertyAudioDataPacketCount, &packetCountSize, &packetCount) == noErr)
        #expect(packetCount == 48_000)
    }

    private var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

}
