import SwiftUI
import UserNotifications
import UIKit

struct PushScreen: View {
    @Environment(\.appEnvironment) private var environment: AppEnvironment
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager
    @Environment(\.openURL) private var openURLAction
    @State private var isSendingTestPush = false
    @State private var isSendingLocalTestPush = false
    @FocusState private var focusedField: TestFormField?
    @State private var alertTopic: InfoTopic?
    @State private var sheetTopic: InfoTopic?
    @State private var isChannelPickerPresented = false
    @State private var channelFieldWidth: CGFloat = 0
    @State private var testForm: TestPushForm
    @State private var lastDefaultTitle: String
    @State private var lastDefaultBody: String
    @State private var customSoundFilenames: [String] = []

    init() {
        let defaultTitle = LocalizationManager.localizedSync("pushgo_test_notification")
        let defaultBody = LocalizationManager.localizedSync(
            "this_is_a_local_test_notification_used_to_verify_the_push_display_effect"
        )
        _testForm = State(initialValue: TestPushForm(defaultTitle: defaultTitle, defaultBody: defaultBody))
        _lastDefaultTitle = State(initialValue: defaultTitle)
        _lastDefaultBody = State(initialValue: defaultBody)
    }

    var body: some View {
        navigationContainer {
            platformWrappedContent
        }
        .onChange(of: localizationManager.locale) { _, _ in
            refreshDefaultTestFormContent()
        }
        .onAppear {
            prefillChannelIfNeeded()
            refreshCustomSoundFilenames()
        }
        .onChange(of: environment.channelSubscriptions) { _, _ in
            prefillChannelIfNeeded()
        }
        .alert(item: $alertTopic) { topic in
            Alert(
                title: Text(topic.title),
                message: Text(topic.message),
                dismissButton: .default(Text(localizationManager.localized("ok"))),
            )
        }
        .sheet(item: $sheetTopic) { topic in
            let titleKey = topic.sheetTitleKey ?? topic.title
            let messageText = topic.sheetMessageKey.map { localizationManager.localized($0) } ?? topic.message
            let codeText = topic.codeSampleKey.map { localizationManager.localized($0) }
            FieldInfoScreen(
                title: titleKey,
                message: messageText,
                codeSample: codeText,
                kind: topic.kind,
                sampleTitle: localizationManager.localized("ciphertext_sample_title"),
                l10n: localizationManager,
            )
            .presentationDetents([.large])
        }
    }

    @ViewBuilder
    private var platformWrappedContent: some View {
        formContent
            .navigationTitle(localizationManager.localized("push"))
    }

    @ViewBuilder
    private var formContent: some View {
        defaultFormContent
    }

    private var defaultFormContent: some View {
        ScrollView {
            contentStack
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
        }
        .background(pageBackground.ignoresSafeArea())
        .scrollDismissesKeyboardIfAvailable()
        .onTapGesture { focusedField = nil }
    }

    private var contentStack: some View {
        VStack(alignment: .leading, spacing: 16) {
            infoNotice
            basicContentFields
            notificationOptionFields
            mediaFields
            sendButtons
                .frame(maxWidth: .infinity)
            gatewayJsonPreview
        }
    }

    private var infoNotice: some View {
        let accent = Color.accentColor
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(accent.opacity(0.14))
                    Image(systemName: "sparkles")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(accent)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 6) {
                    Text(localizationManager.localized("push_form_hint_title"))
                        .font(.headline.weight(.semibold))
                    Text(localizationManager.localized("push_form_hint_body"))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let gateway = environment.serverConfig?.baseURL ?? AppConstants.defaultServerURL {
                HStack(spacing: 8) {
                    Label(localizationManager.localized("push_gateway"), systemImage: "link")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                    Spacer(minLength: 8)
                    Button {
                        copyToClipboard(gateway.absoluteString)
                        environment.showToast(
                            message: localizationManager.localized("gateway_copied"),
                            style: .success,
                            duration: 1.2,
                        )
                    } label: {
                        Text(gateway.absoluteString)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .foregroundColor(accent)
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(accent.opacity(0.08)),
                )
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [accent.opacity(0.06), accent.opacity(0.025)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing,
                    ),
                ),
        )
    }

