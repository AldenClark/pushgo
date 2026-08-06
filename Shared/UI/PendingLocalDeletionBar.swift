import SwiftUI

struct PendingLocalDeletionBar: View {
    @Bindable var controller: PendingLocalDeletionController
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let deletion = controller.pendingDeletion {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                content(for: deletion, now: context.date)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func content(
        for deletion: PendingLocalDeletionController.PendingDeletion,
        now: Date
    ) -> some View {
        let remainingSeconds = max(1, Int(ceil(deletion.deadline.timeIntervalSince(now))))

        return HStack(spacing: 10) {
            Text(deletion.summary)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Text(verbatim: "· \(remainingSeconds)s")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            Button(localizedUndoLabel) {
                controller.undoCurrent()
            }
            .buttonStyle(.plain)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(backgroundStyle, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(borderColor, lineWidth: 0.8)
        }
    }

    private var localizedUndoLabel: String {
        let language = Locale.preferredLanguages.first?.lowercased() ?? ""
        if language.hasPrefix("zh") {
            return "撤销"
        }
        return "Undo"
    }

    private var backgroundStyle: some ShapeStyle {
        if colorScheme == .dark {
            return AnyShapeStyle(Color.white.opacity(0.08))
        }
        return AnyShapeStyle(.ultraThinMaterial)
    }

    private var borderColor: Color {
        colorScheme == .dark ? .white.opacity(0.08) : .black.opacity(0.08)
    }
}

extension View {
    func pendingLocalDeletionBarHost(
        environment: AppEnvironment,
        horizontalPadding: CGFloat = 12,
        bottomPadding: CGFloat = 12
    ) -> some View {
        modifier(PendingLocalDeletionBarHostModifier(
            environment: environment,
            horizontalPadding: horizontalPadding,
            bottomPadding: bottomPadding
        ))
    }
}

enum MessageHistoryCleanupRange: String, CaseIterable, Identifiable {
    case all
    case sevenDays
    case thirtyDays
    case threeMonths
    case sixMonths
    case oneYear

    var id: String { rawValue }

    var localizationKey: String {
        switch self {
        case .all: "history_cleanup_all"
        case .sevenDays: "history_cleanup_7_days"
        case .thirtyDays: "history_cleanup_30_days"
        case .threeMonths: "history_cleanup_3_months"
        case .sixMonths: "history_cleanup_6_months"
        case .oneYear: "history_cleanup_1_year"
        }
    }

    var systemImage: String {
        switch self {
        case .all: "trash.fill"
        case .sevenDays: "calendar.badge.clock"
        case .thirtyDays: "calendar"
        case .threeMonths: "clock.arrow.circlepath"
        case .sixMonths: "archivebox"
        case .oneYear: "archivebox.fill"
        }
    }

    var isDestructive: Bool { self == .all }

    func cutoff(referenceDate: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> Date? {
        switch self {
        case .all:
            nil
        case .sevenDays:
            calendar.date(byAdding: .day, value: -7, to: referenceDate) ?? .distantPast
        case .thirtyDays:
            calendar.date(byAdding: .day, value: -30, to: referenceDate) ?? .distantPast
        case .threeMonths:
            calendar.date(byAdding: .month, value: -3, to: referenceDate) ?? .distantPast
        case .sixMonths:
            calendar.date(byAdding: .month, value: -6, to: referenceDate) ?? .distantPast
        case .oneYear:
            calendar.date(byAdding: .year, value: -1, to: referenceDate) ?? .distantPast
        }
    }
}

private enum MessageHistoryCleanupPhase: Equatable {
    case confirmation
    case cleaning
    case success(Int)
    case failure(String)

    var isCleaning: Bool {
        self == .cleaning
    }
}

struct MessageHistoryCleanupRangeSheet: View {
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager
    @Environment(\.dismiss) private var dismiss

    let cleanup: @MainActor (Date?) async throws -> Int

    @State private var selectedRange: MessageHistoryCleanupRange?
    @State private var phase: MessageHistoryCleanupPhase = .confirmation

    var body: some View {
        VStack(spacing: 0) {
#if os(macOS)
            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(.secondary.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(localizationManager.localized("cancel"))
            }
#endif

            ScrollView {
                VStack(spacing: 24) {
                    MessageHistoryCleanupHeaderView(
                        title: localizationManager.localized("history_cleanup_title"),
                        detail: localizationManager.localized("history_cleanup_sheet_detail")
                    )

                    VStack(spacing: 10) {
                        ForEach(MessageHistoryCleanupRange.allCases) { range in
                            MessageHistoryCleanupRangeCard(
                                title: localizationManager.localized(range.localizationKey),
                                detail: localizationManager.localized(
                                    range.isDestructive
                                        ? "history_cleanup_all_detail"
                                        : "history_cleanup_range_detail"
                                ),
                                systemImage: range.systemImage,
                                isDestructive: range.isDestructive
                            ) {
                                phase = .confirmation
                                selectedRange = range
                            }
                        }
                    }
                }
                .padding(.bottom, 28)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
#if os(iOS)
        .frame(maxWidth: .infinity, minHeight: 560)
#else
        .frame(minWidth: 380, idealWidth: 440, minHeight: 560)
#endif
        .background(Color.primary.opacity(0.025))
#if os(iOS)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
#endif
        .sheet(item: $selectedRange) { range in
            MessageHistoryCleanupStatusSheet(
                phase: phase,
                onCancel: {
                    selectedRange = nil
                    phase = .confirmation
                },
                onConfirm: {
                    beginCleanup(range: range)
                },
                onClose: {
                    selectedRange = nil
                    phase = .confirmation
                    dismiss()
                }
            )
#if os(iOS)
            .presentationDetents([.height(320)])
            .presentationDragIndicator(.visible)
#endif
            .interactiveDismissDisabled(phase.isCleaning)
        }
        .interactiveDismissDisabled(selectedRange != nil)
    }

    private func beginCleanup(range: MessageHistoryCleanupRange) {
        guard phase == .confirmation else { return }
        phase = .cleaning
        Task { @MainActor in
            do {
                phase = .success(try await cleanup(range.cutoff()))
            } catch {
                phase = .failure(error.localizedDescription)
            }
        }
    }
}

private struct MessageHistoryCleanupHeaderView: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 58, height: 58)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))

            VStack(spacing: 6) {
                Text(title)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 360)
    }
}

