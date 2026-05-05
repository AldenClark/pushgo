import SwiftUI
import AppKit

enum EntityVisualTokens {
    static let pageBackground = Color.messageListBackground
    static let secondarySurface = Color.appSurfaceRaised
    static let tertiarySurface = Color.appSurfaceSunken
    static let subtleFill = Color.appSurfaceSunken
    static let subtleFillSoft = Color.appSurfaceRaised
    static let subtleStroke = Color.appBorderSubtle
    static let subtleStrokeStrong = Color.appBorderStrong
    static let chipFillSelected = Color.appSelectionFill
    static let chipFillUnselected = Color.appSurfaceSunken
    static let selectionFill = Color.appSelectionFill

    static let listRowInsetHorizontal: CGFloat = 6
    static let listRowInsetVertical: CGFloat = 10
    static let rowVerticalPadding: CGFloat = 6
    static let stackSpacing: CGFloat = 10
    static let detailSectionSpacing: CGFloat = 16
    static let detailPaddingHorizontal: CGFloat = 20
    static let detailPaddingVertical: CGFloat = 16
    static let chipPaddingVertical: CGFloat = 6

    static let radiusSmall: CGFloat = 10
    static let radiusMedium: CGFloat = 12
    static let radiusLarge: CGFloat = 16
}

struct EntitySelectionBackground: View {
    let isSelected: Bool

    var body: some View {
        if isSelected {
            Rectangle().fill(EntityVisualTokens.selectionFill)
        } else {
            Color.clear
        }
    }
}

extension View {
    func entityListRowTapTarget() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }
}

struct EntityThumbnail: View {
    let url: URL?
    var size: CGFloat = 44
    var placeholderSystemImage: String = "photo"
    var showsBorder: Bool = true

    var body: some View {
        RemoteImageView(url: url, rendition: .listThumbnail) { image in
            image
                .resizable()
                .scaledToFill()
        } placeholder: {
            ZStack {
                RoundedRectangle(cornerRadius: EntityVisualTokens.radiusSmall, style: .continuous)
                    .fill(EntityVisualTokens.secondarySurface)
                Image(systemName: placeholderSystemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.appTextSecondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: EntityVisualTokens.radiusSmall, style: .continuous))
        .overlay {
            if showsBorder {
                RoundedRectangle(cornerRadius: EntityVisualTokens.radiusSmall, style: .continuous)
                    .stroke(EntityVisualTokens.subtleStroke, lineWidth: 1)
            }
        }
    }
}

struct EntityStateBadge: View {
    let text: String
    var tone: AppSemanticTone = .info

    var body: some View {
        AppCapsuleBadge(foreground: tone.foreground, background: tone.background) {
            Text(text)
                .font(.caption2.weight(.semibold))
        }
    }
}

struct EntityInlineAlert: View {
    let text: String
    var systemImage: String = "exclamationmark.circle.fill"
    var tone: AppSemanticTone = .warning

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: systemImage)
                .font(.caption)
                .foregroundStyle(tone.mutedForeground)
                .padding(.top, 1)
            Text(text)
                .font(.caption)
                .foregroundStyle(Color.appTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 1)
    }
}

struct EntityTimelineMarker: View {
    let tone: AppSemanticTone
    let isFirst: Bool
    let isLast: Bool

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(isFirst ? Color.clear : Color.appBorderSubtle)
                .frame(width: 2)
            Circle()
                .fill(tone.background)
                .frame(width: 10, height: 10)
                .overlay(
                    Circle()
                        .stroke(tone.foreground, lineWidth: 1)
                )
            Rectangle()
                .fill(isLast ? Color.clear : Color.appBorderSubtle)
                .frame(width: 2)
        }
        .frame(width: 14)
    }
}

struct EntityMetaChip: View {
    let systemImage: String
    let text: String
    var color: Color = .appTextSecondary

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(EntityVisualTokens.chipFillUnselected)
            )
    }
}

struct EntityEmptyAction {
    let title: String
    let systemImage: String
    let action: () -> Void
}

enum EntityOnboardingEmptyKind: Equatable {
    case messages
    case events
    case things
    case channels

    var iconName: String {
        switch self {
        case .messages:
            "paperplane.circle"
        case .events:
            "bolt.horizontal.circle"
        case .things:
            "shippingbox"
        case .channels:
            "dot.radiowaves.left.and.right"
        }
    }