    @ViewBuilder
    private var basicContentFields: some View {
        channelField

        inputField(
            title: "title",
            placeholder: localizationManager.localized("placeholder_title"),
            text: $testForm.title,
            focus: .title,
        )

        multilineField(
            title: "text",
            placeholder: localizationManager.localized("placeholder_body"),
            text: $testForm.body,
            focus: .body,
            infoKey: "info_body_md",
        )
    }

    @ViewBuilder
    private var channelField: some View {
        let selected = resolveSelectedChannel()
        AppFormField(titleText: localizationManager.localized("channel_id")) {
            if environment.channelSubscriptions.isEmpty {
                AppFieldHint(text: localizationManager.localized("channel_select_empty_hint"))
            } else {
                Button {
                    isChannelPickerPresented = true
                    focusedField = nil
                } label: {
                    HStack(spacing: 10) {
                        AppFieldValue(text: formattedChannelLabel(selected))
                        Spacer(minLength: 8)
                        AppFieldChevron()
                    }
                }
                .buttonStyle(.plain)
                .popover(
                    isPresented: $isChannelPickerPresented,
                    attachmentAnchor: .rect(.bounds),
                    arrowEdge: .bottom
                ) {
                    channelPickerPopover
                        .presentationCompactAdaptation(.popover)
                }
            }
        }
        .background(WidthReader(width: $channelFieldWidth))
    }

    private var channelPickerPopover: some View {
        let subscriptions = environment.channelSubscriptions
        return ScrollView {
            VStack(spacing: 0) {
                ForEach(subscriptions) { subscription in
                    Button {
                        testForm.channel = subscription.channelId
                        focusedField = nil
                        isChannelPickerPresented = false
                    } label: {
                        AppFieldValue(text: formattedChannelLabel(subscription))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                    }
                    .buttonStyle(.appPlain)

                    if subscription.id != subscriptions.last?.id {
                        Divider()
                    }
                }
            }
        }
        .frame(width: max(channelFieldWidth, 320))
        .frame(maxHeight: 320)
    }

