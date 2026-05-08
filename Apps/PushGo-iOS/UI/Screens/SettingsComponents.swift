import Observation
import SwiftUI
import UniformTypeIdentifiers
import UIKit

enum SettingsSheet: Identifiable {
    case manualKey
    case serverManagement

    var id: String {
        switch self {
        case .manualKey:
            "manualKey"
        case .serverManagement:
            "serverManagement"
        }
    }
}

struct ManualKeySettingsSheet: View {
    @Bindable var viewModel: SettingsViewModel
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager

    var body: some View {
        navigationContainer {
            ManualKeySettingsContentView(viewModel: viewModel)
                .navigationTitle(localizationManager.localized("message_decryption"))
        }
        .accessibilityIdentifier("screen.settings.decryption")
    }
}

struct ServerManagementSheet: View {
    @Bindable var viewModel: SettingsViewModel
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager

    var body: some View {
        navigationContainer {
            ServerManagementContentView(viewModel: viewModel)
                .navigationTitle(localizationManager.localized("server_management"))
        }
    }
}

private struct ServerManagementContentView: View {
    @Bindable var viewModel: SettingsViewModel
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: ServerField?
    var onDismiss: (() -> Void)? = nil
    
    private var isUsingDefaultServerAddress: Bool {
        viewModel.gatewayInput.address
            .trimmingCharacters(in: .whitespacesAndNewlines)
            == AppConstants.defaultServerAddress
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            AppFormField(titleText: localizationManager.localized("server_address"), isFocused: focusedField == .address) {
                HStack(spacing: 10) {
                    TextField(
                        "",
                        text: $viewModel.gatewayInput.address,
                        prompt: AppFieldPrompt.text(AppConstants.defaultServerAddress)
                    )
                    .textFieldStyle(.plain)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .keyboardType(.URL)
                    .focused($focusedField, equals: .address)
                    .submitLabel(.done)
                    .onSubmit {
                        dismissKeyboard()
                        focusedField = nil
                    }

                    Button {
                        focusedField = nil
                        viewModel.restoreDefaultServerAddress()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(Color.appTextSecondary)
                    }
                    .buttonStyle(.appPlain)
                    .disabled(isUsingDefaultServerAddress)
                    .opacity(isUsingDefaultServerAddress ? 0.35 : 1)
                    .accessibilityLabel(Text(localizationManager.localized("restore_default_server_address")))
                }
            }

            AppFormField(titleText: localizationManager.localized("server_token_optional"), isFocused: focusedField == .token) {
                HStack(spacing: 10) {
                    Group {
                        if viewModel.gatewayInput.isTokenVisible {
                            TextField(
                                "",
                                text: $viewModel.gatewayInput.token,
                                prompt: AppFieldPrompt.text(localizationManager.localized("server_token_placeholder"))
                            )
                        } else {
                            SecureField(
                                "",
                                text: $viewModel.gatewayInput.token,
                                prompt: AppFieldPrompt.text(localizationManager.localized("server_token_placeholder"))
                            )
                        }
                    }
                    .textFieldStyle(.plain)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .focused($focusedField, equals: .token)
                    .submitLabel(.done)
                    .onSubmit {
                        dismissKeyboard()
                        focusedField = nil
                    }

                    Button {
                        viewModel.gatewayInput.isTokenVisible.toggle()
                    } label: {
                        Image(systemName: viewModel.gatewayInput.isTokenVisible ? "eye.slash" : "eye")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(Color.appTextSecondary)
                    }
                    .buttonStyle(.appPlain)
                    .accessibilityLabel(
                        LocalizedStringKey(viewModel.gatewayInput.isTokenVisible ? "hide_key" : "show_key")
                    )
                }
            }
            Text(localizationManager.localized("server_management_gateway_switch_warning"))
                .font(.footnote)
                .foregroundStyle(Color.appTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            AppActionButton(
                text: Text(localizationManager.localized("save_configuration"))
                    .font(.headline),
                variant: .primary,
                isLoading: viewModel.isSavingServerConfig
            ) {
                focusedField = nil
                Task { await viewModel.saveServerConfig() }
            }
            .disabled(viewModel.isSavingServerConfig)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            viewModel.prepareServerEditor()
        }
        .onChange(of: viewModel.shouldDismissServerManagement) { _, shouldDismiss in
            guard shouldDismiss else { return }
            viewModel.shouldDismissServerManagement = false
            if let onDismiss {
                onDismiss()
            } else {
                dismiss()
            }
        }
        .background {
            SettingsFocusDismissBackground {
                focusedField = nil
            }
        }
    }
}

