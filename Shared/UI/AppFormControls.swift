import SwiftUI

enum AppControlMetrics {
    static let fieldHeight: CGFloat = 48
    static let multilineMinHeight: CGFloat = 80
    static let fieldVerticalPadding: CGFloat = 8
    static let fieldHorizontalPadding: CGFloat = 12
    static let fieldCornerRadius: CGFloat = 10
    static let multilineCornerRadius: CGFloat = 12
    static let labelSpacing: CGFloat = 8
    static let labelAccessorySize: CGFloat = 14
    static let focusedStrokeWidth: CGFloat = 1
    static let unfocusedStrokeWidth: CGFloat = 0.8
    static let focusedStrokeOpacity: Double = 0.3
    static let unfocusedStrokeOpacity: Double = 0.08
    static let fieldFillOpacity: Double = 0.02
    static let buttonHeight: CGFloat = 50
}

struct AppLabeledField<Content: View, Accessory: View>: View {
    private let title: Text
    private let accessory: Accessory
    private let content: Content

    init(_ title: Text, @ViewBuilder content: () -> Content) where Accessory == EmptyView {
        self.title = title
        self.accessory = EmptyView()
        self.content = content()
    }

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) where Accessory == EmptyView {
        self.title = Text(title)
        self.accessory = EmptyView()
        self.content = content()
    }

    init(titleText: String, @ViewBuilder content: () -> Content) where Accessory == EmptyView {
        self.title = Text(titleText)
        self.accessory = EmptyView()
        self.content = content()
    }

    init(
        _ title: Text,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.accessory = accessory()
        self.content = content()
    }

    init(
        _ title: LocalizedStringKey,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) {
        self.title = Text(title)
        self.accessory = accessory()
        self.content = content()
    }

    init(
        titleText: String,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) {
        self.title = Text(titleText)
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppControlMetrics.labelSpacing) {
            HStack(alignment: .center, spacing: 6) {
                title
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                accessory
            }
            content
        }
    }
}

struct AppFormField<Content: View, Accessory: View>: View {
    private let title: Text
    private let accessory: Accessory
    private let content: Content
    private let isFocused: Bool
    private let isMultiline: Bool

    init(
        _ title: LocalizedStringKey,
        isFocused: Bool = false,
        isMultiline: Bool = false,
        @ViewBuilder content: () -> Content
    ) where Accessory == EmptyView {
        self.title = Text(title)
        self.accessory = EmptyView()
        self.content = content()
        self.isFocused = isFocused
        self.isMultiline = isMultiline
    }

    init(
        titleText: String,
        isFocused: Bool = false,
        isMultiline: Bool = false,
        @ViewBuilder content: () -> Content
    ) where Accessory == EmptyView {
        self.title = Text(titleText)
        self.accessory = EmptyView()
        self.content = content()
        self.isFocused = isFocused
        self.isMultiline = isMultiline
    }

    init(
        _ title: LocalizedStringKey,
        isFocused: Bool = false,
        isMultiline: Bool = false,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) {
        self.title = Text(title)
        self.accessory = accessory()
        self.content = content()
        self.isFocused = isFocused
        self.isMultiline = isMultiline
    }

    init(
        titleText: String,
        isFocused: Bool = false,
        isMultiline: Bool = false,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) {
        self.title = Text(titleText)
        self.accessory = accessory()
        self.content = content()
        self.isFocused = isFocused
        self.isMultiline = isMultiline
    }

    var body: some View {
        AppLabeledField(title, accessory: { accessory }) {
            content
                .appInputContainerStyle(isFocused: isFocused, isMultiline: isMultiline)
        }
    }
}

struct AppFieldHint: View {
    private let text: Text

    init(_ text: LocalizedStringKey) {
        self.text = Text(text)
    }

    init(text: String) {
        self.text = Text(text)
    }

    var body: some View {
        text
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}

struct AppFieldTag: View {
    private let text: Text

    init(_ text: LocalizedStringKey) {
        self.text = Text(text)
    }

    init(text: String) {
        self.text = Text(text)
    }

    var body: some View {
        text
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

struct AppFieldValue: View {
    private let text: Text

    init(text: String) {
        self.text = Text(text)
    }

    var body: some View {
        text
            .font(.body)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

struct AppFieldSecondaryText: View {
    private let text: Text

    init(text: String) {
        self.text = Text(text)
    }

    var body: some View {
        text
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

struct AppFieldChevron: View {
    var body: some View {
        Image(systemName: "chevron.up.chevron.down")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

struct AppFormAccessoryButton: View {
    let systemName: String
    let action: () -> Void
    var accessibilityLabel: Text? = nil

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(
                    width: AppControlMetrics.labelAccessorySize,
                    height: AppControlMetrics.labelAccessorySize,
                    alignment: .center
                )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityLabel(accessibilityLabel ?? Text(systemName))
    }
}

enum AppFieldPrompt {
    static func key(_ key: LocalizedStringKey) -> Text {
        Text(key).font(.footnote)
    }

    static func text(_ text: String) -> Text {
        Text(text).font(.footnote)
    }
}

struct AppInputBackground: View {
    let isFocused: Bool
    let isMultiline: Bool

    var body: some View {
        let radius = isMultiline ? AppControlMetrics.multilineCornerRadius : AppControlMetrics.fieldCornerRadius
        let strokeOpacity = isFocused ? AppControlMetrics.focusedStrokeOpacity : AppControlMetrics.unfocusedStrokeOpacity
        let strokeWidth = isFocused ? AppControlMetrics.focusedStrokeWidth : AppControlMetrics.unfocusedStrokeWidth
        let base = Color.accentColor.opacity(AppControlMetrics.fieldFillOpacity)

        return RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(base)
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Color.primary.opacity(strokeOpacity), lineWidth: strokeWidth)
            )
    }
}

enum AppButtonMetrics {
    static let baseHeight: CGFloat = AppControlMetrics.buttonHeight
}

struct AppPlainButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(minHeight: AppButtonMetrics.baseHeight)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct AppBorderlessButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(minHeight: AppButtonMetrics.baseHeight)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

extension ButtonStyle where Self == AppPlainButtonStyle {
    static var appPlain: AppPlainButtonStyle { AppPlainButtonStyle() }
}

extension ButtonStyle where Self == AppBorderlessButtonStyle {
    static var appBorderless: AppBorderlessButtonStyle { AppBorderlessButtonStyle() }
}

extension View {
    func appInputContainerStyle(
        isFocused: Bool = false,
        isMultiline: Bool = false
    ) -> some View {
        let alignment: Alignment = isMultiline ? .top : .center
        return padding(.vertical, AppControlMetrics.fieldVerticalPadding)
            .padding(.horizontal, AppControlMetrics.fieldHorizontalPadding)
            .frame(
                minHeight: isMultiline ? AppControlMetrics.multilineMinHeight : nil,
                alignment: alignment
            )
            .frame(
                height: isMultiline ? nil : AppControlMetrics.fieldHeight,
                alignment: alignment
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppInputBackground(isFocused: isFocused, isMultiline: isMultiline))
    }

    func appInputTextFieldStyle(isFocused: Bool = false, isMultiline: Bool = false) -> some View {
        textFieldStyle(.plain)
            .appInputContainerStyle(isFocused: isFocused, isMultiline: isMultiline)
    }

    func appButtonHeight() -> some View {
        frame(minHeight: AppButtonMetrics.baseHeight)
    }
}
