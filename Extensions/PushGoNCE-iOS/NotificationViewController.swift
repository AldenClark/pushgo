import SwiftUI
import UserNotifications
import UserNotificationsUI

class NotificationViewController: UIViewController, UNNotificationContentExtension {
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let bodyContainer = UIView()
    private let plainBodyLabel = UILabel()
    private let imageContainer = UIView()
    private let imageView = UIImageView()
    private var markdownHost: UIViewController?
    private var currentNotification: UNNotification?
    private var imageHeightConstraint: NSLayoutConstraint?
    private var currentBodyText = ""
    private var iconTask: Task<Void, Never>?
    private var imageTask: Task<Void, Never>?
    private var hasSetupUI = false

    private static let processStartUptime = ProcessInfo.processInfo.systemUptime

    func didReceive(_ notification: UNNotification) {
        currentNotification = notification
        configureUIIfNeeded()
        applyContent(from: notification)
        markMessageAsReadIfNeeded(for: notification)
    }

    func didReceive(
        _ response: UNNotificationResponse,
        completionHandler: @escaping (UNNotificationContentExtensionResponseOption) -> Void
    ) {
        currentNotification = response.notification
        completionHandler(.dismissAndForwardAction)
    }

    private func configureUIIfNeeded() {
        guard hasSetupUI == false else { return }
        hasSetupUI = true

        view.backgroundColor = .clear
        view.preservesSuperviewLayoutMargins = true
        imageContainer.translatesAutoresizingMaskIntoConstraints = false
        imageContainer.backgroundColor = .clear
        imageContainer.isHidden = true
        view.addSubview(imageContainer)

        imageHeightConstraint = imageContainer.heightAnchor.constraint(equalToConstant: 0)
        imageHeightConstraint?.isActive = true

        NSLayoutConstraint.activate([
            imageContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            imageContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            imageContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.backgroundColor = .clear
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: imageContainer.topAnchor),
        ])

