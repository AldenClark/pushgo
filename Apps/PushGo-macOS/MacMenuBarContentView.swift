
import SwiftUI
import AppKit

struct MacMenuBarContentView: View {
    @Environment(AppEnvironment.self) private var environment: AppEnvironment
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel = MenuBarViewModel()
    @State private var listContentHeight: CGFloat = 0
    @State private var isRefreshing: Bool = false
    private let unreadMessageCount: Int = 8

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal,12)

                Divider()

                if viewModel.unreadMessages.isEmpty {
                    emptyState
                } else {
                    messageList
                }
            }
            .frame(width: 360)
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1),
            )
        }
        .onAppear { refresh() }
        .onChange(of: scenePhase) { _, newValue in
            if newValue == .active {
                refresh()
            }
        }
    }

    private func refresh() {
        Task { @MainActor in
            guard !isRefreshing else { return }
            isRefreshing = true
            await viewModel.refreshUnread(maxCount: unreadMessageCount)
            isRefreshing = false
        }
    }

    private func openMain() {
        MainWindowController.shared.showMainWindow()
        dismiss()
    }

    private func openMessage(_ message: PushMessageSummary) {
        Task { @MainActor in
            if message.isRead == false {
                await environment.markMessage(message.id, isRead: true)
            }
            environment.pendingMessageToOpen = message.id
            MainWindowController.shared.showMainWindow()
        }
    }

    private var channelSummary: String {
        let items = environment.channelSubscriptions
        if items.isEmpty {
            return localizationManager.localized("channels_empty")
        }
        if items.count == 1 {
            return items[0].displayName
        }
        return localizationManager.localized("channels_count_placeholder", items.count)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.title2)
                .foregroundColor(.secondary)
            Text(
                localizationManager.localized(
                    "placeholder_no_unread_messages"
                )
            )
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private var messageList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(viewModel.unreadMessages.enumerated()), id: \.element.id) { index, message in
                    if index > 0 {
                        Divider().padding(.horizontal, 12)
                    }
                    messageRow(for: message)
                }
            }
            .background(GeometryReader {
                Color.clear.preference(key: ListHeightKey.self, value: $0.size.height)
            })
        }
        .background(Color.clear)
        .onPreferenceChange(ListHeightKey.self) { height in
            listContentHeight = height
        }
        .frame(height: min(listContentHeight, 600))
        .frame(maxWidth: .infinity)
    }

    private func messageRow(for message: PushMessageSummary) -> some View {
        Button {
            openMessage(message)
        } label: {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        if !message.isRead {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 8, height: 8)
                                .padding(.trailing, 4)
                            Text(localizationManager.localized("unread"))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Text(message.title)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text(menuGroupName(for: message))
                        .font(.subheadline)
                        .lineLimit(1)
                        .foregroundColor(.secondary)

                    Text(MessageTimestampFormatter.listTimestamp(for: message.receivedAt))
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.7))
                }
                Spacer()
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
        }
        .buttonStyle(.appPlain)
        .contentShape(Rectangle())
    }

    private var header: some View {
        HStack {
            Text("PushGo")
                .font(.headline)
            
            Spacer()
            
            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power")
            }
            .help(localizationManager.localized("quit_application"))
            .accessibilityLabel(localizationManager.localized("quit_application"))

            Button(action: openMain) {
                Image(systemName: "macwindow")
            }
            .help(localizationManager.localized("open_main_window"))
            .accessibilityLabel(localizationManager.localized("open_main_window"))
        }
        .buttonStyle(.appPlain)
        .foregroundColor(.secondary)
        .imageScale(.medium)
    }

    private func menuGroupName(for message: PushMessageSummary) -> String {
        if let channelName = environment.channelDisplayName(for: message.channel) {
            return channelName
        }
        return localizationManager.localized("not_grouped")
    }
}

private struct ListHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
