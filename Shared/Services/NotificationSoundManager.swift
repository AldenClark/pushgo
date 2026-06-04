import AVFoundation
import AudioToolbox
import CryptoKit
import Foundation

enum NotificationSoundManagerError: LocalizedError {
    case unreadableAudio
    case emptyAudio
    case audioTooLarge(maxBytes: Int64)
    case sourceMissing
    case unsupportedSelection

    var errorDescription: String? {
        switch self {
        case .unreadableAudio:
            return "PushGo could not read this audio file."
        case .emptyAudio:
            return "The selected audio file is empty."
        case let .audioTooLarge(maxBytes):
            return "The selected audio file is too large. Maximum supported size is \(maxBytes / 1_048_576) MB."
        case .sourceMissing:
            return "The selected sound source is no longer available."
        case .unsupportedSelection:
            return "Please select a valid sound source first."
        }
    }
}

struct NotificationSoundSourceMetadata: Sendable {
    let durationSeconds: Double
    let fileSizeBytes: Int64
    let sha256Hex: String?
}

private struct NotificationSoundSourceDescriptor: Sendable {
    let identifier: String
    let filename: String
    let url: URL
    let naturalDurationSeconds: Double
}

struct NotificationSoundCompiler {
    static let outputFormatVersion = "caf-lpcm-i16-stereo-48k-v1"
    static let maxImportBytes: Int64 = 50 * 1_048_576
    static let minimumDurationSeconds = 0.5
    static let maximumDurationSeconds = 30.0
    static let minimumGain = 0.2
    static let maximumGain = 1.0
    private static let outputSampleRate = 48_000.0
    private static let outputChannelCount: AVAudioChannelCount = 2

    func sourceMetadata(for url: URL) throws -> NotificationSoundSourceMetadata {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard fileSize > 0 else { throw NotificationSoundManagerError.emptyAudio }
        guard fileSize <= Self.maxImportBytes else {
            throw NotificationSoundManagerError.audioTooLarge(maxBytes: Self.maxImportBytes)
        }

        let file = try AVAudioFile(forReading: url)
        let sampleRate = file.processingFormat.sampleRate
        let frameLength = Double(file.length)
        guard sampleRate > 0, frameLength > 0 else {
            throw NotificationSoundManagerError.unreadableAudio
        }

        let duration = frameLength / sampleRate
        let sha256Hex = try? sha256(for: url)
        return NotificationSoundSourceMetadata(
            durationSeconds: duration,
            fileSizeBytes: fileSize,
            sha256Hex: sha256Hex
        )
    }

    func compile(
        from sourceURL: URL,
        to destinationURL: URL,
        targetDurationSeconds: Double,
        gain: Double
    ) throws {
        let sourceFile = try AVAudioFile(forReading: sourceURL)
        let sourceFormat = sourceFile.processingFormat
        let sampleRate = sourceFormat.sampleRate
        let channelCount = Int(sourceFormat.channelCount)
        let sourceFrameCount = AVAudioFrameCount(min(Double(sourceFile.length), sampleRate * Self.maximumDurationSeconds))
        guard sourceFrameCount > 0, channelCount > 0 else {
            throw NotificationSoundManagerError.unreadableAudio
        }

        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: sourceFrameCount
        ) else {
            throw NotificationSoundManagerError.unreadableAudio
        }
        try sourceFile.read(into: sourceBuffer, frameCount: sourceFrameCount)
        guard sourceBuffer.frameLength > 0 else {
            throw NotificationSoundManagerError.emptyAudio
        }
        guard let floatChannelData = sourceBuffer.floatChannelData else {
            throw NotificationSoundManagerError.unreadableAudio
        }

        let clampedDuration = min(max(targetDurationSeconds, Self.minimumDurationSeconds), Self.maximumDurationSeconds)
        let targetFrameLength = AVAudioFrameCount((Self.outputSampleRate * clampedDuration).rounded())
        let outputFormat = Self.outputProcessingFormat()
        guard let outputFormat,
              let outputBuffer = AVAudioPCMBuffer(
                  pcmFormat: outputFormat,
                  frameCapacity: targetFrameLength
              )
        else {
            throw NotificationSoundManagerError.unreadableAudio
        }