private struct MessageHistoryCleanupRangeCard: View {
    let title: String
    let detail: String
    let systemImage: String
    let isDestructive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 42, height: 42)
                    .background(iconColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 13))

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(isDestructive ? Color.red : Color.primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 17))
            .overlay {
                RoundedRectangle(cornerRadius: 17)
                    .strokeBorder(.primary.opacity(0.07), lineWidth: 0.8)
            }
            .contentShape(RoundedRectangle(cornerRadius: 17))
        }
        .buttonStyle(.plain)
    }

    private var iconColor: Color {
        isDestructive ? .red : .accentColor
    }
}

private struct MessageHistoryCleanupStatusSheet: View {
    let phase: MessageHistoryCleanupPhase
    let onCancel: () -> Void
    let onConfirm: () -> Void
    let onClose: () -> Void

    var body: some View {
        MessageHistoryCleanupStatusContent(
            phase: phase,
            onCancel: onCancel,
            onConfirm: onConfirm,
            onClose: onClose
        )
        .modifier(MessageHistoryCleanupStatusSheetLayout())
    }
}

private struct MessageHistoryCleanupStatusSheetLayout: ViewModifier {
    func body(content: Content) -> some View {
#if os(iOS)
        content
            .padding(.horizontal, 24)
            .padding(.vertical, 28)
            .frame(maxWidth: 440)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
#else
        content
            .padding(28)
            .frame(minWidth: 380, idealWidth: 420)
#endif
    }
}

private struct MessageHistoryCleanupStatusContent: View {
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager

    let phase: MessageHistoryCleanupPhase
    let onCancel: () -> Void
    let onConfirm: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            MessageHistoryCleanupStatusHeader(
                phase: phase,
                title: title,
                detail: detail
            )

            MessageHistoryCleanupActions(
                phase: phase,
                cancelTitle: localizationManager.localized("cancel"),
                confirmTitle: localizationManager.localized("history_cleanup_confirm_action"),
                doneTitle: localizationManager.localized("done"),
                onCancel: onCancel,
                onConfirm: onConfirm,
                onClose: onClose
            )
        }
    }

    private var title: String {
        switch phase {
        case .confirmation:
            localizationManager.localized("history_cleanup_confirm_title")
        case .cleaning:
            localizationManager.localized("history_cleanup_cleaning")
        case .success:
            localizationManager.localized("history_cleanup_complete")
        case .failure:
            localizationManager.localized("history_cleanup_failed")
        }
    }

    private var detail: String {
        switch phase {
        case .confirmation:
            localizationManager.localized("history_cleanup_confirm_detail")
        case .cleaning:
            localizationManager.localized("history_cleanup_cleaning_detail")
        case let .success(count):
            localizationManager.localized("history_cleanup_success", count)
        case let .failure(message):
            message
        }
    }

}

private struct MessageHistoryCleanupStatusHeader: View {
    let phase: MessageHistoryCleanupPhase
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 17)
                    .fill(accentColor.opacity(0.12))
                    .frame(width: 56, height: 56)
                statusIcon
            }

            VStack(spacing: 6) {
                Text(title)
                    .font(.title3.weight(.bold))
                    .multilineTextAlignment(.center)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch phase {
        case .confirmation:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(.red)
        case .cleaning:
            ProgressView().controlSize(.large)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 29, weight: .semibold))
                .foregroundStyle(.green)
        case .failure:
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.red)
        }
    }

    private var accentColor: Color {
        switch phase {
        case .success: .green
        case .confirmation, .failure: .red
        case .cleaning: .accentColor
        }
    }
}

private struct MessageHistoryCleanupActions: View {
    let phase: MessageHistoryCleanupPhase
    let cancelTitle: String
    let confirmTitle: String
    let doneTitle: String
    let onCancel: () -> Void
    let onConfirm: () -> Void
    let onClose: () -> Void

    var body: some View {
        switch phase {
        case .confirmation:
            HStack(spacing: 12) {
                Button(action: onCancel) {
                    Text(cancelTitle)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                Button(action: onConfirm) {
                    Text(confirmTitle)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.red)
            }
            .frame(maxWidth: 360)
        case .cleaning:
            EmptyView()
        case .success, .failure:
            Button(doneTitle, action: onClose)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
        }
    }

}

private struct PendingLocalDeletionBarHostModifier: ViewModifier {
    @Bindable var environment: AppEnvironment
    let horizontalPadding: CGFloat
    let bottomPadding: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        environment: AppEnvironment,
        horizontalPadding: CGFloat,
        bottomPadding: CGFloat
    ) {
        _environment = Bindable(environment)
        self.horizontalPadding = horizontalPadding
        self.bottomPadding = bottomPadding
    }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if environment.pendingLocalDeletionController.pendingDeletion != nil {
                    PendingLocalDeletionBar(
                        controller: environment.pendingLocalDeletionController
                    )
                    .padding(.horizontal, horizontalPadding)
                    .padding(.bottom, bottomPadding)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.25),
                value: environment.pendingLocalDeletionController.pendingDeletion
            )
    }
}
