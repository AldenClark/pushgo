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

            Text("· \(remainingSeconds)s")
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