        contentStack.axis = .vertical
        contentStack.alignment = .fill
        contentStack.distribution = .fill
        contentStack.spacing = 16
        contentStack.isLayoutMarginsRelativeArrangement = true
        contentStack.layoutMargins = UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])

        configureBodyContainer()
        configureImageContainer()
    }

    private func configureBodyContainer() {
        bodyContainer.layer.cornerRadius = 0
        bodyContainer.layer.borderWidth = 0
        bodyContainer.layer.borderColor = UIColor.clear.cgColor
        bodyContainer.clipsToBounds = false
        bodyContainer.backgroundColor = .clear
        bodyContainer.translatesAutoresizingMaskIntoConstraints = false

        plainBodyLabel.numberOfLines = 0
        plainBodyLabel.textAlignment = .left
        plainBodyLabel.font = .preferredFont(forTextStyle: .body)
        plainBodyLabel.textColor = .label
        plainBodyLabel.adjustsFontForContentSizeCategory = true
        plainBodyLabel.translatesAutoresizingMaskIntoConstraints = false

        contentStack.addArrangedSubview(bodyContainer)
    }

    private func configureImageContainer() {
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true

        imageContainer.layer.cornerRadius = 0
        imageContainer.clipsToBounds = false

        imageContainer.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: imageContainer.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: imageContainer.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: imageContainer.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: imageContainer.bottomAnchor),
            imageView.heightAnchor.constraint(lessThanOrEqualToConstant: 140),
        ])
    }

    private func applyContent(from notification: UNNotification) {
        let content = notification.request.content
        let resolvedBody = resolveBody(content: content)
        currentBodyText = resolvedBody.rawText
        let renderMarkdown = shouldUseMarkdown(content: content, resolvedBody: resolvedBody)
        let renderPayload = resolveRenderPayload(from: content, shouldRenderMarkdown: renderMarkdown)
        renderBody(text: resolvedBody.rawText, asMarkdown: renderMarkdown, payload: renderPayload)
        loadImage(from: content)
        view.layoutIfNeeded()
        updatePreferredContentSizeIfNeeded()
    }

    private func resolveBody(content: UNNotificationContent) -> NCEResolvedBody {
        let fallbackBody = stringValue(forKeys: ["body"], in: content.userInfo) ?? content.body
        return NCEMessageBodyResolver.resolve(
            ciphertextBody: stringValue(forKeys: ["ciphertext_body"], in: content.userInfo),
            envelopeBody: fallbackBody
        )
    }

    private func shouldUseMarkdown(
        content: UNNotificationContent,
        resolvedBody: NCEResolvedBody
    ) -> Bool {
        if content.categoryIdentifier == AppConstants.nceMarkdownCategoryIdentifier {
            return true
        }
        if let flag = content.userInfo["body_render_is_markdown"] as? Bool, flag {
            return true
        }
        return resolvedBody.isMarkdown
    }

    private func renderBody(text: String, asMarkdown: Bool, payload: MarkdownRenderPayload?) {
        markdownHost?.willMove(toParent: nil)
        markdownHost?.view.removeFromSuperview()
        markdownHost?.removeFromParent()
        markdownHost = nil

        bodyContainer.subviews.forEach { $0.removeFromSuperview() }

        if asMarkdown {
            if let payload, NCEContainsMarkdownSyntax.containsBlockMarkdown(text) == false {
                let host = UIHostingController(rootView: MarkdownRenderPayloadView(payload: payload))
                addChild(host)
                bodyContainer.addSubview(host.view)
                host.view.backgroundColor = .clear
                host.view.translatesAutoresizingMaskIntoConstraints = false
                host.view.setContentHuggingPriority(.required, for: .vertical)
                host.view.setContentCompressionResistancePriority(.required, for: .vertical)
                NSLayoutConstraint.activate([
                    host.view.topAnchor.constraint(equalTo: bodyContainer.topAnchor, constant: 12),
                    host.view.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor, constant: 12),
                    host.view.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor, constant: -12),
                    host.view.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor, constant: -12),
                ])
                host.didMove(toParent: self)
                markdownHost = host
            } else {
                let document = PushGoMarkdownParser().parse(text)
                if document.blocks.isEmpty {
                    plainBodyLabel.text = text
                    addPlainLabel()
                    return
                }
                let host = UIHostingController(rootView: PushGoMarkdownView(document: document))
                addChild(host)
                bodyContainer.addSubview(host.view)
                host.view.backgroundColor = .clear
                host.view.translatesAutoresizingMaskIntoConstraints = false
                host.view.setContentHuggingPriority(.required, for: .vertical)
                host.view.setContentCompressionResistancePriority(.required, for: .vertical)
                NSLayoutConstraint.activate([
                    host.view.topAnchor.constraint(equalTo: bodyContainer.topAnchor, constant: 12),
                    host.view.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor, constant: 12),
                    host.view.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor, constant: -12),
                    host.view.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor, constant: -12),
                ])
                host.didMove(toParent: self)
                markdownHost = host
            }
        } else {
            applyPlainText(text)
            addPlainLabel()
        }
    }

    private func resolveRenderPayload(
        from content: UNNotificationContent,
        shouldRenderMarkdown: Bool
    ) -> MarkdownRenderPayload? {
        guard shouldRenderMarkdown else { return nil }
        guard let payloadText = content.userInfo[AppConstants.markdownRenderPayloadKey] as? String else {
            return nil
        }
        return MarkdownRenderPayload.decode(from: payloadText)
    }

    private func addPlainLabel() {
        bodyContainer.addSubview(plainBodyLabel)
        NSLayoutConstraint.activate([
            plainBodyLabel.topAnchor.constraint(equalTo: bodyContainer.topAnchor, constant: 12),
            plainBodyLabel.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor, constant: 12),
            plainBodyLabel.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor, constant: -12),
            plainBodyLabel.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor, constant: -12),
        ])
    }

    private func applyPlainText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? " " : text
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 6
        plainBodyLabel.attributedText = NSAttributedString(
            string: resolved,
            attributes: [
                .font: plainBodyLabel.font as Any,
                .foregroundColor: plainBodyLabel.textColor as Any,
                .paragraphStyle: paragraph,
            ]
        )
    }

    private func loadImage(from content: UNNotificationContent) {
        imageTask?.cancel()
        imageTask = Task {
            if let attachment = content.attachments.first {
                let url = attachment.url
                let needsAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if needsAccess {
                        url.stopAccessingSecurityScopedResource()
                    }
                }

                if let data = try? Data(contentsOf: url),
                   let image = UIImage(data: data) {
                    await MainActor.run {
                        self.setImage(image)
                    }
                    return
                }
            }
            await MainActor.run {
                self.clearImage()
            }
        }
    }

    private func setImage(_ image: UIImage) {
        imageView.image = image
        imageContainer.isHidden = false
        imageHeightConstraint?.constant = 140
        view.layoutIfNeeded()
        updatePreferredContentSizeIfNeeded()
    }

    private func clearImage() {
        imageView.image = nil
        imageContainer.isHidden = true
        imageHeightConstraint?.constant = 0
        view.layoutIfNeeded()
        updatePreferredContentSizeIfNeeded()
    }

    private func stringValue(forKeys keys: [String], in userInfo: [AnyHashable: Any]) -> String? {
        keys.compactMap { key in
            (userInfo[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .first(where: { !$0.isEmpty })
    }

    private func urlValue(forKeys keys: [String], in userInfo: [AnyHashable: Any]) -> URL? {
        guard let text = stringValue(forKeys: keys, in: userInfo) else { return nil }
        return URL(string: text)
    }

    private func updatePreferredContentSizeIfNeeded() {
        let targetSize = CGSize(width: view.bounds.width, height: UIView.layoutFittingCompressedSize.height)
        let fittingSize = contentStack.systemLayoutSizeFitting(
            targetSize,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        let imageHeight = imageContainer.isHidden ? 0 : (imageHeightConstraint?.constant ?? 0)
        let safeAreaHeight = view.safeAreaInsets.top + view.safeAreaInsets.bottom
        let rawHeight = fittingSize.height + imageHeight + safeAreaHeight

        let screenHeight = view.window?.windowScene?.screen.bounds.height
            ?? view.window?.screen.bounds.height
            ?? view.bounds.height
        let maxHeight = screenHeight * 0.9
        let finalHeight = min(rawHeight, maxHeight)

        guard finalHeight > 0 else { return }
        preferredContentSize = CGSize(width: view.bounds.width, height: finalHeight)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updatePreferredContentSizeIfNeeded()
    }

    private func markMessageAsReadIfNeeded(for notification: UNNotification) {
        let requestId = notification.request.identifier
        let payload = notification.request.content.userInfo.reduce(into: [String: Any]()) { result, item in
            if let key = item.key as? String {
                result[key] = item.value
            }
        }
        let messageId = extractMessageId(from: payload)
        Task { @MainActor in
            let store = LocalDataStore(appGroupIdentifier: AppConstants.appGroupIdentifier)
            let coordinator = MessageStateCoordinator(
                dataStore: store,
                refreshCountsAndNotify: {
                    let counts = (try? await store.messageCounts()) ?? (total: 0, unread: 0)
                    BadgeManager.syncExtensionBadge(unreadCount: counts.unread)
                    DarwinNotificationPoster.post(name: AppConstants.messageSyncNotificationName)
                }
            )
            do {
                _ = try await coordinator.markRead(
                    notificationRequestId: requestId,
                    messageId: messageId
                )
            } catch {
            }
        }
    }

    private func extractMessageId(from payload: [String: Any]) -> UUID? {
        MessageIdExtractor.extract(from: payload)
    }
}

private enum NCEMarkdownRenderer {
    static func render(_ text: String) -> NSAttributedString {
        let baseFont = UIFont.preferredFont(forTextStyle: .body)
        let attributed = NSMutableAttributedString(string: text, attributes: [.font: baseFont])
        applyPattern(#"\\*\\*(.+?)\\*\\*"#, to: attributed) { range in
            attributed.addAttributes([.font: UIFont.boldSystemFont(ofSize: baseFont.pointSize)], range: range)
        }
        applyPattern(#"(?<!\\*)\\*(.+?)\\*"#, to: attributed) { range in
            attributed.addAttributes([.font: UIFont.italicSystemFont(ofSize: baseFont.pointSize)], range: range)
        }
        applyPattern(#"`([^`]+)`"#, to: attributed) { range in
            attributed.addAttributes(
                [
                    .font: UIFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular),
                    .backgroundColor: UIColor.systemGray5,
                ],
                range: range
            )
        }
        applyPattern(#"\\[([^\\]]+)\\]\\((https?://[^\\s)]+)\\)"#, to: attributed) { range, match, string in
            guard match.numberOfRanges >= 3,
                  let textRange = Range(match.range(at: 1), in: string),
                  let urlRange = Range(match.range(at: 2), in: string),
                  let url = URL(string: String(string[urlRange]))
            else { return }
            let display = String(string[textRange])
            attributed.replaceCharacters(in: range, with: display)
            let replacedRange = NSRange(location: range.location, length: display.utf16.count)
            attributed.addAttributes([.link: url], range: replacedRange)
        }

        return attributed
    }

    private static func applyPattern(
        _ pattern: String,
        to attributed: NSMutableAttributedString,
        apply: (NSRange, NSTextCheckingResult, String) -> Void
    ) {
        let full = attributed.string
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return }
        let matches = regex.matches(in: full, options: [], range: NSRange(location: 0, length: full.utf16.count))
        for match in matches.reversed() {
            let fullRange = match.range(at: 0)
            apply(fullRange, match, full)
        }
    }

    private static func applyPattern(
        _ pattern: String,
        to attributed: NSMutableAttributedString,
        apply: (NSRange) -> Void
    ) {
        applyPattern(pattern, to: attributed) { range, _, _ in apply(range) }
    }
}

private final class PaddedLabel: UILabel {
    var insets = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
        let base = super.intrinsicContentSize
        return CGSize(width: base.width + insets.left + insets.right, height: base.height + insets.top + insets.bottom)
    }
}

