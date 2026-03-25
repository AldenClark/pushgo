import Foundation
import SwiftUI

struct MessageSearchScreen: View {
    private let embedsInNavigationContainer: Bool

    init(embedInNavigationContainer: Bool = true) {
        embedsInNavigationContainer = embedInNavigationContainer
    }

    var body: some View {
        MessageSearchScreenModern(embedInNavigationContainer: embedsInNavigationContainer)
    }
}

private struct MessageSearchScreenModern: View {
    private let embedsInNavigationContainer: Bool

    @Environment(AppEnvironment.self) private var environment: AppEnvironment
    @Environment(MessageSearchViewModel.self) private var viewModel: MessageSearchViewModel
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager

    @State private var selectedMessage: PushMessageSummary?
    @FocusState private var focusedField: SearchFieldFocus?

    init(embedInNavigationContainer: Bool) {
        embedsInNavigationContainer = embedInNavigationContainer
    }

    var body: some View {
        Group {
            if embedsInNavigationContainer {
                navigationContainer {
                    searchScaffold
                }
            } else {
                searchScaffold
            }
        }
        .onChange(of: environment.messageStoreRevision) { _, _ in
            viewModel.refreshMessagesIfNeeded()
        }
        .onChange(of: viewModel.query) { _, newValue in
#if DEBUG
            PushGoAutomationRuntime.shared.recordSearchResultsUpdated(
                query: newValue,
                resultCount: viewModel.totalResults
            )
#endif
        }
        .onChange(of: viewModel.totalResults) { _, newValue in
#if DEBUG
            PushGoAutomationRuntime.shared.recordSearchResultsUpdated(
                query: viewModel.query,
                resultCount: newValue
            )
#endif
        }
        .sheet(item: $selectedMessage) { message in
            MessageDetailScreen(messageId: message.id, message: nil)
                .pushgoSheetSizing(.detail)
        }
        .searchableOnSupportedPlatforms(binding: searchFieldBinding)
    }

    private var searchScaffold: some View {
        ScrollView {
            VStack(spacing: EntityVisualTokens.detailSectionSpacing) {
                if isSearchBarVisibleOnThisPlatform {
                    searchBar
                }

                searchStateContent
            }
            .padding(.vertical, EntityVisualTokens.detailPaddingVertical)
            .padding(.horizontal, EntityVisualTokens.detailPaddingHorizontal)
        }
        .background(EntityVisualTokens.pageBackground.ignoresSafeArea())
        .modifier(MessageSearchScrollDismissModifier())
        .simultaneousGesture(dismissTapGesture, including: .subviews)
        .navigationBarTitleDisplayMode(.inline)
    }
    private var isSearchBarVisibleOnThisPlatform: Bool {
        false
    }

    private var searchBar: some View {
        AppFormField("search_messages", isFocused: focusedField == .query) {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                        .accessibilityHidden(true)

                    TextField("search_messages", text: searchFieldBinding)
                        .textFieldStyle(.plain)
                        .focused($focusedField, equals: .query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .submitLabel(.search)

                    if !viewModel.query.isEmpty {
                        Button {
                            viewModel.updateQuery("")
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.appPlain)
                        .accessibilityLabel("clear_search")
                    }
                }

                if isCancelButtonVisible {
                    Button("cancel") {
                        cancelSearch()
                    }
                    .foregroundColor(.accentColor)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
        }
    }

    @ViewBuilder
    private var searchStateContent: some View {
        if !viewModel.hasSearched {
            MessageSearchPlaceholderView(
                imageName: "magnifyingglass",
                title: "start_your_search",
                detailKey: "enter_any_keyword_to_quickly_locate_messages_from_historical_push_notifications",
            )
            .frame(maxWidth: .infinity, minHeight: 240)
        } else if viewModel.displayedResults.isEmpty {
            MessageSearchPlaceholderView(
                imageName: "questionmark.circle",
                title: "no_matching_results",
                detailKey: "try_changing_a_keyword_or_clear_the_filter_conditions",
            )
            .frame(maxWidth: .infinity, minHeight: 240)
        } else {
            resultsSection
        }
    }

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: EntityVisualTokens.detailSectionSpacing) {
            Text(localizationManager.localized("found_number_results", viewModel.totalResults))
                .font(.headline)

            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(viewModel.displayedResults.enumerated()), id: \.element.id) { index, message in
                    Button {
                        selectMessage(message)
                    } label: {
                        MessageSearchResultRow(message: message, query: viewModel.query)
                            .padding(.vertical, EntityVisualTokens.listRowInsetVertical)
                    }
                    .buttonStyle(.appPlain)
                    .contentShape(Rectangle())
                    .onAppear {
                        viewModel.loadMoreIfNeeded(currentItem: message)
                    }

                    if index < viewModel.displayedResults.count - 1 {
                        Divider()
                            .padding(.vertical, EntityVisualTokens.rowVerticalPadding)
                    }
                }

