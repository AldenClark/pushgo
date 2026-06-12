import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

private enum NotificationSoundPickerOption: Hashable, Identifiable {
    case systemDefault
    case none
    case custom(NotificationCustomSoundAsset)
    case builtin(NotificationBuiltinSound)

    var id: String {
        switch self {
        case .systemDefault:
            return "system-default"
        case .none:
            return "none"
        case let .custom(asset):
            return "custom:\(asset.id)"
        case let .builtin(sound):
            return "builtin:\(sound.id)"
        }
    }
}

struct NotificationSoundSettingsContentView: View {
    @Bindable var viewModel: SettingsViewModel
    var dismissAction: (() -> Void)? = nil
    var showsInlineTitle = false

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(LocalizationManager.self) private var localizationManager
    @State private var isPresentingImporter = false
    @State private var draftSettings = NotificationSoundSettings()
    @State private var isDraftLoaded = false
    @State private var isCommittingDraft = false
    @State private var didSubmitDraft = false
    @State private var pendingRemovalAsset: NotificationCustomSoundAsset?

    private var isCompactLayout: Bool {
        horizontalSizeClass == .compact
    }

    private var hasDraftChanges: Bool {
        isDraftLoaded && draftSettings != viewModel.notificationSoundSettings
    }

    private var priorityControlsAreDisabled: Bool {
        #if os(macOS)
        !viewModel.hasMacOSNotificationSoundDirectoryAccess
        #else
        false
        #endif
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: isCompactLayout ? 16 : 18) {
                if showsInlineTitle {
                    HStack(spacing: 12) {
                        Text(localizationManager.localized("notification_sounds"))
                            .font(.title3.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if let dismissAction {
                            Button {
                                Task { await submitDraftAndDismiss(dismissAction: dismissAction) }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(Color.appTextSecondary)
                                    .frame(width: 30, height: 30)
                                    .background(
                                        Circle()
                                            .fill(Color.appSurfaceRaised)
                                    )
                            }
                            .buttonStyle(.plain)
                            .transientPresentationActionControl()
                            .disabled(isCommittingDraft)
                            .accessibilityLabel(localizationManager.localized("close_notification_sound_settings"))
                        }
                    }
                }

                if let errorMessage = viewModel.errorMessage {
                    AppInlineFeedbackBanner(
                        message: errorMessage,
                        tone: .danger,
                        accessibilityID: "feedback.settings.notification_sounds"
                    ) {
                        viewModel.clearError()
                    }
                }

                macOSSoundDirectoryPermissionBanner
                prioritySettingsSection
                soundLibrarySection

            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            await viewModel.refreshNotificationSoundSettings()
            if !isDraftLoaded {
                draftSettings = viewModel.notificationSoundSettings
                isDraftLoaded = true
            }
        }
        .onDisappear {
            viewModel.stopNotificationSoundPreview()
            viewModel.clearError()
            guard !isPresentingImporter, !didSubmitDraft, hasDraftChanges else { return }
            let settings = draftSettings
            didSubmitDraft = true
            Task { await viewModel.commitNotificationSoundSettings(settings) }
        }
        .fileImporter(
            isPresented: $isPresentingImporter,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                guard let url = urls.first else { return }
                Task {
                    await viewModel.importNotificationSound(from: url)
                    mergeLibraryStateFromViewModel()
                }
            case let .failure(error):
                viewModel.error = AppError.wrap(
                    error,
                    fallbackMessage: localizationManager.localized("unable_to_import_this_sound"),
                    code: "notification_sound_file_import_failed",
                    category: .validation
                )
            }
        }
        .alert(localizationManager.localized("remove_custom_sound_confirm_title"), isPresented: removalConfirmationBinding) {
            Button(localizationManager.localized("delete"), role: .destructive) {
                guard let asset = pendingRemovalAsset else { return }
                Task { await removeCustomSound(asset) }
            }
            Button(localizationManager.localized("cancel"), role: .cancel) {
                pendingRemovalAsset = nil
            }
        } message: {
            Text(localizationManager.localized("remove_custom_sound_confirm_message"))
        }
    }

    private var prioritySettingsSection: some View {
        VStack(spacing: 0) {
            ForEach(NotificationSoundLevel.allCases) { level in
                NotificationSoundPriorityRow(
                    level: level,
                    rule: draftSettings.rule(for: level),
                    customAssets: draftSettings.customAssets,
                    isCompactLayout: isCompactLayout,
                    isPreviewing: viewModel.notificationSoundPreviewID == "priority:\(level.rawValue)",
                    onPreview: {
                        let settings = draftSettings
                        Task { await viewModel.previewNotificationSound(for: level, settings: settings) }
                    },
                    onOptionChanged: { option in
                        updateDraftSoundOption(option, for: level)
                    },
                    onDurationChanged: { duration in
                        updateDraftDuration(duration, for: level)
                    },
                    onGainChanged: { gain in
                        updateDraftGain(gain, for: level)
                    }
                )

                if level != NotificationSoundLevel.allCases.last {
                    Divider()
                }
            }
        }
        .padding(.vertical, 2)
        .disabled(priorityControlsAreDisabled)
        .opacity(priorityControlsAreDisabled ? 0.42 : 1)
    }

    @ViewBuilder
    private var macOSSoundDirectoryPermissionBanner: some View {
        #if os(macOS)
        if !viewModel.hasMacOSNotificationSoundDirectoryAccess {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "folder.badge.gearshape")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(AppSemanticTone.warning.foreground)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(localizationManager.localized("sound_folder_permission_required"))
                        .font(.subheadline.weight(.semibold))
                    Text(localizationManager.localized("sound_folder_permission_explanation"))
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Button {
                    Task {
                        await viewModel.requestMacOSNotificationSoundDirectoryAccess()
                    }
                } label: {
                    Text(localizationManager.localized("grant_access"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(
                            Capsule()
                                .fill(Color.appAccentPrimary)
                        )
                }
                .buttonStyle(.plain)
                .transientPresentationActionControl()
                .disabled(viewModel.isRequestingMacOSNotificationSoundDirectoryAccess)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AppSemanticTone.warning.background)
            )
        }
        #endif
    }

    private var soundLibrarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                soundLibraryHeader
                VStack(alignment: .leading, spacing: 10) {
                    Text(localizationManager.localized("sound_library"))
                        .font(.headline)
                    importButton
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                if !draftSettings.customAssets.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(draftSettings.customAssets) { asset in
            NotificationSoundLibraryRow(
                title: asset.displayName,
                isPreviewing: viewModel.notificationSoundPreviewID == "custom:\(asset.id)",
                                onPreview: {
                                    let settings = draftSettings
                                    Task { await viewModel.previewNotificationCustomSound(asset.id, settings: settings) }
                                },
                                trailingAction: {
                                    Button {
                                        pendingRemovalAsset = asset
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.callout.weight(.medium))
                                            .foregroundStyle(AppSemanticTone.danger.foreground)
                                    }
                                    .buttonStyle(.appPlain)
                                    .accessibilityLabel(localizationManager.localized("remove_item_placeholder", asset.displayName))
                                }
                            )
                            if asset.id != (draftSettings.customAssets.last?.id ?? "") {
                                Divider()
                            }
                        }
                    }

                    Divider()
                        .padding(.vertical, 2)
                }

                VStack(spacing: 0) {
                    ForEach(NotificationBuiltinSoundCatalog.sounds) { sound in
                        NotificationSoundLibraryRow(
                            title: sound.displayName,
                            isPreviewing: viewModel.notificationSoundPreviewID == "builtin:\(sound.id)",
                            onPreview: {
                                Task { await viewModel.previewNotificationBuiltinSound(sound.id) }
                            }
                        )
                        if sound.id != (NotificationBuiltinSoundCatalog.sounds.last?.id ?? "") {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private var soundLibraryHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(localizationManager.localized("sound_library"))
                .font(.headline)
            Spacer(minLength: 12)
            importButton
        }
    }

    private var importButton: some View {
        Button {
            isPresentingImporter = true
        } label: {
            Image(systemName: viewModel.isImportingNotificationSound ? "hourglass" : "plus")
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.appAccentPrimary)
                .frame(width: 34, height: 34)
                .background(
                    Circle()
                        .fill(Color.appSurfaceRaised)
                )
        }
        .buttonStyle(.plain)
        .transientPresentationActionControl()
        .disabled(viewModel.isImportingNotificationSound)
        .accessibilityLabel(localizationManager.localized("import_sound"))
    }

    private var removalConfirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingRemovalAsset != nil },
            set: { isPresented in
                if !isPresented {
                    pendingRemovalAsset = nil
                }
            }
        )
    }

    private func removeCustomSound(_ asset: NotificationCustomSoundAsset) async {
        pendingRemovalAsset = nil
        setDraftRulesUsingCustomSoundToSilent(asset.id)
        await viewModel.removeNotificationCustomSound(assetID: asset.id)
        mergeLibraryStateFromViewModel()
    }

    private func submitDraftAndDismiss(dismissAction: @escaping () -> Void) async {
        guard !isCommittingDraft else { return }
        isCommittingDraft = true
        defer { isCommittingDraft = false }

        didSubmitDraft = true
        guard hasDraftChanges else {
            dismissAction()
            return
        }
        let saved = await viewModel.commitNotificationSoundSettings(draftSettings)
        if saved {
            dismissAction()
        } else {
            didSubmitDraft = false
        }
    }

    private func mergeLibraryStateFromViewModel() {
        var merged = draftSettings
        merged.customAssets = viewModel.notificationSoundSettings.customAssets
        for level in NotificationSoundLevel.allCases {
            var rule = merged.rule(for: level)
            if rule.mode == .custom,
               !merged.customAssets.contains(where: { $0.id == rule.customAssetID })
            {
                rule = silentRule(for: level)
                merged.rules[level] = rule
            }
        }
        draftSettings = merged
    }

    private func setDraftRulesUsingCustomSoundToSilent(_ assetID: String) {
        for level in NotificationSoundLevel.allCases {
            var rule = draftSettings.rule(for: level)
            guard rule.mode == .custom, rule.customAssetID == assetID else { continue }
            rule = silentRule(for: level)
            draftSettings.rules[level] = rule
        }
        draftSettings.updatedAt = Date()
    }

    private func updateDraftSoundOption(
        _ option: NotificationSoundPickerOption,
        for level: NotificationSoundLevel
    ) {
        var rule = draftSettings.rule(for: level)
        switch option {
        case .systemDefault:
            rule.mode = .systemDefault
            rule.builtinSoundID = nil
            rule.customAssetID = nil
            rule.durationSeconds = nil
            rule.gain = 1
        case .none:
            rule = silentRule(for: level)
        case let .custom(asset):
            rule.mode = .custom
            rule.customAssetID = asset.id
        case let .builtin(sound):
            rule.mode = .builtin
            rule.builtinSoundID = sound.id
            rule.customAssetID = nil
        }
        updateDraftRule(rule, for: level)
    }

    private func updateDraftDuration(_ duration: Double, for level: NotificationSoundLevel) {
        var rule = draftSettings.rule(for: level)
        rule.durationSeconds = duration
        updateDraftRule(rule, for: level)
    }

    private func updateDraftGain(_ gain: Double, for level: NotificationSoundLevel) {
        var rule = draftSettings.rule(for: level)
        rule.gain = gain
        updateDraftRule(rule, for: level)
    }

    private func updateDraftRule(_ rule: NotificationSoundRule, for level: NotificationSoundLevel) {
        var updatedRule = rule
        updatedRule.compiledFilename = nil
        updatedRule.compilationToken = nil
        updatedRule.updatedAt = Date()
        draftSettings.rules[level] = updatedRule
        draftSettings.updatedAt = Date()
        viewModel.clearError()
    }

    private func silentRule(for level: NotificationSoundLevel) -> NotificationSoundRule {
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

}