private struct NCEResolvedBody {
    enum Source: String {
        case ciphertextBody
        case body
    }

    let rawText: String
    let isMarkdown: Bool
    let source: Source
}

private enum NCEMessageBodyResolver {
    static func resolve(
        ciphertextBody: String?,
        envelopeBody: String
    ) -> NCEResolvedBody {
        if let cipherBody = trimmed(ciphertextBody) {
            return NCEResolvedBody(
                rawText: cipherBody,
                isMarkdown: NCEContainsMarkdownSyntax.containsMarkdownSyntax(cipherBody),
                source: .ciphertextBody
            )
        }
        let rawText = trimmed(envelopeBody) ?? ""
        return NCEResolvedBody(
            rawText: rawText,
            isMarkdown: NCEContainsMarkdownSyntax.containsMarkdownSyntax(rawText),
            source: .body
        )
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return raw
    }
}

private enum NCEContainsMarkdownSyntax {
    static func containsMarkdownSyntax(_ text: String) -> Bool {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return false }

        if raw.contains("```") { return true }

        if InlineRegex.bold.firstMatch(in: raw, options: [], range: raw.nsRange) != nil { return true }
        if InlineRegex.italicAsterisk.firstMatch(in: raw, options: [], range: raw.nsRange) != nil { return true }
        if InlineRegex.italicUnderscore.firstMatch(in: raw, options: [], range: raw.nsRange) != nil { return true }
        if InlineRegex.strikethrough.firstMatch(in: raw, options: [], range: raw.nsRange) != nil { return true }
        if InlineRegex.highlight.firstMatch(in: raw, options: [], range: raw.nsRange) != nil { return true }
        if InlineRegex.inlineCode.firstMatch(in: raw, options: [], range: raw.nsRange) != nil { return true }
        if InlineRegex.link.firstMatch(in: raw, options: [], range: raw.nsRange) != nil { return true }