                if viewModel.hasMore {
                    HStack {
                        Spacer()
                        ProgressView()
                            .progressViewStyle(.circular)
                        Spacer()
                    }
                    .padding(.vertical, EntityVisualTokens.listRowInsetVertical)
                }
            }
        }
    }

    private func selectMessage(_ message: PushMessageSummary) {
        if message.isRead == false {
            Task {
                await environment.markMessage(message.id, isRead: true)
            }
        }
        selectedMessage = message
    }

    private func cancelSearch() {
        guard !viewModel.query.isEmpty || focusedField != nil else { return }
        viewModel.updateQuery("")
        dismissSearchFocusIfNeeded()
    }

    private var searchFieldBinding: Binding<String> {
        Binding(
            get: { viewModel.query },
            set: { newValue in viewModel.updateQuery(newValue) },
        )
    }

    private var isCancelButtonVisible: Bool {
        focusedField != nil || !viewModel.query.isEmpty
    }

    private var dismissTapGesture: some Gesture {
        TapGesture().onEnded { dismissSearchFocusIfNeeded() }
    }
}

private enum SearchFieldFocus: Hashable {
    case query
}

private struct MessageSearchScrollDismissModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        content.scrollDismissesKeyboard(.interactively)
    }
}

private extension MessageSearchScreenModern {
    func dismissSearchFocusIfNeeded() {
        guard focusedField != nil else { return }
        focusedField = nil
        dismissKeyboard()
    }
}

private extension View {
    @ViewBuilder
    func searchableOnSupportedPlatforms(binding: Binding<String>) -> some View {
        self.searchable(text: binding, prompt: "search_messages")
    }
}

struct MessageSearchPlaceholderView: View {
    let imageName: String
    let title: String
    let detailKey: String
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: imageName)
                .font(.largeTitle.weight(.semibold))
                .foregroundColor(.secondary)
                .accessibilityHidden(true)

            Text(localizationManager.localized(title))
                .font(.headline)

            Text(localizationManager.localized(detailKey))
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }
}

struct MessageSearchResultRow: View {
    let message: PushMessageSummary
    let query: String
    @Environment(AppEnvironment.self) private var environment: AppEnvironment
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        HighlightedText(text: message.title, query: query)
                            .font(.headline)
                            .foregroundColor(.primary)
                            .lineLimit(2)

                        if message.isEncrypted {
                            Image(systemName: "lock.fill")
                                .font(.caption.bold())
                                .foregroundColor(.accentColor)
                                .accessibilityLabel(localizationManager.localized("encrypted_message"))
                        }
                    }

                    HighlightedText(text: message.bodyPreview, query: query)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(4)

                    HStack(spacing: 12) {
                        Label(
                            message.receivedAt.pushgoSearchResultTimestamp(),
                            systemImage: "clock",
                        )
                        .font(.caption)
                        .foregroundColor(.secondary)

                        if let channelName = environment.channelDisplayName(for: message.channel) {
                            Label(channelName, systemImage: "square.stack.3d.up")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        if message.isRead == false {
                            Label(localizationManager.localized("unread"), systemImage: "envelope.badge")
                                .font(.caption2)
                                .foregroundColor(.accentColor)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let imageURL = message.imageURL {
                    RemoteImageView(url: imageURL, rendition: .listThumbnail) { image in
                        image
                            .resizable()
                            .scaledToFill()
                    } placeholder: {
                        RoundedRectangle(cornerRadius: EntityVisualTokens.radiusSmall, style: .continuous)
                            .fill(EntityVisualTokens.subtleFill)
                    }
                    .accessibilityLabel(LocalizedStringKey("image_attachment"))
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: EntityVisualTokens.radiusSmall, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: EntityVisualTokens.radiusSmall, style: .continuous)
                            .stroke(EntityVisualTokens.subtleStroke, lineWidth: 0.6),
                    )
                }
            }
        }
        .padding(.vertical, EntityVisualTokens.rowVerticalPadding + 2)
        .accessibilityElement(children: .combine)
    }
}

private extension Date {
    func pushgoSearchResultTimestamp() -> String {
        MessageTimestampFormatter.listTimestamp(for: self)
    }
}

private struct HighlightedText: View {
    let text: String
    let query: String

    var body: some View {
        highlight(text: text, query: query)
    }

    private func highlight(text: String, query: String) -> Text {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Text(text)
        }

        let pattern = NSRegularExpression.escapedPattern(for: trimmed)
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive],
        ) else {
            return Text(text)
        }

        let nsText = text as NSString
        let matches = regex.matches(
            in: text,
            options: [],
            range: NSRange(location: 0, length: nsText.length),
        )
        guard !matches.isEmpty else {
            return Text(text)
        }

        var result = Text("")
        var currentLocation = 0

        for match in matches {
            if match.range.location > currentLocation {
                let range = NSRange(
                    location: currentLocation,
                    length: match.range.location - currentLocation,
                )
                let substring = nsText.substring(with: range)
                result = Text("\(result)\(substring)")
            }

            let highlight = nsText.substring(with: match.range)
            result = Text("\(result)\(highlight)")
                .foregroundColor(Color.accentColor)
                .fontWeight(.semibold)

            currentLocation = match.range.location + match.range.length
        }

        if currentLocation < nsText.length {
            let range = NSRange(
                location: currentLocation,
                length: nsText.length - currentLocation,
            )
            let substring = nsText.substring(with: range)
            result = Text("\(result)\(substring)")
        }

        return result
    }
}