private enum ServerField: Hashable {
    case address
    case token
}

private struct SettingsFocusDismissBackground: View {
    let dismiss: () -> Void

    var body: some View {
        Button(action: dismiss) {
            Color.clear.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHidden(true)
    }
}

private struct ManualKeySettingsContentView: View {
    @Bindable var viewModel: SettingsViewModel
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager
    @FocusState private var sheetFocus: ManualSheetField?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            keyEncodingPicker
            keyField
            Text(localizationManager
                .localized(
                    "only_aes_gcm_is_supported_iv_needs_to_be_included_by_the_sender_and_the_key_length_must_exactly_match_the_selected_number_of_bits",
                ))
                .font(.footnote)
                .foregroundStyle(Color.appTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            AppActionButton(
                text: Text(localizationManager.localized("save_configuration"))
                    .font(.headline),
                variant: .primary,
                isLoading: viewModel.isSaving
            ) {
                Task { await viewModel.saveManualKeyConfig() }
            }
            .disabled(viewModel.isSaving)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            SettingsFocusDismissBackground {
                sheetFocus = nil
            }
        }
    }

    @ViewBuilder
    private var keyEncodingPicker: some View {
        AppLabeledField(titleText: localizationManager.localized("key_format")) {
            Picker("", selection: $viewModel.manualKeyInput.encoding) {
                ForEach(SettingsViewModel.KeyEncoding.allCases) { encoding in
                    Text(encoding.displayName).tag(encoding)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel(Text(localizationManager.localized("key_format")))
        }
    }

    private var keyField: some View {
        let isFocused = sheetFocus == .manualKey
        let placeholderKey = viewModel.manualKeyInput.hasConfiguredKey
            ? "key_has_been_saved_enter_new_value_to_overwrite"
            : "enter_key"

        return Group {
            if viewModel.manualKeyInput.hasConfiguredKey {
                AppFormField(titleText: localizationManager.localized("key_content"), isFocused: isFocused, accessory: {
                    AppFieldTag(text: localizationManager.localized("saved"))
                }) {
                    HStack(spacing: 10) {
                        Group {
                            if viewModel.manualKeyInput.isSecretVisible {
                                TextField(
                                    "",
                                    text: $viewModel.manualKeyInput.key,
                                    prompt: AppFieldPrompt.text(localizationManager.localized(placeholderKey))
                                )
                            } else {
                                SecureField(
                                    "",
                                    text: $viewModel.manualKeyInput.key,
                                    prompt: AppFieldPrompt.text(localizationManager.localized(placeholderKey))
                                )
                            }
                        }
                        .textFieldStyle(.plain)
                        .font(.system(.body, design: .monospaced))
                        .focused($sheetFocus, equals: .manualKey)
                        .submitLabel(.done)
                        .onSubmit {
                            dismissKeyboard()
                            sheetFocus = nil
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)

                        Button {
                            viewModel.manualKeyInput.isSecretVisible.toggle()
                        } label: {
                            Image(systemName: viewModel.manualKeyInput.isSecretVisible ? "eye.slash" : "eye")
                                .font(.callout.weight(.medium))
                        }
                        .buttonStyle(.appPlain)
                        .accessibilityLabel(
                            LocalizedStringKey(viewModel.manualKeyInput.isSecretVisible ? "hide_key" : "show_key")
                        )
                    }
                }
            } else {
                AppFormField(titleText: localizationManager.localized("key_content"), isFocused: isFocused) {
                    HStack(spacing: 10) {
                        Group {
                            if viewModel.manualKeyInput.isSecretVisible {
                                TextField(
                                    "",
                                    text: $viewModel.manualKeyInput.key,
                                    prompt: AppFieldPrompt.text(localizationManager.localized(placeholderKey))
                                )
                            } else {
                                SecureField(
                                    "",
                                    text: $viewModel.manualKeyInput.key,
                                    prompt: AppFieldPrompt.text(localizationManager.localized(placeholderKey))
                                )
                            }
                        }
                        .textFieldStyle(.plain)
                        .font(.system(.body, design: .monospaced))
                        .focused($sheetFocus, equals: .manualKey)
                        .submitLabel(.done)
                        .onSubmit {
                            dismissKeyboard()
                            sheetFocus = nil
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)

                        Button {
                            viewModel.manualKeyInput.isSecretVisible.toggle()
                        } label: {
                            Image(systemName: viewModel.manualKeyInput.isSecretVisible ? "eye.slash" : "eye")
                                .font(.callout.weight(.medium))
                        }
                        .buttonStyle(.appPlain)
                        .accessibilityLabel(
                            LocalizedStringKey(viewModel.manualKeyInput.isSecretVisible ? "hide_key" : "show_key")
                        )
                    }
                }
            }
        }
    }
}

private enum ManualSheetField: Hashable {
    case manualKey
}

private struct SheetHeader: View {
    let title: LocalizedStringKey

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.title3.weight(.semibold))
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            AppInsetDivider()
        }
    }
}