private struct NotificationSoundPriorityRow: View {
    let level: NotificationSoundLevel
    let rule: NotificationSoundRule
    let customAssets: [NotificationCustomSoundAsset]
    let isCompactLayout: Bool
    let isPreviewing: Bool
    let onPreview: () -> Void
    let onOptionChanged: (NotificationSoundPickerOption) -> Void
    let onDurationChanged: (Double) -> Void
    let onGainChanged: (Double) -> Void
    @Environment(LocalizationManager.self) private var localizationManager

    private var selectedOption: NotificationSoundPickerOption {
        switch rule.mode {
        case .systemDefault:
            return .systemDefault
        case .silent:
            return allowsSilentOption ? .none : fallbackOption
        case .custom:
            if let asset = customAssets.first(where: { $0.id == rule.customAssetID }) {
                return .custom(asset)
            }
            return fallbackOption
        case .builtin:
            if let sound = NotificationBuiltinSoundCatalog.sound(id: rule.builtinSoundID ?? level.defaultBuiltinSoundID) {
                return .builtin(sound)
            }
            return fallbackOption
        }
    }

    private var allowsSilentOption: Bool {
        level == .low
    }

    private var fallbackOption: NotificationSoundPickerOption {
        #if os(macOS)
        .systemDefault
        #else
        if let sound = NotificationBuiltinSoundCatalog.sound(id: level.defaultBuiltinSoundID) {
            return .builtin(sound)
        }
        return .none
        #endif
    }