    private func formattedChannelLabel(_ subscription: ChannelSubscription) -> String {
        let trimmedId = subscription.channelId.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = String(trimmedId.suffix(6))
        let name = subscription.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            return suffix
        }
        if suffix.isEmpty {
            return name
        }
        return "\(name) \(suffix)"
    }

    @ViewBuilder
    private var notificationOptionFields: some View {
        inputField(
            title: "url_or_deep_link",
            placeholder: localizationManager.localized("placeholder_url"),
            text: $testForm.url,
            focus: .url,
            keyboard: .URL,
            infoKey: "info_url_or_deep_link",
        )

        soundSelector
    }

    @ViewBuilder
    private var mediaFields: some View {
        inputField(
            title: "icon_url",
            placeholder: localizationManager.localized("placeholder_icon"),
            text: $testForm.icon,
            focus: .icon,
            keyboard: .URL,
        )

        inputField(
            title: "image_url",
            placeholder: localizationManager.localized("placeholder_image"),
            text: $testForm.image,
            focus: .image,
            keyboard: .URL,
        )

        inputField(
            title: "ciphertext",
            placeholder: localizationManager.localized("optional_encrypted_message_content"),
            text: $testForm.ciphertext,
            focus: .ciphertext,
            autocapitalization: .never,
            infoKey: "info_ciphertext",
        )
    }

    private func cardSection(
        title: LocalizedStringKey,
        detail: String? = nil,
        hasSeparator: Bool = true,
        @ViewBuilder content: () -> some View,
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline.weight(.semibold))
                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(spacing: 14) {
                content()
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                if hasSeparator {
                    Divider().opacity(0.08)
                        .padding(.top, 8)
                }
            }
        )
    }

    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(localizationManager.localized("push"))
                    .font(.title3.weight(.semibold))
                Spacer()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()
        }
        .background(pageBackground)
    }

    private var pageBackground: Color {
        Color(UIColor.systemBackground)
    }

    enum FormKeyboard {
        case `default`
        case URL
        case numberPad
    }

    enum FormAutocapitalization {
        case never
    }

    private func inputField(
        title: LocalizedStringKey,
        placeholder: String,
        text: Binding<String>,
        focus: TestFormField,
        keyboard: FormKeyboard = .default,
        autocapitalization: FormAutocapitalization? = nil,
        infoKey: String? = nil,
    ) -> some View {
        let isFocused = focusedField == focus
        return Group {
            if let infoKey {
                AppFormField(title, isFocused: isFocused, accessory: {
                    infoButton(titleKey: title, messageKey: infoKey)
                }) {
                    TextField("", text: text, prompt: AppFieldPrompt.text(placeholder))
                        .textFieldStyle(.plain)
                        .focused($focusedField, equals: focus)
                        .submitLabel(.done)
                        .onSubmit {
                            dismissKeyboard()
                            focusedField = nil
                        }
                        .keyboardType(keyboard.uiKitType)
                        .textInputAutocapitalization(autocapitalization?.swiftUIType ?? .sentences)
                        .autocorrectionDisabled(true)
                }
            } else {
                AppFormField(title, isFocused: isFocused) {
                    TextField("", text: text, prompt: AppFieldPrompt.text(placeholder))
                        .textFieldStyle(.plain)
                        .focused($focusedField, equals: focus)
                        .submitLabel(.done)
                        .onSubmit {
                            dismissKeyboard()
                            focusedField = nil
                        }
                        .keyboardType(keyboard.uiKitType)
                        .textInputAutocapitalization(autocapitalization?.swiftUIType ?? .sentences)
                        .autocorrectionDisabled(true)
                }
            }
        }
    }

    private func multilineField(
        title: LocalizedStringKey,
        placeholder: String,
        text: Binding<String>,
        focus: TestFormField,
        infoKey: String? = nil,
    ) -> some View {
        let isFocused = focusedField == focus
        return Group {
            if let infoKey {
                AppFormField(title, isFocused: isFocused, isMultiline: true, accessory: {
                    infoButton(titleKey: title, messageKey: infoKey)
                }) {
                    TextField("", text: text, prompt: AppFieldPrompt.text(placeholder), axis: .vertical)
                        .lineLimit(2 ... 5)
                        .textFieldStyle(.plain)
                        .focused($focusedField, equals: focus)
                }
            } else {
                AppFormField(title, isFocused: isFocused, isMultiline: true) {
                    TextField("", text: text, prompt: AppFieldPrompt.text(placeholder), axis: .vertical)
                        .lineLimit(2 ... 5)
                        .textFieldStyle(.plain)
                        .focused($focusedField, equals: focus)
                }
            }
        }
    }

    private var soundSelector: some View {
        AppFormField(titleText: localizationManager.localized("ring")) {
            Menu {
                Button(localizationManager.localized("sound_not_set")) {
                    testForm.sound = nil
                }
                ForEach(availableSoundOptions) { option in
                    Button {
                        testForm.sound = option
                    } label: {
                        Text(option.displayName(localizationManager: localizationManager))
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    AppFieldValue(
                        text: testForm.sound?.displayName(localizationManager: localizationManager)
                            ?? localizationManager.localized("sound_not_set")
                    )
                    Spacer(minLength: 8)
                    AppFieldChevron()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
    }

    private func copyToClipboard(_ value: String) {
        UIPasteboard.general.string = value
    }

    private func infoButton(titleKey: LocalizedStringKey, messageKey: String) -> some View {
        AppFormAccessoryButton(systemName: "questionmark.circle", action: {
            if messageKey == "info_ciphertext" {
                sheetTopic = InfoTopic(
                    title: titleKey,
                    message: "",
                    sheetTitleKey: "ciphertext",
                    sheetMessageKey: nil,
                    codeSampleKey: "ciphertext_code_sample",
                    kind: .ciphertext,
                )
            } else if messageKey == "info_body_md" {
                sheetTopic = InfoTopic(
                    title: titleKey,
                    message: "",
                    sheetTitleKey: "body_md",
                    sheetMessageKey: "info_body_md_intro",
                    codeSampleKey: nil,
                    kind: .markdown,
                )
            } else {
                let message = localizationManager.localized(messageKey)
                alertTopic = InfoTopic(title: titleKey, message: message)
            }
        }, accessibilityLabel: Text(localizationManager.localized(messageKey)))
    }

    private var sendButtons: some View {
        let trimmedChannel = testForm.channel.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTitle = testForm.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = testForm.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let isChannelSelected = !trimmedChannel.isEmpty
        let hasContent = !trimmedTitle.isEmpty || !trimmedBody.isEmpty
        let isBusy = isSendingTestPush || isSendingLocalTestPush
        return VStack(spacing: 10) {
            Button {
                Task { await sendLocalTestMessage() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "bell.fill")
                    Text(localizationManager.localized("send_local_test_notification"))
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .appButtonHeight()
            .disabled(isBusy || !hasContent)

            Button {
                Task { await sendTestPushMessage() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "paperplane.fill")
                    Text(localizationManager.localized("send_gateway_test_notification"))
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .appButtonHeight()
            .disabled(isBusy || !isChannelSelected)
        }
    }

    private var gatewayJsonPreview: some View {
        let jsonText = formattedGatewayJSON()
        return VStack(alignment: .leading, spacing: 8) {
            if let jsonText {
                Text(jsonText)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(.primary)
                    .contextMenu {
                        Button {
                            copyToClipboard(jsonText)
                        } label: {
                            Text(localizationManager.localized("copy_content"))
                        }
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.primary.opacity(0.04))
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @MainActor
    private func sendTestPushMessage() async {
        guard environment.pushRegistrationService.authorizationState == .authorized else {
            environment
                .showToast(message: localizationManager
                    .localized("please_enable_notification_permission_in_system_settings_first"))
            return
        }
        guard !isSendingTestPush else { return }
        isSendingTestPush = true
        defer { isSendingTestPush = false }

        let trimmedTitle = testForm.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedChannel = testForm.channel.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedChannel.isEmpty else {
            environment.showToast(message: localizationManager.localized("channel_select_empty_hint"))
            return
        }

        guard !trimmedTitle.isEmpty else {
            environment.showToast(message: localizationManager.localized("please_fill_in_the_complete_title_and_text"))
            return
        }

        guard let baseURL = resolveGatewayBaseURL() else {
            environment.showToast(message: AppError.invalidURL.localizedDescription)
            return
        }

        let gatewayKey = environment.serverConfig?.gatewayKey ?? baseURL.absoluteString
        let storedPassword = await environment.dataStore.channelPassword(
            gateway: gatewayKey,
            for: trimmedChannel
        ) ?? ""
        let resolvedPassword: String
        do {
            resolvedPassword = try ChannelPasswordValidator.validate(storedPassword)
        } catch {
            environment.showToast(message: error.localizedDescription)
            return
        }

        let payload = buildGatewayPayload(password: resolvedPassword)

        do {
            try await sendGatewayPush(
                payload: payload,
                baseURL: baseURL,
                token: environment.serverConfig?.token
            )
            environment.showToast(
                message: localizationManager.localized("test_notification_triggered"),
                style: .success,
                duration: 1.5,
            )
        } catch let appError as AppError {
            environment.showToast(message: appError.localizedDescription)
        } catch {
            environment.showToast(message: error.localizedDescription)
        }
    }

    private func scheduleLocalTestNotification(
        with content: UNMutableNotificationContent,
        identifier: String
    ) async throws {
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: trigger,
        )
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            UNUserNotificationCenter.current().add(request) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    @MainActor
    private func sendLocalTestMessage() async {
        guard environment.pushRegistrationService.authorizationState == .authorized else {
            environment
                .showToast(message: localizationManager
                    .localized("please_enable_notification_permission_in_system_settings_first"))
            return
        }
        guard !isSendingLocalTestPush else { return }
        isSendingLocalTestPush = true
        defer { isSendingLocalTestPush = false }

        let trimmedChannel = testForm.channel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedChannel.isEmpty,
              environment.channelSubscriptions.contains(where: { $0.channelId == trimmedChannel })
        else {
            environment.showToast(message: localizationManager.localized("channel_select_empty_hint"))
            return
        }

        let trimmedTitle = testForm.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = testForm.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty || !trimmedBody.isEmpty else {
            environment.showToast(message: localizationManager.localized("please_fill_in_the_complete_title_and_text"))
            return
        }

        let identifier = UUID().uuidString
        let payload = buildGatewayPayload(password: nil)

        let content = UNMutableNotificationContent()
        content.title = trimmedTitle
        content.body = trimmedBody
        content.userInfo = payload
        content.threadIdentifier = trimmedChannel
        if let soundName = testForm.sound?.soundName, !soundName.isEmpty {
            content.sound = UNNotificationSound(named: UNNotificationSoundName(soundName))
        } else {
            content.sound = .default
        }
        if let category = payload["category"] as? String, !category.isEmpty {
            content.categoryIdentifier = category
        }

        do {
            try await scheduleLocalTestNotification(with: content, identifier: identifier)
            environment.showToast(
                message: localizationManager.localized("test_notification_triggered"),
                style: .success,
                duration: 1.5,
            )
        } catch {
            environment.showToast(message: error.localizedDescription)
        }
    }

    private func buildGatewayPayload(password: String?) -> [String: Any] {
        let trimmedChannel = testForm.channel.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTitle = testForm.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = testForm.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let urlString = testForm.url.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCategory = testForm.category.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedIcon = testForm.icon.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedImage = testForm.image.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCiphertext = testForm.ciphertext.trimmingCharacters(in: .whitespacesAndNewlines)
        var payload: [String: Any] = ["title": trimmedTitle]
        if !trimmedChannel.isEmpty {
            payload["channel_id"] = trimmedChannel
            if let password {
                payload["password"] = password
            }
        }
        if !trimmedBody.isEmpty { payload["body"] = trimmedBody }
        if let resolvedURL = URLSanitizer.resolveHTTPSURL(from: urlString) {
            payload["url"] = resolvedURL.absoluteString
        }
        if !trimmedCategory.isEmpty { payload["category"] = trimmedCategory }
        if !trimmedIcon.isEmpty { payload["icon"] = trimmedIcon }
        if !trimmedImage.isEmpty { payload["image"] = trimmedImage }
        if !trimmedCiphertext.isEmpty { payload["ciphertext"] = trimmedCiphertext }

        if let selectedSoundName = testForm.sound?.soundName, !selectedSoundName.isEmpty {
            payload["sound"] = selectedSoundName
        }

        return payload
    }

    private var availableSoundOptions: [TestSoundOption] {
        TestSoundOption.allOptions(customFilenames: customSoundFilenames)
    }

    private func refreshCustomSoundFilenames() {
        customSoundFilenames = Self.loadCustomSoundFilenames()
    }

    private static func loadCustomSoundFilenames() -> [String] {
        let fileManager = FileManager.default
        guard let containerURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: AppConstants.appGroupIdentifier
        ) else {
            return []
        }
        let soundsDirectory = containerURL.appendingPathComponent(
            AppConstants.customRingtoneRelativePath,
            isDirectory: true
        )
        guard let files = try? fileManager.contentsOfDirectory(
            at: soundsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let longPrefix = AppConstants.longRingtonePrefix
        return files
            .filter { !$0.hasDirectoryPath }
            .map(\.lastPathComponent)
            .filter { !$0.hasPrefix(longPrefix) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func formattedGatewayJSON() -> String? {
        let payload = buildGatewayPayload(password: "********")
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(
                  withJSONObject: payload,
                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func resolveGatewayBaseURL() -> URL? {
        environment.serverConfig?.baseURL ?? AppConstants.defaultServerURL
    }

    private func sendGatewayPush(
        payload: [String: Any],
        baseURL: URL,
        token: String?
    ) async throws {
        guard JSONSerialization.isValidJSONObject(payload) else {
            throw AppError.invalidURL
        }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw AppError.invalidURL
        }
        var path = components.path
        if path.hasSuffix("/") {
            path.removeLast()
        }
        components.path = path + "/push"
        guard let url = components.url else {
            throw AppError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = AppConstants.deviceRegistrationTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppError.serverUnreachable
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw AppError.authFailed
        }

        let decoded = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let message = decoded?["error"] as? String,
           !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            throw AppError.unknown(message)
        }
        if let success = decoded?["success"] as? Bool, success {
            return
        }
        guard (200...299).contains(http.statusCode) else {
            throw AppError.serverUnreachable
        }
    }

    private func prefillChannelIfNeeded() {
        let trimmed = testForm.channel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = environment.channelSubscriptions.first else {
            testForm.channel = ""
            return
        }
        if trimmed.isEmpty || environment.channelSubscriptions.contains(where: { $0.channelId == trimmed }) == false {
            testForm.channel = first.channelId
        }
    }

    private func resolveSelectedChannel() -> ChannelSubscription {
        if let match = environment.channelSubscriptions.first(where: { $0.channelId == testForm.channel }) {
            return match
        }
        return environment.channelSubscriptions.first ?? ChannelSubscription(
            channelId: "",
            displayName: "",
            updatedAt: Date(),
            lastSyncedAt: nil,
            autoCleanupEnabled: true
        )
    }

    private func refreshDefaultTestFormContent() {
        let newDefaultTitle = localizationManager.localized("pushgo_test_notification")
        let newDefaultBody = localizationManager.localized(
            "this_is_a_local_test_notification_used_to_verify_the_push_display_effect"
        )

        let titleIsDefaultOrEmpty = testForm.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || testForm.title == lastDefaultTitle
        let bodyIsDefaultOrEmpty = testForm.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || testForm.body == lastDefaultBody

        if titleIsDefaultOrEmpty {
            testForm.title = newDefaultTitle
        }
        if bodyIsDefaultOrEmpty {
            testForm.body = newDefaultBody
        }

        lastDefaultTitle = newDefaultTitle
        lastDefaultBody = newDefaultBody
    }
}

extension PushScreen.FormKeyboard {
    var uiKitType: UIKeyboardType {
        switch self {
        case .default:
            .default
        case .URL:
            .URL
        case .numberPad:
            .numberPad
        }
    }
}

extension PushScreen.FormAutocapitalization {
    var swiftUIType: TextInputAutocapitalization {
        switch self {
        case .never:
            .never
        }
    }
}

extension View {
    @ViewBuilder
    func scrollDismissesKeyboardIfAvailable() -> some View {
        self.scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder
    func applyUnderlineIfAvailable(color: Color? = nil) -> some View {
        if let color {
            self.underline(true, color: color)
        } else {
            self.underline()
        }
    }

    @ViewBuilder
    func applyGroupedFormStyle() -> some View {
        self.formStyle(.grouped)
    }
}

private enum TestSoundOption: Hashable, Identifiable {
    case builtIn(String)
    case custom(String)

    var id: String {
        switch self {
        case let .builtIn(id):
            id
        case let .custom(filename):
            filename
        }
    }

    static func allOptions(customFilenames: [String]) -> [TestSoundOption] {
        let builtIn: [TestSoundOption] = BuiltInRingtone.catalog.map { TestSoundOption.builtIn($0.id) }
        let custom: [TestSoundOption] = customFilenames.map { TestSoundOption.custom($0) }
        return custom + builtIn
    }

    func displayName(localizationManager _: LocalizationManager) -> String {
        switch self {
        case let .builtIn(id):
            if let ringtone = BuiltInRingtone.catalogById[id] {
                return "\(ringtone.displayName) (\(ringtone.filename))"
            }
            return id
        case let .custom(filename):
            return filename
        }
    }

    var soundName: String {
        switch self {
        case let .builtIn(id):
            return BuiltInRingtone.catalogById[id]?.filename ?? ""
        case let .custom(filename):
            return filename
        }
    }
}

private struct InfoTopic: Identifiable {
    let id = UUID()
    let title: LocalizedStringKey
    let message: String
    let sheetTitleKey: LocalizedStringKey?
    let sheetMessageKey: String?
    let codeSampleKey: String?
    let kind: InfoKind

    init(
        title: LocalizedStringKey,
        message: String,
        sheetTitleKey: LocalizedStringKey? = nil,
        sheetMessageKey: String? = nil,
        codeSampleKey: String? = nil,
        kind: InfoKind = .plain,
    ) {
        self.title = title
        self.message = message
        self.sheetTitleKey = sheetTitleKey
        self.sheetMessageKey = sheetMessageKey
        self.codeSampleKey = codeSampleKey
        self.kind = kind
    }
}

private enum InfoKind {
    case plain
    case ciphertext
    case markdown
}

private struct FieldInfoScreen: View {
    let title: LocalizedStringKey
    let message: String
    let codeSample: String?
    let kind: InfoKind
    let sampleTitle: String
    let l10n: LocalizationManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        contentView()
    }

    @ViewBuilder
    private func contentView() -> some View {
        let messageLines = message.trimmedLines
        let core = ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !messageLines.isEmpty {
                    header(lines: messageLines)
                }
                switch kind {
                case .ciphertext:
                    steps
                    if let codeSample { example(codeSample) }
                    tips
                case .markdown:
                    markdownSpec
                    markdownExample
                    markdownFallbackNote
                case .plain:
                    tips
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        NavigationView {
            core
                .navigationTitle(title)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        if kind != .ciphertext {
                            Button(l10n.localized("close")) {
                                dismiss()
                            }
                        }
                    }
                }
        }
        .navigationViewStyle(.stack)
    }

    private func header(lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(.body)
                    .foregroundColor(.primary)
                    .compatTextSelectionEnabled()
            }
        }
    }

    @ViewBuilder
    private var steps: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(l10n.localized("ciphertext_steps_title"))
                .font(.headline.weight(.semibold))
            stepRow(icon: "list.bullet.rectangle", text: l10n.localized("ciphertext_step_structure"))
            stepRow(icon: "key.fill", text: l10n.localized("ciphertext_step_encrypt"))
            stepRow(icon: "arrow.down.doc", text: l10n.localized("ciphertext_step_send"))
            stepRow(icon: "tray.and.arrow.down.fill", text: l10n.localized("ciphertext_step_apply"))
            stepRow(icon: "checkmark.shield", text: l10n.localized("ciphertext_step_requirements"))
        }
    }

    @ViewBuilder
    private func example(_ sample: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(sampleTitle)
                .font(.headline.weight(.semibold))
            codeBlock(sample)
        }
    }

    private var tips: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(l10n.localized("ciphertext_tips_title"), systemImage: "lightbulb")
                .font(.subheadline.weight(.semibold))
            Text(l10n.localized("ciphertext_tips_text"))
                .font(.body)
                .foregroundColor(.primary)
                .compatTextSelectionEnabled()
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private func codeBlock(_ text: String) -> some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Text(text)
                .font(.system(.footnote, design: .monospaced))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.accentColor.opacity(0.08), Color.primary.opacity(0.03)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing,
                            ),
                        ),
                )
        }
    }

    private func stepRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .frame(width: 22, height: 22)
                .foregroundColor(.accentColor)
                .background(
                    Circle().fill(Color.accentColor.opacity(0.12)),
                )
            Text(text)
                .font(.body)
                .foregroundColor(.primary)
                .compatTextSelectionEnabled()
        }
    }

    @ViewBuilder
    private var markdownSpec: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(l10n.localized("pushgo_markdown_supported_blocks"))
                .font(.headline.weight(.semibold))
            bulletList([
                l10n.localized("body_md_blocks_item1"),
                l10n.localized("body_md_blocks_item2"),
                l10n.localized("body_md_blocks_item3"),
            ])

            Text(l10n.localized("pushgo_markdown_supported_inlines"))
                .font(.headline.weight(.semibold))
            bulletList([
                l10n.localized("body_md_inlines_item1"),
                l10n.localized("body_md_inlines_item2"),
            ])

            Text(l10n.localized("pushgo_markdown_limits"))
                .font(.headline.weight(.semibold))
            bulletList([
                l10n.localized("body_md_limits_item1"),
                l10n.localized("body_md_limits_item2"),
                l10n.localized("body_md_limits_item3"),
            ])
        }
    }

    @ViewBuilder
    private var markdownExample: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(l10n.localized("sample"))
                .font(.headline.weight(.semibold))
            let sample = """
            # 订单提醒
            > [!info]
            > 您的订单已支付，等待发货。

            - 商品：**夜间护肤套装**
            - 金额：==¥199==（原价 ~~¥259~~）
            - 联系人：@alice
            - 订单号：123456
            | 项目 | 内容 |
            | --- | --- |
            | 收件人 | 王小明 |
            | 电话 | +86-138-0013-8000 |
            """
            codeBlock(sample)
        }
    }

    @ViewBuilder
    private var markdownFallbackNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.2.circlepath")
                .font(.title3.weight(.semibold))
                .foregroundColor(.accentColor)
            Text(l10n.localized("body_md_fallback_note"))
                .font(.body)
        }
        .padding(.top, 4)
    }

    private func bulletList(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 8) {
                    Text("•")
                        .font(.body.weight(.semibold))
                    styledInlineText(item)
                        .font(.body)
                        .foregroundColor(.primary)
                        .compatTextSelectionEnabled()
                }
            }
        }
    }

    @ViewBuilder
    private func styledInlineText(_ raw: String) -> some View {
        Text(styledInline(raw))
    }

    private func styledInline(_ raw: String) -> AttributedString {
        var result = AttributedString()
        var current = ""
        var inCode = false
        for char in raw {
            if char == "`" {
                if inCode {
                    var chunk = AttributedString(current)
                    chunk.font = .system(.body, design: .monospaced)
                    chunk.backgroundColor = Color.primary.opacity(0.08)
                    chunk.inlinePresentationIntent = .code
                    result.append(chunk)
                    current = ""
                    inCode = false
                } else {
                    if !current.isEmpty {
                        result.append(AttributedString(current))
                        current = ""
                    }
                    inCode = true
                }
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty {
            result.append(AttributedString(current))
        }
        return result
    }
}

private extension String {
    var trimmedLines: [String] {
        split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private struct TestPushForm {
    var channel: String
    var title: String
    var body: String
    var url: String
    var category: String
    var icon: String
    var image: String
    var ciphertext: String
    var sound: TestSoundOption?

    init(defaultTitle: String, defaultBody: String) {
        channel = ""
        title = defaultTitle
        body = defaultBody
        url = ""
        category = ""
        icon = ""
        image = ""
        ciphertext = ""
        sound = nil
    }
}

private enum TestFormField: Hashable {
    case channel
    case title
    case body
    case url
    case category
    case icon
    case image
    case ciphertext
}

private extension View {
    @ViewBuilder
    func compatTextSelectionEnabled() -> some View {
        textSelection(.enabled)
    }
}

private struct WidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct WidthReader: View {
    @Binding var width: CGFloat

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .preference(key: WidthPreferenceKey.self, value: proxy.size.width)
        }
        .onPreferenceChange(WidthPreferenceKey.self) { width = $0 }
    }
}