    var titleKey: String {
        switch self {
        case .messages:
            "onboarding_messages_empty_title"
        case .events:
            "onboarding_events_empty_title"
        case .things:
            "onboarding_things_empty_title"
        case .channels:
            "onboarding_channels_empty_title"
        }
    }

    var subtitleKey: String {
        switch self {
        case .messages:
            "onboarding_messages_empty_subtitle"
        case .events:
            "onboarding_events_empty_subtitle"
        case .things:
            "onboarding_things_empty_subtitle"
        case .channels:
            "onboarding_channels_empty_subtitle"
        }
    }

    var stepKeys: [String] {
        switch self {
        case .messages:
            [
                "onboarding_messages_step_channel",
                "onboarding_messages_step_send",
                "onboarding_messages_step_delivery",
            ]
        case .events:
            [
                "onboarding_events_step_channel",
                "onboarding_events_step_create",
                "onboarding_events_step_update",
                "onboarding_events_step_close",
            ]
        case .things:
            [
                "onboarding_things_step_channel",
                "onboarding_things_step_create",
                "onboarding_things_step_update",
                "onboarding_things_step_activity",
            ]
        case .channels:
            []
        }
    }

    var documentationPage: PushGoDocumentationPage? {
        switch self {
        case .messages:
            .messageAPI
        case .events:
            .eventAPI
        case .things:
            .thingAPI
        case .channels:
            nil
        }
    }

    var documentationTitleKey: String? {
        switch self {
        case .messages:
            "open_message_api_docs"
        case .events:
            "open_event_api_docs"
        case .things:
            "open_thing_api_docs"
        case .channels:
            nil
        }
    }
}

struct EntityOnboardingEmptyView: View {
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager
    @Environment(\.openURL) private var openURL

    let kind: EntityOnboardingEmptyKind
    var channelPrimaryAction: (() -> Void)?
    var subtitleMaxWidth: CGFloat? = 420

    var body: some View {
        EntityEmptyView(
            iconName: kind.iconName,
            title: localizationManager.localized(kind.titleKey),
            subtitle: localizationManager.localized(kind.subtitleKey),
            guidanceSteps: kind.stepKeys.map { localizationManager.localized($0) },
            primaryAction: primaryAction,
            secondaryAction: secondaryAction,
            subtitleMaxWidth: subtitleMaxWidth
        )
    }

    private var primaryAction: EntityEmptyAction? {
        if kind == .channels {
            guard let channelPrimaryAction else { return nil }
            return EntityEmptyAction(
                title: localizationManager.localized("add_channel"),
                systemImage: "plus.circle",
                action: channelPrimaryAction
            )
        }

        guard let page = kind.documentationPage, let titleKey = kind.documentationTitleKey else {
            return nil
        }
        return EntityEmptyAction(
            title: localizationManager.localized(titleKey),
            systemImage: "book"
        ) {
            openURL(AppConstants.documentationURL(page))
        }
    }

    private var secondaryAction: EntityEmptyAction {
        EntityEmptyAction(
            title: localizationManager.localized("open_getting_started_docs"),
            systemImage: "arrow.up.right.square"
        ) {
            openURL(AppConstants.documentationURL(.gettingStarted))
        }
    }
}

private struct EntityEmptyStepper: View {
    private enum Metrics {
        static let textMaxWidth: CGFloat = 248
    }

    let iconName: String
    let steps: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                EntityEmptyStepItem(
                    systemImage: stepIcon(at: index),
                    text: step,
                    textMaxWidth: Metrics.textMaxWidth,
                    isLast: index == steps.count - 1
                )
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func stepIcon(at index: Int) -> String {
        let icons: [String]
        if iconName.contains("paperplane") {
            icons = ["dot.radiowaves.left.and.right", "paperplane", "tray"]
        } else if iconName.contains("bolt") {
            icons = ["plus.circle", "bolt.horizontal", "arrow.triangle.2.circlepath", "checkmark.circle"]
        } else if iconName.contains("shippingbox") {
            icons = ["dot.radiowaves.left.and.right", "shippingbox", "slider.horizontal.3", "bubble.left.and.bubble.right"]
        } else {
            icons = ["plus.circle", "lock.open", "curlybraces"]
        }
        return icons.indices.contains(index) ? icons[index] : "\(index + 1).circle"
    }
}