    var body: some View {
        Group {
            if isCompactLayout {
                compactLayout
            } else {
                regularLayout
            }
        }
        .padding(.vertical, isCompactLayout ? 12 : 10)
    }

    private var regularLayout: some View {
        HStack(spacing: 18) {
            levelLabel
                .frame(width: 86, alignment: .leading)
            soundPicker
                .frame(minWidth: 220, maxWidth: .infinity)
            if showsTunableSoundControls {
                HStack(spacing: 16) {
                    lengthField
                    volumeField
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            previewButton
        }
    }

    private var compactLayout: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                levelLabel
                Spacer(minLength: 8)
                previewButton
            }

            soundPicker

            if showsTunableSoundControls {
                HStack(spacing: 8) {
                    lengthField
                        .frame(maxWidth: .infinity)
                    volumeField
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var lengthField: some View {
        NotificationSoundIntegerField(
            title: localizationManager.localized("length"),
            value: Int((rule.durationSeconds ?? 5).rounded()),
            range: Int(NotificationSoundCompiler.minimumDurationSeconds.rounded())...Int(NotificationSoundCompiler.maximumDurationSeconds.rounded()),
            step: 5,
            suffix: "s"
        ) { seconds in
            onDurationChanged(Double(seconds))
        }
        .environment(\.notificationSoundIntegerFieldCompact, isCompactLayout)
        .environment(\.notificationSoundIntegerFieldFixedWidth, isCompactLayout ? nil : 158)
    }

    private var showsTunableSoundControls: Bool {
        rule.mode == .builtin || rule.mode == .custom
    }

    private var canPreviewSound: Bool {
        rule.mode == .builtin || rule.mode == .custom
    }

    private var volumeField: some View {
        NotificationSoundIntegerField(
            title: localizationManager.localized("volume"),
            value: Int((rule.gain * 100).rounded()),
            range: Int((NotificationSoundCompiler.minimumGain * 100).rounded())...Int((NotificationSoundCompiler.maximumGain * 100).rounded()),
            step: 5,
            suffix: "%"
        ) { percent in
            onGainChanged(Double(percent) / 100)
        }
        .environment(\.notificationSoundIntegerFieldCompact, isCompactLayout)
        .environment(\.notificationSoundIntegerFieldFixedWidth, isCompactLayout ? nil : 170)
    }

    private var levelLabel: some View {
        HStack(spacing: 8) {
            Image(systemName: level.systemImageName)
                .font(.callout.weight(.semibold))
                .foregroundStyle(tone.foreground)
                .frame(width: 18)
            Text(localizedLevelName)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
        }
    }

    private var soundPicker: some View {
        Menu {
            #if os(macOS)
            Button(localizationManager.localized("notification_sound_system_default")) {
                onOptionChanged(.systemDefault)
            }

            Divider()
            #endif

            if allowsSilentOption {
                Button(localizationManager.localized("none")) {
                    onOptionChanged(.none)
                }

                Divider()
            }

            if !customAssets.isEmpty {
                ForEach(customAssets) { asset in
                    Button(asset.displayName) {
                        onOptionChanged(.custom(asset))
                    }
                }

                Divider()
            }

            ForEach(NotificationBuiltinSoundCatalog.sounds) { sound in
                Button(sound.displayName) {
                    onOptionChanged(.builtin(sound))
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(selectedOptionTitle)
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.appTextSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: isCompactLayout ? 38 : 32, alignment: .leading)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.appSurfaceRaised)
            )
        }
        .buttonStyle(.plain)
        .transientPresentationActionControl()
        .accessibilityLabel(localizationManager.localized("sound_for_priority_placeholder", localizedLevelName))
    }

    private var previewButton: some View {
        Button {
            onPreview()
        } label: {
            Image(systemName: isPreviewing ? "stop.circle.fill" : "play.circle.fill")
                .font(.title3)
                .foregroundStyle(Color.appAccentPrimary)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.appPlain)
        .disabled(!canPreviewSound)
        .opacity(!canPreviewSound ? 0.35 : 1)
        .accessibilityLabel(
            isPreviewing
                ? localizationManager.localized("stop_sound_preview_placeholder", localizedLevelName)
                : localizationManager.localized("preview_sound_placeholder", localizedLevelName)
        )
    }

    private var tone: AppSemanticTone {
        switch level {
        case .critical:
            return .danger
        case .high:
            return .warning
        case .normal:
            return .info
        case .low:
            return .neutral
        }
    }

    private var localizedLevelName: String {
        switch level {
        case .critical:
            return localizationManager.localized("message_severity_critical")
        case .high:
            return localizationManager.localized("message_severity_high")
        case .normal:
            return localizationManager.localized("normal")
        case .low:
            return localizationManager.localized("message_severity_low")
        }
    }

    private var selectedOptionTitle: String {
        switch selectedOption {
        case .systemDefault:
            return localizationManager.localized("notification_sound_system_default")
        case .none:
            return localizationManager.localized("none")
        case let .custom(asset):
            return asset.displayName
        case let .builtin(sound):
            return sound.displayName
        }
    }
}

private struct NotificationSoundIntegerField: View {
    let title: String
    let value: Int
    let range: ClosedRange<Int>
    let step: Int
    let suffix: String
    let onCommit: (Int) -> Void

    @Environment(\.notificationSoundIntegerFieldCompact) private var isCompactLayout
    @Environment(\.notificationSoundIntegerFieldFixedWidth) private var fixedWidth
    @FocusState private var isFocused: Bool
    @State private var text = ""
    @Environment(LocalizationManager.self) private var localizationManager

    private var controlHeight: CGFloat {
        isCompactLayout ? 38 : 32
    }

    var body: some View {
        HStack(alignment: .center, spacing: isCompactLayout ? 2 : 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.appTextSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .frame(
                    minWidth: isCompactLayout ? 38 : 44,
                    maxWidth: isCompactLayout ? 44 : 56,
                    minHeight: controlHeight,
                    alignment: .center
                )

            stepButton(systemName: "minus") {
                applyDelta(-step)
            }

            TextField(title, text: $text)
                .textFieldStyle(.plain)
                .font(.subheadline.monospacedDigit())
                .multilineTextAlignment(.trailing)
                .frame(width: isCompactLayout ? 28 : 34)
                .frame(height: controlHeight)
                .focused($isFocused)
                .onSubmit {
                    commitDraft()
                }
#if os(iOS)
                .keyboardType(.numberPad)
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button(localizationManager.localized("done")) {
                            commitDraft()
                            isFocused = false
                        }
                    }
                }
#endif

            Text(suffix)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.appTextSecondary)
                .frame(width: isCompactLayout ? 10 : 12, height: controlHeight, alignment: .center)

            stepButton(systemName: "plus") {
                applyDelta(step)
            }
        }
        .frame(height: controlHeight)
        .padding(.horizontal, isCompactLayout ? 5 : 8)
        .notificationSoundIntegerFieldWidth(fixedWidth)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.appSurfaceRaised)
        )
        .onAppear {
            refreshDraft()
        }
        .onChange(of: value) { _, _ in
            if !isFocused {
                refreshDraft()
            }
        }
        .onChange(of: isFocused) { _, focused in
            if !focused {
                commitDraft()
            }
        }
    }

    private func stepButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.caption.weight(.bold))
                .frame(width: isCompactLayout ? 24 : 28, height: controlHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .transientPresentationActionControl()
    }

    private func refreshDraft() {
        text = String(value)
    }

    private func commitDraft() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Int(trimmed) else {
            refreshDraft()
            return
        }
        let clamped = min(max(parsed, range.lowerBound), range.upperBound)
        text = String(clamped)
        if clamped != value {
            onCommit(clamped)
        }
    }

    private func applyDelta(_ delta: Int) {
        let current = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? value
        let updated = min(max(current + delta, range.lowerBound), range.upperBound)
        text = String(updated)
        if updated != value {
            onCommit(updated)
        }
    }
}

