import Foundation
import ImageIO
import SwiftUI

enum WatchCachedImagePhase {
    case empty
    case success(Image)
    case failure
}

/// Watch has no animated resource player. Decode exactly the first frame at display size,
/// rather than creating a full-resolution image (or materializing animation frames).
private actor WatchImageDecoder {
    static let shared = WatchImageDecoder()

    func firstFrame(from data: Data, maximumPixelDimension: Int) -> CGImage? {
        guard !Task.isCancelled, (1...512).contains(maximumPixelDimension) else { return nil }
        return ImageDisplayPolicy.firstFrame(for: data, maximumPixelSize: maximumPixelDimension)
    }
}

struct WatchCachedImage<Content: View>: View {
    @Environment(\.scenePhase) private var scenePhase

    let url: URL
    let owner: SharedImageCache.ResourceOwner
    var revision: Int? = nil
    let accessibilityLabel: String
    var maximumPixelDimension: Int = 512
    @ViewBuilder let content: (WatchCachedImagePhase) -> Content

    private struct LoadIdentity: Hashable {
        let url: URL
        let owner: SharedImageCache.ResourceOwner
        let maximumPixelDimension: Int
        let isActive: Bool
        let isVisible: Bool
        let retry: Int
        let revision: Int?
    }

    @State private var phase: WatchCachedImagePhase = .empty
    @State private var isVisible = false
    @State private var isStale = false
    @State private var retry = 0
    @State private var isAnimatedSource = false

    private var failed: Bool {
        if case .failure = phase { return true }
        return false
    }

    var body: some View {
        ZStack {
            content(phase)
        }
        .accessibilityHint(isAnimatedSource ? Text(LocalizedStringKey("image_static_preview")) : Text(""))
        .overlay(alignment: .bottomTrailing) {
            if isStale || failed {
                Button { retry += 1 } label: {
                    Image(systemName: isStale ? "clock.arrow.circlepath" : "arrow.clockwise")
                        .font(.caption2).padding(4)
                }
                .accessibilityLabel(LocalizedStringKey(isStale ? "image_cached_preview_retry" : "retry"))
                .accessibilityIdentifier("action.image.retry")
            }
        }
        .task(id: LoadIdentity(
            url: url, owner: owner, maximumPixelDimension: maximumPixelDimension,
            isActive: scenePhase == .active, isVisible: isVisible, retry: retry, revision: revision
        )) {
            phase = .empty
            isStale = false
            isAnimatedSource = false
            guard scenePhase == .active, isVisible else { return }
#if DEBUG
            if WatchQualityRuntime.isHermeticRequested,
               ProcessInfo.processInfo.environment["PUSHGO_RESOURCE_RETRY_FIRST_FAILURE"] == "1",
               owner == .watchMessage(localID: "quality-watch-message-001"), retry == 0 {
                phase = .failure
                return
            }
#endif
            do {
                let resource = try await SharedImageCache.resolve(
                    for: url,
                    maxBytes: 8 * 1024 * 1024,
                    timeout: 10,
                    owner: owner
                )
                defer { withExtendedLifetime(resource) {} }
                guard let image = await WatchImageDecoder.shared.firstFrame(
                    from: resource.data,
                    maximumPixelDimension: maximumPixelDimension
                ), !Task.isCancelled, isVisible, scenePhase == .active else {
                    if !Task.isCancelled, isVisible, scenePhase == .active { phase = .failure }
                    return
                }
                isStale = resource.isStale
                isAnimatedSource = ImageDisplayPolicy.metadata(for: resource.data, inspectAnimationFrames: false)?.isAnimated == true
                phase = .success(Image(image, scale: 1, label: Text(accessibilityLabel)))
            } catch is CancellationError {
                return
            } catch {
                if !Task.isCancelled, isVisible, scenePhase == .active { phase = .failure }
            }
        }
        .onAppear { isVisible = true }
        .onDisappear {
            isVisible = false
            phase = .empty
        }
    }
}

enum WatchSemanticTone {
    case info
    case neutral
    case warning

    var foreground: Color {
        switch self {
        case .info:
            return .appStateInfoForeground
        case .neutral:
            return .appStateNeutralForeground
        case .warning:
            return .appStateWarningForeground
        }
    }

    var background: Color {
        switch self {
        case .info:
            return .appStateInfoBackground
        case .neutral:
            return .appStateNeutralBackground
        case .warning:
            return .appStateWarningBackground
        }
    }

    var mutedForeground: Color {
        switch self {
        case .info, .neutral, .warning:
            return .appTextSecondary
        }
    }
}

enum WatchEntityVisualTokens {
    static let subtleFill = Color.appSurfaceRaised
    static let subtleFillSoft = Color.appSurfaceSunken
    static let subtleStroke = Color.appBorderSubtle
    static let chipFillSelected = Color.appSelectionFill
    static let chipFillUnselected = Color.appSurfaceSunken

    static let rowVerticalPadding: CGFloat = 4
    static let stackSpacing: CGFloat = 8
    static let sectionSpacing: CGFloat = 8

    static let radiusSmall: CGFloat = 8
}

struct WatchEntityAvatar: View {
    let url: URL?
    let owner: SharedImageCache.ResourceOwner
    var revision: Int? = nil
    var size: CGFloat = 32
    let loadedImageAccessibilityIdentifier: String
    let loadedImageAccessibilityLabel: String