        let lines = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if BlockRegex.heading.firstMatch(in: line, options: [], range: line.nsRange) != nil { return true }
            if BlockRegex.callout.firstMatch(in: line, options: [], range: line.nsRange) != nil { return true }
            if BlockRegex.blockquote.firstMatch(in: line, options: [], range: line.nsRange) != nil { return true }
            if BlockRegex.unorderedList.firstMatch(in: line, options: [], range: line.nsRange) != nil { return true }
            if BlockRegex.orderedList.firstMatch(in: line, options: [], range: line.nsRange) != nil { return true }
            if BlockRegex.horizontalRule.firstMatch(in: line, options: [], range: line.nsRange) != nil { return true }
        }

        if lines.count >= 2 {
            for index in 0 ..< (lines.count - 1) {
                let headerLine = lines[index]
                let separatorLine = lines[index + 1]
                if headerLine.contains("|"),
                   BlockRegex.tableSeparator.firstMatch(in: separatorLine, options: [], range: separatorLine.nsRange) != nil
                {
                    return true
                }
            }
        }

        return false
    }

    static func containsBlockMarkdown(_ text: String) -> Bool {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return false }

        let lines = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if BlockRegex.heading.firstMatch(in: line, options: [], range: line.nsRange) != nil { return true }
            if BlockRegex.callout.firstMatch(in: line, options: [], range: line.nsRange) != nil { return true }
            if BlockRegex.blockquote.firstMatch(in: line, options: [], range: line.nsRange) != nil { return true }
            if BlockRegex.unorderedList.firstMatch(in: line, options: [], range: line.nsRange) != nil { return true }
            if BlockRegex.orderedList.firstMatch(in: line, options: [], range: line.nsRange) != nil { return true }
            if BlockRegex.horizontalRule.firstMatch(in: line, options: [], range: line.nsRange) != nil { return true }
        }

        if lines.count >= 2 {
            for index in 0 ..< (lines.count - 1) {
                let headerLine = lines[index]
                let separatorLine = lines[index + 1]
                if headerLine.contains("|"),
                   BlockRegex.tableSeparator.firstMatch(in: separatorLine, options: [], range: separatorLine.nsRange) != nil
                {
                    return true
                }
            }
        }

        return false
    }
}