private struct NotificationSoundIntegerFieldCompactKey: EnvironmentKey {
    static let defaultValue = false
}

private struct NotificationSoundIntegerFieldFixedWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

private extension EnvironmentValues {
    var notificationSoundIntegerFieldCompact: Bool {
        get { self[NotificationSoundIntegerFieldCompactKey.self] }
        set { self[NotificationSoundIntegerFieldCompactKey.self] = newValue }
    }

    var notificationSoundIntegerFieldFixedWidth: CGFloat? {
        get { self[NotificationSoundIntegerFieldFixedWidthKey.self] }
        set { self[NotificationSoundIntegerFieldFixedWidthKey.self] = newValue }
    }
}

private extension View {
    @ViewBuilder
    func notificationSoundIntegerFieldWidth(_ fixedWidth: CGFloat?) -> some View {
        if let fixedWidth {
            frame(width: fixedWidth)
        } else {
            frame(maxWidth: .infinity)
        }
    }
}

private struct NotificationSoundLibraryRow<TrailingAction: View>: View {
    let title: String
    let isPreviewing: Bool
    let onPreview: () -> Void
    let trailingAction: TrailingAction
    @Environment(LocalizationManager.self) private var localizationManager

    init(
        title: String,
        isPreviewing: Bool,
        onPreview: @escaping () -> Void,
        @ViewBuilder trailingAction: () -> TrailingAction
    ) {
        self.title = title
        self.isPreviewing = isPreviewing
        self.onPreview = onPreview
        self.trailingAction = trailingAction()
    }

    init(
        title: String,
        isPreviewing: Bool,
        onPreview: @escaping () -> Void
    ) where TrailingAction == EmptyView {
        self.title = title
        self.isPreviewing = isPreviewing
        self.onPreview = onPreview
        self.trailingAction = EmptyView()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)

            Spacer(minLength: 8)

            Button {
                onPreview()
            } label: {
                Image(systemName: isPreviewing ? "stop.circle.fill" : "play.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Color.appAccentPrimary)
            }
            .buttonStyle(.appPlain)
            .accessibilityLabel(
                isPreviewing
                    ? localizationManager.localized("stop_preview_item_placeholder", title)
                    : localizationManager.localized("preview_item_placeholder", title)
            )

            trailingAction
        }
        .padding(.vertical, 7)
    }
}