    var body: some View {
        Group {
            if let url {
                WatchCachedImage(
                    url: url,
                    owner: owner,
                    revision: revision,
                    accessibilityLabel: loadedImageAccessibilityLabel,
                    maximumPixelDimension: 128
                ) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .scaledToFill()
                            .accessibilityElement()
                            .accessibilityLabel(loadedImageAccessibilityLabel)
                            .accessibilityIdentifier(loadedImageAccessibilityIdentifier)
                    case .empty, .failure:
                        Image(systemName: "cube")
                            .font(.caption)
                            .foregroundStyle(Color.appTextSecondary)
                    }
                }
            } else {
                Image(systemName: "cube")
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
            }
        }
        .frame(width: size, height: size)
        .background(WatchEntityVisualTokens.subtleFillSoft)
        .clipShape(RoundedRectangle(cornerRadius: WatchEntityVisualTokens.radiusSmall, style: .continuous))
    }
}

struct WatchEntityStateBadge: View {
    let text: String
    let tone: WatchSemanticTone

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tone.foreground)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tone.background, in: Capsule())
    }
}

struct WatchEntityInlineAlert: View {
    let text: String
    var tone: WatchSemanticTone = .warning

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(tone.mutedForeground)
                .padding(.top, 1)
            Text(text)
                .font(.caption2)
                .foregroundStyle(Color.appTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 1)
    }
}

struct WatchEntityEmptyState: View {
    let icon: String
    let text: String

    var body: some View {
        VStack(spacing: WatchEntityVisualTokens.sectionSpacing) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.appTextSecondary)
            Text(text)
                .font(.footnote)
                .foregroundStyle(Color.appTextSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, WatchEntityVisualTokens.rowVerticalPadding + 6)
    }
}

struct WatchEntityLoadErrorState: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: WatchEntityVisualTokens.sectionSpacing) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(Color.appStateDangerForeground)
            Text(message)
                .font(.footnote)
                .foregroundStyle(Color.appTextSecondary)
                .multilineTextAlignment(.center)
            Button(LocalizationManager.shared.localized("retry"), action: retry)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, WatchEntityVisualTokens.rowVerticalPadding + 6)
    }
}

struct WatchEntityMissingState: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Color.appTextSecondary)
            Text(LocalizationManager.shared.localized("entry_not_found"))
                .font(.footnote)
                .foregroundStyle(Color.appTextSecondary)
        }
    }
}

func watchDateText(_ date: Date) -> String {
    date.formatted(date: .abbreviated, time: .shortened)
}

func watchEventStateTone(_ state: String?) -> WatchSemanticTone {
    let normalized = state?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
    switch normalized {
    case "ONGOING":
        return .info
    case "CLOSED":
        return .neutral
    default:
        return .neutral
    }
}

func watchEventStateColor(_ state: String?) -> Color {
    watchEventStateTone(state).foreground
}

func normalizedWatchEventStatus(_ status: String?) -> String? {
    let trimmed = status?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
}

func watchDecryptionStateText(_ raw: String?) -> String? {
    let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmed.isEmpty else { return nil }
    switch PushMessage.DecryptionState.from(raw: trimmed) {
    case .decryptOk:
        return "Decrypted"
    case .decryptFailed:
        return "Decrypt Failed"
    case .notConfigured:
        return "Encrypted (No Key)"
    case .algMismatch:
        return "Encrypted (Alg)"
    case .none:
        return trimmed
    }
}

func watchDecryptionStateTone(_ raw: String?) -> WatchSemanticTone {
    switch PushMessage.DecryptionState.from(raw: raw) {
    case .decryptOk:
        return .info
    case .decryptFailed:
        return .warning
    case .notConfigured, .algMismatch:
        return .neutral
    case .none:
        return .neutral
    }
}

func localizedDefaultWatchCreatedEventStatus() -> String {
    LocalizationManager.localizedSync("watch_event_status_created")
}

struct WatchEntityDisplayAttribute: Identifiable, Hashable {
    let key: String
    let label: String
    let value: String

    var displayLabel: String {
        label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? key : label
    }

    var id: String { "\(key):\(label):\(value)" }
}

func parseWatchEntityAttributes(from jsonText: String?) -> [WatchEntityDisplayAttribute] {
    guard let jsonText,
          !jsonText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          let data = jsonText.data(using: .utf8),
          let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else {
        return []
    }

    return object
        .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
        .map { key, value in
            WatchEntityDisplayAttribute(
                key: key,
                label: key,
                value: watchAttributeDisplayValue(value)
            )
        }
}

func hasNonEmptyWatchEntityAttributes(from jsonText: String?) -> Bool {
    !parseWatchEntityAttributes(from: jsonText).isEmpty
}

func watchDisplayAttributes(from metadata: [String: String]) -> [WatchEntityDisplayAttribute] {
    metadata
        .filter { !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
        .map { key, value in
            WatchEntityDisplayAttribute(key: key, label: key, value: value)
        }
}

func isLikelyWatchImageAttachmentURL(_ url: URL) -> Bool {
    let path = url.path.lowercased()
    let imageExtensions = [".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".heic", ".heif"]
    if imageExtensions.contains(where: { path.hasSuffix($0) }) {
        return true
    }
    return !url.lastPathComponent.contains(".")
}

private func watchAttributeDisplayValue(_ value: Any) -> String {
    switch value {
    case let text as String:
        return text
    case let number as NSNumber:
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue ? "true" : "false"
        }
        return number.stringValue
    case let dict as [String: Any]:
        return watchCompactJSONString(from: dict) ?? "{}"
    case let array as [Any]:
        return watchCompactJSONString(from: array) ?? "[]"
    case _ as NSNull:
        return "null"
    default:
        return String(describing: value)
    }
}

private func nonEmptyWatchAttributeText(_ value: Any?) -> String? {
    guard let text = value as? String else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func watchCompactJSONString(from value: Any) -> String? {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8)
    else {
        return nil
    }
    return text
}