private enum InlineRegex {
    static let noMatchRegex = makeNoMatchRegex()
    static let bold = make(#"(?:\*\*|__)(?=\S).+?(?<=\S)(?:\*\*|__)"#, options: [])
    static let italicAsterisk = make(#"(?<!\*)\*(?=\S)[^*\n]+?(?<=\S)\*(?!\*)"#, options: [])
    static let italicUnderscore = make(#"(?<!_)_(?=\S)[^_\n]+?(?<=\S)_(?!_)"#, options: [])
    static let strikethrough = make(#"~~(?=\S).+?(?<=\S)~~"#, options: [])
    static let highlight = make(#"==(?=\S).+?(?<=\S)=="#, options: [])
    static let inlineCode = make(#"`[^`\n]+`"#, options: [])
    static let link = make(#"\[[^\]\n]+\]\(([^)\s]+)\)"#, options: [])

    private static func make(_ pattern: String, options: NSRegularExpression.Options) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            return noMatchRegex
        }
    }

    private static func makeNoMatchRegex() -> NSRegularExpression {
        if let regex = try? NSRegularExpression(pattern: "(?!)") { return regex }
        if let regex = try? NSRegularExpression(pattern: "a^") { return regex }
        return try! NSRegularExpression(pattern: "(?!)")
    }
}

private enum BlockRegex {
    static let noMatchRegex = makeNoMatchRegex()
    static let heading = make(#"^\s{0,3}#{1,6}\s+.+$"#, options: [])
    static let callout = make(#"^\s{0,3}>\s*\[\!(info|success|warning|error)\]\s*.*$"#, options: [.caseInsensitive])
    static let blockquote = make(#"^\s{0,3}>\s?.+$"#, options: [])
    static let unorderedList = make(#"^\s{0,3}[-*]\s+.+$"#, options: [])
    static let orderedList = make(#"^\s{0,3}\d+\.\s+.+$"#, options: [])
    static let horizontalRule = make(#"^\s{0,3}(([-*_])\s*){3,}$"#, options: [])
    static let tableSeparator = make(#"^\s*\|?\s*-+\s*(\|\s*-+\s*)+\|?\s*$"#, options: [])

    private static func make(_ pattern: String, options: NSRegularExpression.Options) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            return noMatchRegex
        }
    }

    private static func makeNoMatchRegex() -> NSRegularExpression {
        if let regex = try? NSRegularExpression(pattern: "(?!)") { return regex }
        if let regex = try? NSRegularExpression(pattern: "a^") { return regex }
        return try! NSRegularExpression(pattern: "(?!)")
    }
}

private extension String {
    var nsRange: NSRange { NSRange(location: 0, length: utf16.count) }
}