private struct EntityEmptyStepItem: View {
    let systemImage: String
    let text: String
    let textMaxWidth: CGFloat
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Image(systemName: systemImage)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.appAccentPrimary)
                    .frame(width: 34, height: 34)
                    .background(
                        Circle()
                            .fill(EntityVisualTokens.subtleFillSoft)
                    )
                    .overlay(
                        Circle()
                            .stroke(EntityVisualTokens.subtleStroke, lineWidth: 0.8)
                    )
                    .accessibilityHidden(true)
                Rectangle()
                    .fill(isLast ? Color.clear : EntityVisualTokens.subtleStroke)
                    .frame(width: 1, height: 18)
                    .accessibilityHidden(true)
            }

            Text(text)
                .font(.footnote.weight(.medium))
                .foregroundStyle(Color.appTextPrimary)
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: textMaxWidth, alignment: .leading)
                .padding(.top, 7)
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
    }
}

private struct EntityEmptyHero: View {
    let iconName: String

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.appAccentPrimary.opacity(0.045))
                .frame(width: 118, height: 118)
                .offset(y: -2)

            Path { path in
                path.move(to: CGPoint(x: 20, y: 112))
                path.addCurve(
                    to: CGPoint(x: 94, y: 96),
                    control1: CGPoint(x: 42, y: 130),
                    control2: CGPoint(x: 42, y: 70)
                )
                path.addCurve(
                    to: CGPoint(x: 150, y: 54),
                    control1: CGPoint(x: 120, y: 112),
                    control2: CGPoint(x: 126, y: 62)
                )
            }
            .stroke(
                Color.appAccentPrimary.opacity(0.18),
                style: StrokeStyle(lineWidth: 2.4, lineCap: .round, dash: [7, 7])
            )
            .frame(width: 138, height: 108)
            .offset(x: -8, y: 14)

            Image(systemName: heroSymbolName)
                .font(.system(size: isRadioWavesHero ? 50 : 48, weight: isRadioWavesHero ? .bold : .semibold))
                .symbolRenderingMode(isRadioWavesHero ? .monochrome : .hierarchical)
                .foregroundStyle(Color.appAccentPrimary)
                .rotationEffect(heroSymbolName.contains("paperplane") ? .degrees(-10) : .degrees(0))
                .shadow(color: Color.appAccentPrimary.opacity(0.1), radius: 10, y: 5)
        }
        .frame(width: 150, height: 118)
        .accessibilityHidden(true)
    }

    private var heroSymbolName: String {
        if iconName.contains("paperplane") { return "paperplane.fill" }
        if iconName.contains("bolt") { return "bolt.horizontal.fill" }
        if iconName.contains("shippingbox") { return "shippingbox.fill" }
        if iconName.contains("dot.radiowaves") { return "dot.radiowaves.left.and.right" }
        return iconName
    }

    private var isRadioWavesHero: Bool {
        heroSymbolName.contains("dot.radiowaves")
    }
}

struct EntityEmptyView: View {
    let iconName: String
    let title: String
    let subtitle: String
    var guidanceSteps: [String] = []
    var primaryAction: EntityEmptyAction?
    var secondaryAction: EntityEmptyAction?
    var subtitleMaxWidth: CGFloat? = 420
    var fillsAvailableSpace: Bool = true
    var topPadding: CGFloat = 48
    var horizontalPadding: CGFloat = 24

    init(
        iconName: String = "tray",
        title: String,
        subtitle: String,
        guidanceSteps: [String] = [],
        primaryAction: EntityEmptyAction? = nil,
        secondaryAction: EntityEmptyAction? = nil,
        subtitleMaxWidth: CGFloat? = 420,
        fillsAvailableSpace: Bool = true,
        topPadding: CGFloat = 48,
        horizontalPadding: CGFloat = 24
    ) {
        self.iconName = iconName
        self.title = title
        self.subtitle = subtitle
        self.guidanceSteps = guidanceSteps
        self.primaryAction = primaryAction
        self.secondaryAction = secondaryAction
        self.subtitleMaxWidth = subtitleMaxWidth
        self.fillsAvailableSpace = fillsAvailableSpace
        self.topPadding = topPadding
        self.horizontalPadding = horizontalPadding
    }

