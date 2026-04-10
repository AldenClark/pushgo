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
    static let buttonHeight: CGFloat = 36
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
            .foregroundStyle(Color.appTextSecondary)
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
            .foregroundStyle(Color.appTextSecondary)
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
            .foregroundStyle(Color.appTextPrimary)
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
            .foregroundStyle(Color.appTextSecondary)
    }
}

struct AppFieldChevron: View {
    var body: some View {
        Image(systemName: "chevron.up.chevron.down")
            .font(.caption)
            .foregroundStyle(Color.appTextSecondary)
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
                .foregroundStyle(Color.appTextSecondary)
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

enum AppActionButtonVariant {
    case primary
    case secondary
    case plain
}

struct AppActionButton<Label: View>: View {
    let variant: AppActionButtonVariant
    let role: ButtonRole?
    let isLoading: Bool
    let fullWidth: Bool
    let action: () -> Void
    private let label: Label

    init(
        variant: AppActionButtonVariant = .primary,
        role: ButtonRole? = nil,
        isLoading: Bool = false,
        fullWidth: Bool = true,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) {
        self.variant = variant
        self.role = role
        self.isLoading = isLoading
        self.fullWidth = fullWidth
        self.action = action
        self.label = label()
    }

    init(
        _ title: LocalizedStringKey,
        variant: AppActionButtonVariant = .primary,
        role: ButtonRole? = nil,
        isLoading: Bool = false,
        fullWidth: Bool = true,
        action: @escaping () -> Void
    ) where Label == Text {
        self.init(
            variant: variant,
            role: role,
            isLoading: isLoading,
            fullWidth: fullWidth,
            action: action
        ) {
            Text(title)
        }
    }

    init(
        title: String,
        variant: AppActionButtonVariant = .primary,
        role: ButtonRole? = nil,
        isLoading: Bool = false,
        fullWidth: Bool = true,
        action: @escaping () -> Void
    ) where Label == Text {
        self.init(
            variant: variant,
            role: role,
            isLoading: isLoading,
            fullWidth: fullWidth,
            action: action
        ) {
            Text(title)
        }
    }

    init(
        text: Text,
        variant: AppActionButtonVariant = .primary,
        role: ButtonRole? = nil,
        isLoading: Bool = false,
        fullWidth: Bool = true,
        action: @escaping () -> Void
    ) where Label == Text {
        self.init(
            variant: variant,
            role: role,
            isLoading: isLoading,
            fullWidth: fullWidth,
            action: action
        ) {
            text
        }
    }

    var body: some View {
        let button = Button(role: role, action: action) {
            ZStack {
                label
                    .opacity(isLoading ? 0 : 1)
                    .frame(maxWidth: fullWidth ? .infinity : nil)
                if isLoading {
                    ProgressView()
                }
            }
            .frame(minHeight: AppControlMetrics.buttonHeight)
            .frame(maxWidth: fullWidth ? .infinity : nil)
        }
        .disabled(isLoading)

        switch variant {
        case .primary:
            button.buttonStyle(.borderedProminent)
        case .secondary:
            button.buttonStyle(.bordered)
        case .plain:
            button.buttonStyle(.plain)
        }
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
        let strokeWidth = isFocused ? AppControlMetrics.focusedStrokeWidth : AppControlMetrics.unfocusedStrokeWidth
        let strokeColor = isFocused ? Color.appInputStrokeFocused : Color.appInputStrokeUnfocused

        return RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.appInputFieldFill)
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(strokeColor, lineWidth: strokeWidth)
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

struct AppInsetDivider: View {
    var color: Color = .appDividerSubtle
    var leadingInset: CGFloat = 0
    var trailingInset: CGFloat = 0
    var verticalPadding: CGFloat = 0
    var thickness: CGFloat = 1

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(height: thickness)
            .padding(.leading, leadingInset)
            .padding(.trailing, trailingInset)
            .padding(.vertical, verticalPadding)
            .accessibilityHidden(true)
    }
}

struct AppStatusDot: View {
    var color: Color = .appAccentPrimary
    var size: CGFloat = 8
    var accessibilityLabel: LocalizedStringKey? = nil

    var body: some View {
        Group {
            if let accessibilityLabel {
                Circle()
                    .fill(color)
                    .frame(width: size, height: size)
                    .accessibilityLabel(Text(accessibilityLabel))
            } else {
                Circle()
                    .fill(color)
                    .frame(width: size, height: size)
                    .accessibilityHidden(true)
            }
        }
    }
}

struct AppCapsuleBadge<Content: View>: View {
    let foreground: Color
    let background: Color
    var border: Color? = nil
    var horizontalPadding: CGFloat = 8
    var verticalPadding: CGFloat = 4
    let content: Content

    init(
        foreground: Color,
        background: Color,
        border: Color? = nil,
        horizontalPadding: CGFloat = 8,
        verticalPadding: CGFloat = 4,
        @ViewBuilder content: () -> Content,
    ) {
        self.foreground = foreground
        self.background = background
        self.border = border
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(
                Capsule(style: .continuous)
                    .fill(background)
            )
            .overlay {
                if let border {
                    Capsule(style: .continuous)
                        .stroke(border, lineWidth: 1)
                }
            }
            .foregroundStyle(foreground)
    }
}

struct AppIconTile: View {
    let systemName: String
    var foreground: Color = .appAccentPrimary
    var background: Color = .appInfoIconBackground
    var size: CGFloat = 32
    var cornerRadius: CGFloat = 10
    var font: Font = .callout.weight(.semibold)

    var body: some View {
        Image(systemName: systemName)
            .font(font)
            .frame(width: size, height: size)
            .foregroundStyle(foreground)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(background)
            )
    }
}

struct SettingsRowDivider: View {
    private let leadingInset: CGFloat = 48