struct MessagesExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    private enum Source {
        case messages([PushMessage])
        case preparedFile(URL)
    }
    private let source: Source

    init(messages: [PushMessage]) {
        source = .messages(messages)
    }

    init(preparedFileURL: URL) {
        source = .preparedFile(preparedFileURL)
    }

    init(configuration: ReadConfiguration) throws {
        guard let file = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([PushMessage].self, from: file)
        source = .messages(decoded)
    }

    func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
        switch source {
        case let .messages(messages):
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(messages)
            return .init(regularFileWithContents: data)
        case let .preparedFile(url):
            return try FileWrapper(url: url, options: .immediate)
        }
    }
}

struct MessageJSONExportStreamWriter {
    private let fileURL: URL
    private var fileHandle: FileHandle?
    private let encoder: JSONEncoder
    private var wroteAnyRecord = false
    private(set) var exportedCount = 0

    init(filenamePrefix: String) throws {
        let temporaryFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(filenamePrefix)-\(UUID().uuidString).json")
        guard FileManager.default.createFile(atPath: temporaryFileURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        fileURL = temporaryFileURL
        fileHandle = try FileHandle(forWritingTo: temporaryFileURL)
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try write(Data("[\n".utf8))
    }

    mutating func append(_ messages: [PushMessage]) throws {
        guard !messages.isEmpty else { return }
        for message in messages {
            if wroteAnyRecord {
                try write(Data(",\n".utf8))
            }
            let encoded = try encoder.encode(message)
            try write(encoded)
            wroteAnyRecord = true
            exportedCount += 1
        }
    }

    mutating func finish() throws -> URL {
        try write(Data("\n]".utf8))
        try closeFileHandle()
        return fileURL
    }

    mutating func discard() {
        try? closeFileHandle()
        try? FileManager.default.removeItem(at: fileURL)
    }

    private mutating func closeFileHandle() throws {
        try fileHandle?.close()
        fileHandle = nil
    }

    private func write(_ data: Data) throws {
        guard let fileHandle else {
            throw CocoaError(.fileWriteUnknown)
        }
        try fileHandle.write(contentsOf: data)
    }
}

private extension View {
    @ViewBuilder
    func customAdaptiveDetents() -> some View {
        self.pushgoSheetSizing(.form)
    }
}

private struct PlatformListStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.listStyle(.insetGrouped)
    }
}