    var body: some View {
        let textBlock = VStack(spacing: 18) {
            EntityEmptyHero(iconName: iconName)
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.appTextPrimary)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(Color.appTextSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: subtitleMaxWidth)
            if !guidanceSteps.isEmpty {
                EntityEmptyStepper(iconName: iconName, steps: guidanceSteps)
                    .padding(.top, 14)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            if primaryAction != nil || secondaryAction != nil {
                HStack(spacing: 10) {
                    if let primaryAction {
                        Button {
                            primaryAction.action()
                        } label: {
                            Label(primaryAction.title, systemImage: primaryAction.systemImage)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    if let secondaryAction {
                        Button {
                            secondaryAction.action()
                        } label: {
                            Label(secondaryAction.title, systemImage: secondaryAction.systemImage)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 8)
            }
        }

        Group {
            if fillsAvailableSpace {
                VStack(spacing: 24) {
                    textBlock
                        .frame(maxWidth: .infinity)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                VStack(spacing: 24) {
                    textBlock
                        .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .padding(.top, topPadding)
        .padding(.horizontal, horizontalPadding)
    }
}

enum EntityDateFormatter {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()
    static func text(_ date: Date) -> String {
        formatter.string(from: date)
    }

    static func relativeText(_ date: Date) -> String {
        date.formatted(
            .relative(
                presentation: .named,
                unitsStyle: .abbreviated
            )
        )
    }
}

struct EntityDisplayAttribute: Identifiable, Hashable {
    let key: String
    let label: String
    let value: String

    var displayLabel: String {
        label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? key : label
    }

    var id: String { "\(key):\(label):\(value)" }
}

struct EntityKeyValueRows: View {
    let entries: [EntityDisplayAttribute]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(entries.indices, id: \.self) { index in
                let entry = entries[index]
                Text("\(entry.displayLabel) - \(entry.value)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.vertical, EntityVisualTokens.rowVerticalPadding)
                if index < entries.count - 1 {
                    AppInsetDivider()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: EntityVisualTokens.radiusMedium, style: .continuous)
                .fill(EntityVisualTokens.subtleFill)
        )
    }
}

struct EntityDecryptionBadgeDescriptor {
    let icon: String
    let text: String
    let tone: AppSemanticTone
}

@MainActor
func entityDecryptionBadgeDescriptor(
    state: PushMessage.DecryptionState?,
    localizationManager: LocalizationManager
) -> EntityDecryptionBadgeDescriptor? {
    guard let state else { return nil }
    switch state {
    case .decryptOk:
        return EntityDecryptionBadgeDescriptor(
            icon: "lock.open.fill",
            text: localizationManager.localized("decrypted"),
            tone: .info
        )
    case .decryptFailed:
        return EntityDecryptionBadgeDescriptor(
            icon: "lock.slash",
            text: localizationManager.localized("decryption_failed_the_original_text_has_been_displayed"),
            tone: .danger
        )
    case .notConfigured:
        return EntityDecryptionBadgeDescriptor(
            icon: "lock.fill",
            text: "Encrypted (Not Configured)",
            tone: .warning
        )
    case .algMismatch:
        return EntityDecryptionBadgeDescriptor(
            icon: "lock.fill",
            text: "Encrypted (Alg Mismatch)",
            tone: .warning
        )
    }
}

func normalizedEventState(_ state: String?) -> String {
    switch state?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
    case "ONGOING":
        return "ONGOING"
    case "CLOSED":
        return "CLOSED"
    default:
        return "UNKNOWN"
    }
}

func normalizedThingState(_ state: String?) -> String {
    switch state?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "active":
        return "ACTIVE"
    case "inactive", "archived":
        return "ARCHIVED"
    case "deleted", "decommissioned":
        return "DELETED"
    default:
        return "UNKNOWN"
    }
}

func normalizedEventStatus(_ status: String?) -> String? {
    let trimmed = status?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
}

func localizedDefaultCreatedEventStatus() -> String {
    LocalizationManager.localizedSync("event_status_created_default")
}

func parseEntityAttributes(from jsonText: String?) -> [EntityDisplayAttribute] {
    guard let jsonText,
          !jsonText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          let data = jsonText.data(using: .utf8),
          let value = try? JSONSerialization.jsonObject(with: data)
    else {
        return []
    }

    if let object = value as? [String: Any] {
        return object
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { key, value in
                displayAttribute(key: key, rawValue: value)
            }
    }

    if let array = value as? [Any] {
        return array.enumerated().compactMap { index, item in
            guard let object = item as? [String: Any] else {
                let fallbackKey = "item_\(index + 1)"
                return EntityDisplayAttribute(
                    key: fallbackKey,
                    label: fallbackKey,
                    value: attributeDisplayValue(item)
                )
            }
            let fallbackKey = nonEmptyAttributeText(object["key"]) ?? "item_\(index + 1)"
            let rawLabel = nonEmptyAttributeText(object["label"])
            let value = object.keys.contains("value")
                ? attributeDisplayValue(object["value"] as Any)
                : compactJSONString(from: object) ?? "{}"
            return EntityDisplayAttribute(
                key: fallbackKey,
                label: rawLabel ?? fallbackKey,
                value: value
            )
        }
    }

    return []
}

private func displayAttribute(key: String, rawValue: Any) -> EntityDisplayAttribute {
    if let object = rawValue as? [String: Any], object.keys.contains("value") {
        return EntityDisplayAttribute(
            key: key,
            label: nonEmptyAttributeText(object["label"]) ?? key,
            value: attributeDisplayValue(object["value"] as Any)
        )
    }
    return EntityDisplayAttribute(
        key: key,
        label: key,
        value: attributeDisplayValue(rawValue)
    )
}

func hasNonEmptyEntityAttributes(from jsonText: String?) -> Bool {
    !parseEntityAttributes(from: jsonText).isEmpty
}

func metadataDisplayAttributes(from metadata: [String: String]) -> [EntityDisplayAttribute] {
    metadata
        .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
        .map { key, value in
            EntityDisplayAttribute(key: key, label: key, value: value)
        }
}

func isLikelyImageAttachmentURL(_ url: URL) -> Bool {
    let path = url.path.lowercased()
    let imageExtensions = [".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".heic", ".heif"]
    if imageExtensions.contains(where: { path.hasSuffix($0) }) {
        return true
    }
    return !url.lastPathComponent.contains(".")
}

func eventStateColor(_ state: String?) -> Color {
    eventStateTone(state).foreground
}

func eventStateTone(_ state: String?) -> AppSemanticTone {
    switch normalizedEventState(state) {
    case "ONGOING":
        return .info
    case "CLOSED":
        return .neutral
    default:
        return .neutral
    }
}

enum EventSeverity: String {
    case critical
    case high
    case medium
    case low
    case info
}

enum EventLifecycleState: String {
    case ongoing
    case closed
    case unknown
}

func eventLifecycleState(from raw: String?) -> EventLifecycleState {
    switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
    case "ONGOING":
        return .ongoing
    case "CLOSED":
        return .closed
    default:
        return .unknown
    }
}

func normalizedEventSeverity(_ severity: String?) -> EventSeverity? {
    EventSeverity(rawValue: severity?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "")
}

func eventSeverityTone(_ severity: EventSeverity?) -> AppSemanticTone? {
    switch severity {
    case .critical:
        return .danger
    case .high:
        return .warning
    case .medium:
        return .info
    case .low:
        return .info
    case .info:
        return .info
    case nil:
        return nil
    }
}

func eventSeverityColor(_ severity: EventSeverity?) -> Color? {
    eventSeverityTone(severity)?.foreground
}

func eventSeveritySymbol(_ severity: EventSeverity?) -> String? {
    switch severity {
    case .critical:
        return "exclamationmark.triangle.fill"
    case .high:
        return "exclamationmark.circle.fill"
    case .medium:
        return "info.circle.fill"
    case .low:
        return "arrow.down.circle.fill"
    case .info:
        return "info.circle.fill"
    case nil:
        return nil
    }
}

func thingStateColor(_ state: String?) -> Color {
    thingStateTone(state).foreground
}

func thingStateTone(_ state: String?) -> AppSemanticTone {
    switch normalizedThingState(state) {
    case "ACTIVE":
        return .success
    case "ARCHIVED":
        return .warning
    case "DELETED":
        return .danger
    default:
        return .neutral
    }
}

private func attributeDisplayValue(_ value: Any) -> String {
    switch value {
    case let text as String:
        return text
    case let number as NSNumber:
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue ? "true" : "false"
        }
        return number.stringValue
    case let dict as [String: Any]:
        return compactJSONString(from: dict) ?? "{}"
    case let array as [Any]:
        return compactJSONString(from: array) ?? "[]"
    case _ as NSNull:
        return "null"
    default:
        return String(describing: value)
    }
}

private func nonEmptyAttributeText(_ value: Any?) -> String? {
    guard let text = value as? String else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func compactJSONString(from value: Any) -> String? {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8)
    else {
        return nil
    }
    return text
}
