import SwiftUI

struct SystemIntegrationSettingsGroup: View {
    @Bindable var viewModel: SettingsViewModel
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager

    var body: some View {
        VStack(spacing: 0) {
            SettingsControlRow(
                iconName: "magnifyingglass",
                title: "system_integration",
                detail: "system_integration_detail",
                useFormField: false
            ) {
                Toggle("", isOn: binding(\.systemSearchEnabled))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            .accessibilityIdentifier("toggle.settings.system_search")

            SettingsRowDivider()

            SettingsControlRow(
                iconName: "text.alignleft",
                title: "include_message_body_in_search",
                detail: "include_message_body_in_search_detail",
                useFormField: false
            ) {
                Toggle("", isOn: binding(\.includeMessageBodyInSearch))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            .disabled(!viewModel.systemIntegrationSettings.systemSearchEnabled)
            .accessibilityIdentifier("toggle.settings.system_search_body")

            SettingsRowDivider()

            SettingsControlRow(
                iconName: "doc.text.magnifyingglass",
                title: "include_metadata_in_search",
                detail: "include_metadata_in_search_detail",
                useFormField: false
            ) {
                Toggle("", isOn: binding(\.includeMetadataInSearch))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            .disabled(!viewModel.systemIntegrationSettings.systemSearchEnabled)
            .accessibilityIdentifier("toggle.settings.system_search_metadata")

            SettingsRowDivider()

            SettingsControlRow(
                iconName: "tag",
                title: "index_events_and_objects",
                detail: "index_events_and_objects_detail",
                useFormField: false
            ) {
                Toggle("", isOn: binding(\.indexEventsAndThings))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            .disabled(!viewModel.systemIntegrationSettings.systemSearchEnabled)
            .accessibilityIdentifier("toggle.settings.system_search_entities")

            SettingsRowDivider()

            SettingsControlRow(
                iconName: "clock.badge.exclamationmark",
                title: "time_sensitive_alerts",
                detail: "time_sensitive_alerts_detail",
                useFormField: false
            ) {
                Toggle("", isOn: binding(\.timeSensitiveAlertsEnabled))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            .accessibilityIdentifier("toggle.settings.time_sensitive_alerts")

            SettingsRowDivider()

            SettingsControlRow(
                iconName: "number",
                title: "exclude_channels_from_system_search",
                detail: "exclude_channels_from_system_search_detail"
            ) {
                TextField(
                    localizationManager.localized("excluded_channels_placeholder"),
                    text: excludedChannelIDsBinding,
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
                .disabled(!viewModel.systemIntegrationSettings.systemSearchEnabled)
                .accessibilityIdentifier("field.settings.system_search_excluded_channels")
            }
            .disabled(!viewModel.systemIntegrationSettings.systemSearchEnabled)

            SettingsRowDivider()

            HStack(spacing: 12) {
                Button(localizationManager.localized("clear_system_search_index")) {
                    Task { await viewModel.clearSystemSearchIndex() }
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isRebuildingSystemSearchIndex)
                .accessibilityIdentifier("action.settings.clear_system_search_index")

                Button(localizationManager.localized("rebuild_system_search_index")) {
                    Task { await viewModel.rebuildSystemSearchIndex() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    !viewModel.systemIntegrationSettings.systemSearchEnabled
                        || viewModel.isRebuildingSystemSearchIndex
                )
                .accessibilityIdentifier("action.settings.rebuild_system_search_index")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
        }
    }

    private func binding(_ keyPath: WritableKeyPath<SystemIntegrationSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { viewModel.systemIntegrationSettings[keyPath: keyPath] },
            set: { newValue in
                viewModel.updateSystemIntegrationSettings { settings in
                    settings[keyPath: keyPath] = newValue
                }
            }
        )
    }

    private var excludedChannelIDsBinding: Binding<String> {
        Binding(
            get: {
                viewModel.systemIntegrationSettings.excludedChannelIDs
                    .sorted()
                    .joined(separator: ", ")
            },
            set: { newValue in
                viewModel.updateSystemIntegrationSettings { settings in
                    settings.excludedChannelIDs = Set(Self.parseExcludedChannelIDs(newValue))
                }
            }
        )
    }

    private static func parseExcludedChannelIDs(_ value: String) -> [String] {
        value
            .split { character in
                character == "," || character == "\n" || character == "\r"
            }
            .compactMap { SystemIntegrationSettings.normalizedChannelID(String($0)) }
    }
}