        let normalizedGain = min(max(gain, Self.minimumGain), Self.maximumGain)
        let sourceFrames = Int(sourceBuffer.frameLength)
        let sourceChannels = UnsafeBufferPointer(start: floatChannelData, count: channelCount)
        guard let outputChannel = outputBuffer.floatChannelData?[0] else {
            throw NotificationSoundManagerError.unreadableAudio
        }
        for frame in 0..<Int(targetFrameLength) {
            outputChannel[frame] = resampledMixedSample(
                frame: frame,
                sourceSampleRate: sampleRate,
                sourceFrames: sourceFrames,
                sourceChannels: sourceChannels,
                channelCount: channelCount,
                gain: normalizedGain
            )
        }
        if Self.outputChannelCount > 1,
           let secondOutputChannel = outputBuffer.floatChannelData?[1]
        {
            memcpy(secondOutputChannel, outputChannel, Int(targetFrameLength) * MemoryLayout<Float>.size)
        }
        outputBuffer.frameLength = targetFrameLength

        let tempURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.deletingPathExtension().lastPathComponent).tmp-\(UUID().uuidString.lowercased()).\(destinationURL.pathExtension)")
        do {
            try writeCAF(buffer: outputBuffer, to: tempURL)
        }

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: tempURL, to: destinationURL)
        NotificationSoundStorage.removeExtendedAttribute("com.apple.quarantine", from: destinationURL)
    }

    private func resampledMixedSample(
        frame: Int,
        sourceSampleRate: Double,
        sourceFrames: Int,
        sourceChannels: UnsafeBufferPointer<UnsafeMutablePointer<Float>>,
        channelCount: Int,
        gain: Double
    ) -> Float {
        let sourcePosition = (Double(frame) * sourceSampleRate / Self.outputSampleRate)
            .truncatingRemainder(dividingBy: Double(sourceFrames))
        let lowerIndex = Int(sourcePosition)
        let upperIndex = (lowerIndex + 1) % sourceFrames
        let interpolation = Float(sourcePosition - Double(lowerIndex))
        var mixed: Float = 0
        for channel in 0..<channelCount {
            let lower = sourceChannels[channel][lowerIndex]
            let upper = sourceChannels[channel][upperIndex]
            mixed += lower + ((upper - lower) * interpolation)
        }
        let averaged = mixed / Float(channelCount)
        return max(-1, min(1, averaged * Float(gain)))
    }

    private static func outputProcessingFormat() -> AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: outputSampleRate,
            channels: outputChannelCount,
            interleaved: false
        )
    }

    private func writeCAF(buffer: AVAudioPCMBuffer, to destinationURL: URL) throws {
        guard let channelData = buffer.floatChannelData else {
            throw NotificationSoundManagerError.unreadableAudio
        }

        var fileFormat = Self.outputFileFormatDescription()
        var audioFile: ExtAudioFileRef?
        try checkAudioToolboxStatus(
            ExtAudioFileCreateWithURL(
                destinationURL as CFURL,
                kAudioFileCAFType,
                &fileFormat,
                nil,
                AudioFileFlags.eraseFile.rawValue,
                &audioFile
            ),
            operation: "create CAF file"
        )
        guard let audioFile else {
            throw NotificationSoundManagerError.unreadableAudio
        }
        defer {
            ExtAudioFileDispose(audioFile)
        }

        var clientFormat = Self.outputClientFormatDescription()
        try checkAudioToolboxStatus(
            ExtAudioFileSetProperty(
                audioFile,
                kExtAudioFileProperty_ClientDataFormat,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
                &clientFormat
            ),
            operation: "configure CAF client format"
        )

        let frameCount = UInt32(buffer.frameLength)
        let channelCount = Int(Self.outputChannelCount)
        let channelByteCount = UInt32(Int(buffer.frameLength) * MemoryLayout<Float>.size)
        let audioBufferList = AudioBufferList.allocate(maximumBuffers: channelCount)
        defer {
            free(audioBufferList.unsafeMutablePointer)
        }
        audioBufferList.count = channelCount
        for channel in 0..<channelCount {
            audioBufferList[channel] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: channelByteCount,
                mData: channelData[channel]
            )
        }

        try checkAudioToolboxStatus(
            ExtAudioFileWrite(audioFile, frameCount, audioBufferList.unsafePointer),
            operation: "write AIFF audio"
        )
    }

    private static func outputFileFormatDescription() -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: outputSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: outputChannelCount,
            mBitsPerChannel: 16,
            mReserved: 0
        )
    }

    private static func outputClientFormatDescription() -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: outputSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: outputChannelCount,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }

    private func checkAudioToolboxStatus(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw NSError(
                domain: "io.ethan.pushgo.notification-sound.audio-toolbox",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "\(operation) failed with status \(status)."]
            )
        }
    }

    private func sha256(for url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

actor NotificationSoundManager {
    static let shared = NotificationSoundManager()

    private let compiler = NotificationSoundCompiler()
    private let fileManager = FileManager.default

    func loadSettings() async -> NotificationSoundSettings {
        let stored = NotificationSoundSharedState.loadSettings()
            ?? NotificationSoundSharedState.loadEffectiveSettingsManifest(fileManager: fileManager)?.settings
        do {
            let normalized = try normalizedSettings(from: stored ?? NotificationSoundSettings())
            if normalized != stored {
                try? saveSettingsAndManifest(normalized)
            }
            return normalized
        } catch {
            return NotificationSoundSettings()
        }
    }

    func importCustomSound(from externalURL: URL) async throws -> NotificationSoundSettings {
        var settings = await loadSettings()
        let metadata = try compiler.sourceMetadata(for: externalURL)
        let hash = metadata.sha256Hex ?? UUID().uuidString.lowercased()
        if let existingIndex = settings.customAssets.firstIndex(where: { $0.sha256Hex == hash }) {
            let existing = settings.customAssets.remove(at: existingIndex)
            settings.customAssets.insert(existing, at: 0)
            settings.updatedAt = Date()
            try saveSettingsAndManifest(settings)
            return settings
        }

        let assetID = UUID().uuidString.lowercased()
        let ext = sanitizedExtension(for: externalURL)
        let originalFilename = "\(assetID).\(ext)"
        let originalsDirectory = try NotificationSoundStorage.appGroupOriginalsDirectory(fileManager: fileManager)
        let destinationURL = originalsDirectory.appendingPathComponent(originalFilename, isDirectory: false)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: externalURL, to: destinationURL)
        NotificationSoundStorage.removeExtendedAttribute("com.apple.quarantine", from: destinationURL)

        let displayName = externalURL.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let asset = NotificationCustomSoundAsset(
            id: assetID,
            displayName: displayName.isEmpty ? "Imported Sound" : displayName,
            originalFilename: originalFilename,
            importedAt: Date(),
            sourceDurationSeconds: metadata.durationSeconds,
            sourceFileSizeBytes: metadata.fileSizeBytes,
            sha256Hex: hash
        )
        settings.customAssets.insert(asset, at: 0)
        settings.updatedAt = Date()
        try saveSettingsAndManifest(settings)
        return settings
    }

    func persistSettings(_ draft: NotificationSoundSettings) async throws -> NotificationSoundSettings {
        let normalized = try normalizedSettings(from: draft)
        try saveSettingsAndManifest(normalized)
        return normalized
    }

    func previewURL(
        for level: NotificationSoundLevel,
        settings: NotificationSoundSettings
    ) async -> URL? {
        let rule = settings.rule(for: level)
        if let filename = rule.compiledFilename,
           let compiledSoundsDirectory = try? NotificationSoundStorage.compiledSoundsDirectory(fileManager: fileManager)
        {
            let compiledURL = compiledSoundsDirectory.appendingPathComponent(filename, isDirectory: false)
            if fileManager.fileExists(atPath: compiledURL.path) {
                return compiledURL
            }
        }
        switch rule.mode {
        case .systemDefault:
            return nil
        case .silent:
            return nil
        case .builtin:
            let builtin = NotificationBuiltinSoundCatalog.sound(id: rule.builtinSoundID ?? level.defaultBuiltinSoundID)
            return builtin.flatMap { builtinURL(for: $0) }
        case .custom:
            guard let asset = settings.customAsset(id: rule.customAssetID),
                  let originalsDirectory = try? NotificationSoundStorage.appGroupOriginalsDirectory(fileManager: fileManager)
            else {
                return nil
            }
            let originalURL = originalsDirectory.appendingPathComponent(asset.originalFilename, isDirectory: false)
            return fileManager.fileExists(atPath: originalURL.path) ? originalURL : nil
        }
    }

    func previewBuiltinSoundURL(soundID: String) async -> URL? {
        guard let sound = NotificationBuiltinSoundCatalog.sound(id: soundID) else {
            return nil
        }
        return builtinURL(for: sound)
    }

    func previewCustomSoundURL(
        assetID: String,
        settings: NotificationSoundSettings
    ) async -> URL? {
        guard let asset = settings.customAsset(id: assetID),
              let originalsDirectory = try? NotificationSoundStorage.appGroupOriginalsDirectory(fileManager: fileManager)
        else {
            return nil
        }
        let originalURL = originalsDirectory.appendingPathComponent(asset.originalFilename, isDirectory: false)
        return fileManager.fileExists(atPath: originalURL.path) ? originalURL : nil
    }

    func removeCustomSound(assetID: String) async throws -> NotificationSoundSettings {
        var settings = await loadSettings()
        settings.customAssets.removeAll { $0.id == assetID }
        for level in NotificationSoundLevel.allCases {
            var rule = settings.rule(for: level)
            if rule.customAssetID == assetID {
                rule = fallbackRuleAfterRemovingCustomSound(for: level)
                rule.updatedAt = Date()
                settings.rules[level] = rule
            }
        }
        let normalized = try normalizedSettings(from: settings)
        if let originalsDirectory = try? NotificationSoundStorage.appGroupOriginalsDirectory(fileManager: fileManager) {
            let candidateFiles = try? fileManager.contentsOfDirectory(at: originalsDirectory, includingPropertiesForKeys: nil)
            let usedNames = Set(normalized.customAssets.map(\.originalFilename))
            candidateFiles?.forEach { url in
                if !usedNames.contains(url.lastPathComponent) {
                    try? fileManager.removeItem(at: url)
                }
            }
        }
        try saveSettingsAndManifest(normalized)
        return normalized
    }

    func reconcileCompiledSounds() async {
        do {
            let settings = NotificationSoundSharedState.loadSettings()
                ?? NotificationSoundSharedState.loadEffectiveSettingsManifest(fileManager: fileManager)?.settings
                ?? NotificationSoundSettings()
            let normalized = try normalizedSettings(from: settings)
            try saveSettingsAndManifest(normalized)
        } catch {
            return
        }
    }

    #if os(macOS)
    func hasMacOSUserSoundsDirectoryAccess() async -> Bool {
        NotificationSoundStorage.hasMacOSUserSoundsDirectoryAccess(fileManager: fileManager)
    }

    func authorizeMacOSUserSoundsDirectory(_ directoryURL: URL) async throws {
        try NotificationSoundStorage.saveMacOSUserSoundsBookmark(for: directoryURL)
    }

    func macOSUserSoundsDirectoryURL() async -> URL {
        NotificationSoundStorage.macOSUserSoundsDirectoryURL(fileManager: fileManager)
    }
    #endif

    private func normalizedSettings(from draft: NotificationSoundSettings) throws -> NotificationSoundSettings {
        var settings = draft
        settings.schemaVersion = NotificationSoundSettings.schemaVersion
        settings.updatedAt = Date()
        settings.customAssets.sort { $0.importedAt > $1.importedAt }

        struct CompilationRequest {
            let level: NotificationSoundLevel
            var rule: NotificationSoundRule
            let sourceURL: URL
            let durationSeconds: Double
            let compilationToken: String
            let compiledFilename: String
        }

        var compilationRequests: [CompilationRequest] = []
        var referencedCompiledFilenames = Set<String>()
        for level in NotificationSoundLevel.allCases {
            var rule = settings.rule(for: level)
            if rule.mode == .silent, level != .low {
                rule = .default(for: level)
            }
            rule.gain = min(max(rule.gain, NotificationSoundCompiler.minimumGain), NotificationSoundCompiler.maximumGain)

            guard let source = try resolvedSource(for: level, rule: rule, settings: settings) else {
                rule.compiledFilename = nil
                rule.compilationToken = nil
                rule.customAssetID = nil
                if rule.mode == .systemDefault {
                    rule.builtinSoundID = nil
                    rule.durationSeconds = nil
                    rule.gain = 1
                }
                rule.updatedAt = Date()
                settings.rules[level] = rule
                continue
            }

            let naturalDuration = min(source.naturalDurationSeconds, NotificationSoundCompiler.maximumDurationSeconds)
            let normalizedDuration = min(
                max(rule.durationSeconds ?? naturalDuration, NotificationSoundCompiler.minimumDurationSeconds),
                NotificationSoundCompiler.maximumDurationSeconds
            )
            rule.durationSeconds = normalizedDuration

            let compilationToken = makeCompilationToken(
                level: level,
                sourceIdentifier: source.identifier,
                durationSeconds: normalizedDuration,
                gain: rule.gain
            )
            let compiledFilename = compiledFilename(for: level)
            compilationRequests.append(
                CompilationRequest(
                    level: level,
                    rule: rule,
                    sourceURL: source.url,
                    durationSeconds: normalizedDuration,
                    compilationToken: compilationToken,
                    compiledFilename: compiledFilename
                )
            )
        }

        guard !compilationRequests.isEmpty else {
            return settings
        }

        try NotificationSoundStorage.withCompiledSoundsDirectoryAccess(fileManager: fileManager) { compiledSoundsDirectory in
            for request in compilationRequests {
                var rule = request.rule
                let compiledURL = compiledSoundsDirectory.appendingPathComponent(request.compiledFilename, isDirectory: false)
                if rule.compilationToken != request.compilationToken || !fileManager.fileExists(atPath: compiledURL.path) {
                    try compiler.compile(
                        from: request.sourceURL,
                        to: compiledURL,
                        targetDurationSeconds: request.durationSeconds,
                        gain: rule.gain
                    )
                }
                rule.compiledFilename = request.compiledFilename
                rule.compilationToken = request.compilationToken
                rule.updatedAt = Date()
                settings.rules[request.level] = rule
                referencedCompiledFilenames.insert(request.compiledFilename)
            }
            try cleanupCompiledFiles(
                in: compiledSoundsDirectory,
                keep: referencedCompiledFilenames
            )
        }
        return settings
    }

    private func cleanupCompiledFiles(in directory: URL, keep filenames: Set<String>) throws {
        let files = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for fileURL in files where fileURL.lastPathComponent.hasPrefix("pushgo-") {
            if !filenames.contains(fileURL.lastPathComponent) {
                try? fileManager.removeItem(at: fileURL)
            }
        }
    }

    private func resolvedSource(
        for level: NotificationSoundLevel,
        rule: NotificationSoundRule,
        settings: NotificationSoundSettings
    ) throws -> NotificationSoundSourceDescriptor? {
        switch rule.mode {
        case .systemDefault:
            return nil
        case .silent:
            return nil
        case .builtin:
            guard let sound = NotificationBuiltinSoundCatalog.sound(id: rule.builtinSoundID ?? level.defaultBuiltinSoundID),
                  let url = builtinURL(for: sound)
            else {
                throw NotificationSoundManagerError.sourceMissing
            }
            return try makeSourceDescriptor(
                identifier: "builtin:\(sound.id)",
                filename: sound.filename,
                url: url
            )
        case .custom:
            guard let asset = settings.customAsset(id: rule.customAssetID) else {
                throw NotificationSoundManagerError.unsupportedSelection
            }
            let originalsDirectory = try NotificationSoundStorage.appGroupOriginalsDirectory(fileManager: fileManager)
            let url = originalsDirectory.appendingPathComponent(asset.originalFilename, isDirectory: false)
            guard fileManager.fileExists(atPath: url.path) else {
                throw NotificationSoundManagerError.sourceMissing
            }
            return try makeSourceDescriptor(
                identifier: "custom:\(asset.id)",
                filename: asset.originalFilename,
                url: url
            )
        }
    }

    private func makeSourceDescriptor(
        identifier: String,
        filename: String,
        url: URL
    ) throws -> NotificationSoundSourceDescriptor {
        let metadata = try compiler.sourceMetadata(for: url)
        return NotificationSoundSourceDescriptor(
            identifier: identifier,
            filename: filename,
            url: url,
            naturalDurationSeconds: metadata.durationSeconds
        )
    }

    private func makeCompilationToken(
        level: NotificationSoundLevel,
        sourceIdentifier: String,
        durationSeconds: Double,
        gain: Double
    ) -> String {
        let normalized = [
            NotificationSoundCompiler.outputFormatVersion,
            level.rawValue,
            sourceIdentifier,
            String(format: "%.2f", durationSeconds),
            String(format: "%.2f", gain),
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(normalized.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return String(digest.prefix(20))
    }

    private func compiledFilename(for level: NotificationSoundLevel) -> String {
        "pushgo-\(level.rawValue).caf"
    }

    private func fallbackRuleAfterRemovingCustomSound(for level: NotificationSoundLevel) -> NotificationSoundRule {
        var rule = NotificationSoundRule.default(for: level)
        if level == .low {
            rule.mode = .silent
        }
        rule.customAssetID = nil
        rule.compiledFilename = nil
        rule.compilationToken = nil
        rule.updatedAt = Date()
        return rule
    }

    private func saveSettingsAndManifest(_ settings: NotificationSoundSettings) throws {
        try NotificationSoundSharedState.saveEffectiveSettingsManifest(settings, fileManager: fileManager)
        NotificationSoundSharedState.saveSettings(settings)
    }

    private func builtinURL(for sound: NotificationBuiltinSound) -> URL? {
        let filename = sound.filename as NSString
        let name = filename.deletingPathExtension
        let ext = filename.pathExtension
        return Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Sounds")
            ?? Bundle.main.url(forResource: sound.filename, withExtension: nil, subdirectory: "Sounds")
            ?? Bundle.main.url(forResource: name, withExtension: ext)
    }

    private func sanitizedExtension(for url: URL) -> String {
        let raw = url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if raw.isEmpty { return "audio" }
        return raw.replacingOccurrences(of: "/", with: "-")
    }
}