    var body: some View {
        AppInsetDivider(leadingInset: leadingInset, verticalPadding: 18)
    }
}

struct DataPageToggleGroupRow: View {
    let iconName: String
    let title: LocalizedStringKey
    let messageTitle: LocalizedStringKey
    let eventTitle: LocalizedStringKey
    let thingTitle: LocalizedStringKey
    @Binding var messageIsOn: Bool
    @Binding var eventIsOn: Bool
    @Binding var thingIsOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AppIconTile(systemName: iconName)

            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)

                HStack(spacing: 8) {
                    DataPageToggleChip(
                        title: messageTitle,
                        isOn: $messageIsOn,
                        accessibilityID: "toggle.settings.page.messages"
                    )
                    DataPageToggleChip(
                        title: eventTitle,
                        isOn: $eventIsOn,
                        accessibilityID: "toggle.settings.page.events"
                    )
                    DataPageToggleChip(
                        title: thingTitle,
                        isOn: $thingIsOn,
                        accessibilityID: "toggle.settings.page.things"
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12)
    }
}

private struct DataPageToggleChip: View {
    let title: LocalizedStringKey
    @Binding var isOn: Bool
    let accessibilityID: String

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 4) {
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.bold))
                }
                Text(title)
                    .lineLimit(1)
            }
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(isOn ? Color.appAccentPrimary : Color.appTextSecondary)
            .background(
                Capsule(style: .continuous)
                    .fill(isOn ? Color.appStateInfoBackground : Color.clear)
            )
            .overlay {
                Capsule(style: .continuous)
                    .stroke(
                        isOn ? AppSemanticTone.info.border : Color.appBorderSubtle,
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(.appPlain)
        .accessibilityIdentifier(accessibilityID)
        .accessibilityValue(isOn ? Text("On") : Text("Off"))
    }
}

struct SettingsActionRow<Trailing: View>: View {
    enum Style {
        case plain
        case destructive
    }

    let iconName: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey?
    let style: Style
    private let trailing: () -> Trailing
    @Environment(\.isEnabled) private var isEnabled

    init(
        iconName: String,
        title: LocalizedStringKey,
        detail: LocalizedStringKey? = nil,
        style: Style = .plain,
        @ViewBuilder trailing: @escaping () -> Trailing,
    ) {
        self.iconName = iconName
        self.title = title
        self.detail = detail
        self.style = style
        self.trailing = trailing
    }

    private var iconTint: Color {
        switch style {
        case .plain:
            return .appAccentPrimary
        case .destructive:
            return AppSemanticTone.danger.foreground
        }
    }

    private var iconBackground: Color {
        switch style {
        case .plain:
            return .appInfoIconBackground
        case .destructive:
            return .appDangerIconBackground
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AppIconTile(systemName: iconName, foreground: iconTint, background: iconBackground)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)

                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(Color.appTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 12)

            trailing()
                .fixedSize()
        }
        .contentShape(Rectangle())
        .padding(.vertical, 14)
        .opacity(isEnabled ? 1 : 0.45)
    }
}

extension SettingsActionRow where Trailing == EmptyView {
    init(
        iconName: String,
        title: LocalizedStringKey,
        detail: LocalizedStringKey? = nil,
        style: Style = .plain,
    ) {
        self.init(iconName: iconName, title: title, detail: detail, style: style) {
            EmptyView()
        }
    }
}

struct SettingsControlRow<Control: View>: View {
    let iconName: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey?
    let control: Control
    let useFormField: Bool

    init(
        iconName: String,
        title: LocalizedStringKey,
        detail: LocalizedStringKey? = nil,
        useFormField: Bool = true,
        @ViewBuilder control: () -> Control,
    ) {
        self.iconName = iconName
        self.title = title
        self.detail = detail
        self.control = control()
        self.useFormField = useFormField
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AppIconTile(systemName: iconName)

            if useFormField {
                AppFormField(title) {
                    VStack(alignment: .leading, spacing: 6) {
                        if let detail {
                            AppFieldHint(detail)
                        }
                        control
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)

                    if let detail {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(Color.appTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 12)

                control
                    .fixedSize()
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 10)
    }
}

struct ManualKeyStatusBadge: View {
    let text: LocalizedStringKey
    let isConfigured: Bool

    var body: some View {
        AppCapsuleBadge(
            foreground: isConfigured ? AppSemanticTone.info.foreground : AppSemanticTone.neutral.foreground,
            background: isConfigured ? AppSemanticTone.info.background : AppSemanticTone.neutral.background,
            horizontalPadding: 10,
            verticalPadding: 4,
        ) {
            Text(text)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}

struct NotificationStatusBadge: View {
    let text: LocalizedStringKey
    let tone: AppSemanticTone

    var body: some View {
        AppCapsuleBadge(
            foreground: tone.foreground,
            background: tone.background,
            horizontalPadding: 10,
            verticalPadding: 4,
        ) {
            Text(text)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}
