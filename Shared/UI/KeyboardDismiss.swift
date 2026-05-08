import SwiftUI
import UniformTypeIdentifiers
import ImageIO
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
#if canImport(SDWebImageSwiftUI) && !os(watchOS)
import SDWebImageSwiftUI
#endif
#if canImport(SDWebImage) && !os(watchOS)
import SDWebImage
#endif

@MainActor
func dismissKeyboard() {
#if os(iOS)
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
#endif
}

@MainActor
@ViewBuilder
func navigationContainer(@ViewBuilder _ content: () -> some View) -> some View {
    NavigationStack { content() }
}

enum PushgoSheetSizingStyle {
    case form
    case detail
    case fitted
}

extension View {
    @ViewBuilder
    func pushgoSheetSizing(_ style: PushgoSheetSizingStyle) -> some View {
#if os(iOS)
        switch style {
        case .form:
            self
                .presentationSizing(.form.fitted(horizontal: false, vertical: true))
                .presentationContentInteraction(.scrolls)
                .presentationDragIndicator(.visible)
        case .detail:
            self
                .presentationSizing(
                    .page
                        .fitted(horizontal: false, vertical: true)
                        .sticky(horizontal: false, vertical: true),
                )
                .presentationContentInteraction(.scrolls)
                .presentationDragIndicator(.visible)
        case .fitted:
            self
                .presentationSizing(.fitted)
                .presentationDragIndicator(.visible)
        }
#else
        self
#endif
    }

    @ViewBuilder
    func pushgoAdaptiveSheetSizing() -> some View {
        self.pushgoSheetSizing(.form)
    }

    @ViewBuilder
    func pushgoFittedSheetSizing() -> some View {
        self.pushgoSheetSizing(.fitted)
    }

    @ViewBuilder
    func pushgoHideTabBarForDetail() -> some View {
#if os(iOS)
        self.toolbarVisibility(.hidden, for: .tabBar)
#else
        self
#endif
    }

    @ViewBuilder
    func pushgoTabBarMinimizeOnScroll() -> some View {
#if os(iOS)
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
#else
        self
#endif
    }

    @ViewBuilder
    func pushgoImagePreviewOverlay<Item: Identifiable>(
        previewItem: Binding<Item?>,
        imageURL: @escaping (Item) -> URL,
        onPresent: (() -> Void)? = nil,
        onDismiss: (() -> Void)? = nil,
    ) -> some View {
#if os(iOS)
        fullScreenCover(item: previewItem) { payload in
            PushgoImagePreviewOverlay(
                imageURL: imageURL(payload),
                onPresent: onPresent,
                onDismiss: onDismiss
            )
        }
#else
        sheet(item: previewItem) { payload in
            PushgoImagePreviewOverlay(
                imageURL: imageURL(payload),
                onPresent: onPresent,
                onDismiss: onDismiss
            )
        }
#endif
    }
}

private struct PushgoImagePreviewOverlay: View {
    let imageURL: URL
    let onPresent: (() -> Void)?
    let onDismiss: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager
    @Environment(AppEnvironment.self) private var environment: AppEnvironment
    @State private var currentScale: CGFloat = 1.0
    @State private var baseScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var loadedImage: PreviewPlatformImage?
    @State private var previewSourceURL: URL?
    @State private var previewIsAnimated = false
    @State private var previewIsAnimating = false
    @State private var animatedPlaybackPhase: AnimatedPlaybackPhase = .unavailable
    @State private var animatedPlaybackToken = UUID()
    @State private var singleLoopPlaybackDuration: TimeInterval = 0
    @State private var playbackStopTask: Task<Void, Never>?
    @State private var previewLoadGeneration = UUID()
#if os(iOS)
    @State private var sharePayload: PushGoImageSharePayload?
#elseif os(macOS)
    @State private var macShareFileURL: URL?
#endif

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.appImagePreviewScrim.ignoresSafeArea()

                previewMediaView(maxWidth: geo.size.width, maxHeight: geo.size.height)
                    .overlay(alignment: .bottomTrailing) {
                        if shouldShowReplayButton {
                            replayButton
                                .padding(.trailing, 20)
                                .padding(.bottom, 20)
                        }
                    }
                    .zIndex(0)

                VStack {
                    HStack {
                        Spacer()
#if os(iOS)
                        HStack(spacing: 8) {
                            Button {
                                Task {
                                    await prepareSharePayload()
                                }
                            } label: {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(Color.appOverlayForegroundMuted)
                                    .frame(width: 34, height: 34)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(Color.black.opacity(0.42))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(LocalizedStringKey("share"))

                            Button {
                                dismiss()
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(Color.appOverlayForegroundMuted)
                                    .frame(width: 34, height: 34)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(Color.black.opacity(0.42))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(LocalizedStringKey("close"))
                        }
                        .padding(.trailing, 16)
                        .padding(.top, 16)
#elseif os(macOS)
                        HStack(spacing: 8) {
                            PushGoMacShareButton(fileURL: macShareFileURL)
                                .pushgoMacPreviewActionChrome(isEnabled: macShareFileURL != nil)
                            Button {
                                Task {
                                    await saveImageToDisk()
                                }
                            } label: {
                                Image(systemName: "square.and.arrow.down")
                                    .font(.system(size: macPreviewOverlayActionIconSize, weight: .semibold))
                                    .foregroundStyle(Color.appOverlayForegroundMuted)
                            }
                            .buttonStyle(.plain)
                            .pushgoMacPreviewActionChrome()
                            .accessibilityLabel("Save")
                            Button {
                                dismiss()
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: macPreviewOverlayActionIconSize, weight: .semibold))
                                    .foregroundStyle(Color.appOverlayForegroundMuted)
                            }
                            .buttonStyle(.plain)
                            .pushgoMacPreviewActionChrome()
                            .accessibilityLabel(LocalizedStringKey("close"))
                        }
                        .padding(.trailing, 16)
                        .padding(.top, 16)
#else
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title.weight(.bold))
                                .foregroundStyle(Color.appOverlayForegroundMuted)
                        }
                        .accessibilityLabel(LocalizedStringKey("close"))
                        .padding()
#endif
                    }
                    Spacer()
                }
                .zIndex(10)
            }
        }
#if os(macOS)
        .frame(minWidth: 980, minHeight: 620)
#endif
        .task(id: imageURL) {
            let generation = UUID()
            previewLoadGeneration = generation
            resetPreviewStateForNewImage()
            PushGoAnimatedImageRuntime.bootstrapIfNeeded()
            let cachedSourceURL = SharedImageCache.cachedFileURL(
                for: imageURL,
                rendition: .original
            )
            guard isCurrentPreviewLoad(generation) else { return }
            previewSourceURL = cachedSourceURL ?? imageURL
            if let cachedSourceURL {
                let metadata = await Self.animationMetadata(at: cachedSourceURL)
                guard isCurrentPreviewLoad(generation) else { return }
                applyAnimationMetadata(metadata, autoPlay: true)
            } else {
                applyAnimationMetadata(.unavailable, autoPlay: false)
            }

            let resolvedSourceURL = await SharedImageCache.sourceURL(
                for: imageURL,
                rendition: .original,
                maxBytes: AppConstants.maxMessageImageBytes,
                timeout: 10
            )
            guard isCurrentPreviewLoad(generation) else { return }
            let previousSourceURL = previewSourceURL
            previewSourceURL = resolvedSourceURL
            let metadata = await Self.animationMetadata(at: resolvedSourceURL)
            guard isCurrentPreviewLoad(generation) else { return }
            let shouldRestartPlayback = previousSourceURL != resolvedSourceURL || animatedPlaybackPhase != .playing
            applyAnimationMetadata(metadata, autoPlay: shouldRestartPlayback)
#if os(macOS)
            macShareFileURL = Self.localShareableSourceURL(
                primaryURL: resolvedSourceURL,
                fallbackURL: imageURL
            )
#endif
        }
        .onDisappear {
            onDismiss?()
            previewLoadGeneration = UUID()
            playbackStopTask?.cancel()
            playbackStopTask = nil
            previewIsAnimating = false
            animatedPlaybackPhase = .unavailable
        }
        .onAppear {
            onPresent?()
        }
#if os(iOS)
        .sheet(item: $sharePayload) { payload in
            PushGoShareSheet(activityItems: [payload.fileURL])
        }
#endif
    }

    private var combinedGesture: some Gesture {
        SimultaneousGesture(dragGesture, magnificationGesture)
    }

    @ViewBuilder
    private func previewMediaView(maxWidth: CGFloat, maxHeight: CGFloat) -> some View {
#if canImport(SDWebImageSwiftUI) && !os(watchOS)
        if previewIsAnimated, let sourceURL = previewSourceURL {
            AnimatedImage(
                url: sourceURL,
                options: [.matchAnimatedImageClass, .fromLoaderOnly],
                isAnimating: $previewIsAnimating
            )
            .customLoopCount(1)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: maxWidth, maxHeight: maxHeight)
            .scaleEffect(currentScale)
            .offset(offset)
            .animation(.spring(response: 0.2, dampingFraction: 0.85), value: currentScale)
            .animation(.spring(response: 0.2, dampingFraction: 0.85), value: offset)
            .onTapGesture(count: 2) { toggleZoom() }
            .highPriorityGesture(combinedGesture)
            .id(animatedPlaybackToken)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if previewIsAnimated {
            ProgressView().foregroundStyle(Color.appOverlayForeground)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            staticPreviewMediaView(maxWidth: maxWidth, maxHeight: maxHeight)
        }
#else
        staticPreviewMediaView(maxWidth: maxWidth, maxHeight: maxHeight)
#endif
    }

    private func staticPreviewMediaView(maxWidth: CGFloat, maxHeight: CGFloat) -> some View {
        RemoteImageView(url: previewSourceURL, rendition: .original) { image in
            image
                .resizable()
                .scaledToFit()
                .frame(maxWidth: maxWidth, maxHeight: maxHeight)
                .scaleEffect(currentScale)
                .offset(offset)
                .animation(.spring(response: 0.2, dampingFraction: 0.85), value: currentScale)
                .animation(.spring(response: 0.2, dampingFraction: 0.85), value: offset)
                .onTapGesture(count: 2) { toggleZoom() }
                .highPriorityGesture(combinedGesture)
        } placeholder: {
            ProgressView().foregroundStyle(Color.appOverlayForeground)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let translation = value.translation
                offset = CGSize(
                    width: lastOffset.width + translation.width,
                    height: lastOffset.height + translation.height,
                )
            }
            .onEnded { _ in
                lastOffset = offset
            }
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let newScale = baseScale * value
                currentScale = min(max(1.0, newScale), 4.0)
            }
            .onEnded { _ in
                baseScale = currentScale
            }
    }

    private func toggleZoom() {
        if currentScale < 2.0 {
            currentScale = 2.5
        } else {
            currentScale = 1.0
            offset = .zero
            lastOffset = .zero
        }
        baseScale = currentScale
    }

    @MainActor
    private func restartAnimatedPlayback() {
        guard previewIsAnimated, previewSourceURL != nil else {
            previewIsAnimating = false
            animatedPlaybackPhase = .unavailable
            return
        }
        playbackStopTask?.cancel()
        playbackStopTask = nil
        let playbackToken = UUID()
        animatedPlaybackToken = playbackToken
        animatedPlaybackPhase = .playing
        previewIsAnimating = false

        // Restart on next run loop to ensure a fresh animation session starts from frame zero.
        DispatchQueue.main.async {
            guard animatedPlaybackToken == playbackToken else { return }
            previewIsAnimating = true
        }

        let playbackDuration = max(singleLoopPlaybackDuration, 0.9) + 0.12
        playbackStopTask = Task { @MainActor in
            let nanos = UInt64(playbackDuration * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }
            guard animatedPlaybackToken == playbackToken else { return }
            previewIsAnimating = false
            animatedPlaybackPhase = previewIsAnimated ? .ready : .unavailable
        }
    }

    @MainActor
    private func resetPreviewStateForNewImage() {
        playbackStopTask?.cancel()
        playbackStopTask = nil
        previewSourceURL = nil
        previewIsAnimated = false
        previewIsAnimating = false
        animatedPlaybackPhase = .unavailable
        animatedPlaybackToken = UUID()
        singleLoopPlaybackDuration = 0
        loadedImage = nil
        currentScale = 1
        baseScale = 1
        offset = .zero
        lastOffset = .zero
#if os(macOS)
        macShareFileURL = nil
#elseif os(iOS)
        sharePayload = nil
#endif
    }

    @MainActor
    private func isCurrentPreviewLoad(_ generation: UUID) -> Bool {
        !Task.isCancelled && previewLoadGeneration == generation
    }

    private var shouldShowReplayButton: Bool {
        previewIsAnimated
            && previewSourceURL?.isFileURL == true
            && animatedPlaybackPhase == .ready
    }

    private var replayButton: some View {
        Button {
            restartAnimatedPlayback()
        } label: {
            Image(systemName: "play.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.appOverlayForegroundMuted)
                .frame(width: 44, height: 44)
                .background(
                    Circle()
                        .fill(Color.black.opacity(0.46))
                )
                .overlay(
                    Circle()
                        .strokeBorder(Color.white.opacity(0.20), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(LocalizedStringKey("play"))
    }

    private func resolveLoadedImage() async -> PreviewPlatformImage? {
        if let loadedImage {
            return loadedImage
        }
        if let cached = await RemoteImageCache.cachedImage(for: imageURL, rendition: .original) {
            await MainActor.run {
                loadedImage = cached
            }
            return cached
        }
        do {
            let loaded = try await RemoteImageCache.loadImage(from: imageURL, rendition: .original)
            await MainActor.run {
                loadedImage = loaded
            }
            return loaded
        } catch {
            return nil
        }
    }

    private func shareableImageFileURL() async -> URL? {
        guard let image = await resolveLoadedImage(),
              let (data, contentType) = Self.normalizedImageDataAndType(from: image)
        else {
            return nil
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pushgo-share-preview", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory
                .appendingPathComponent("pushgo-image-\(UUID().uuidString)")
                .appendingPathExtension(contentType.preferredFilenameExtension ?? "png")
            try data.write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            return nil
        }
    }

#if os(macOS)
    @MainActor
    private func saveImageToDisk() async {
        guard let image = await resolveLoadedImage() else {
            showSaveFailure(reason: "Unable to load image.")
            return
        }
        guard let (data, contentType) = Self.normalizedImageDataAndType(from: image) else {
            showSaveFailure(reason: "Unable to convert image to a supported format.")
            return
        }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "pushgo-image.\(contentType.preferredFilenameExtension ?? "png")"
        panel.allowedContentTypes = [contentType]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try data.write(to: destination, options: .atomic)
            showSaveSuccess()
        } catch {
            showSaveFailure(reason: environment.userFacingErrorMessage(error))
        }
    }

    private static func normalizedImageDataAndType(from image: NSImage) -> (Data, UTType)? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else {
            return nil
        }
        if let png = bitmap.representation(using: .png, properties: [:]) {
            return (png, .png)
        }
        if let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.94]) {
            return (jpeg, .jpeg)
        }
        return nil
    }
#elseif os(iOS)
    private static func normalizedImageDataAndType(from image: UIImage) -> (Data, UTType)? {
        if let png = image.pngData() {
            return (png, .png)
        }
        if let jpeg = image.jpegData(compressionQuality: 0.94) {
            return (jpeg, .jpeg)
        }
        return nil
    }

    @MainActor
    private func prepareSharePayload() async {
        guard let fileURL = await shareableImageFileURL() else {
            showSaveFailure(reason: "Unable to prepare image for sharing.")
            return
        }
        sharePayload = PushGoImageSharePayload(fileURL: fileURL)
    }
#endif

    @MainActor
    private func showSaveSuccess() {
        environment.showToast(
            message: localizationManager.localized("saved"),
            style: .success,
            duration: 1.2
        )
    }

    @MainActor
    private func showSaveFailure(reason: String) {
        environment.showToast(
            message: localizationManager.localized("export_failed_placeholder", reason),
            style: .error,
            duration: 2
        )
    }

    private static func isSupportedAnimatedImage(at url: URL) -> Bool {
        guard url.isFileURL else {
            return false
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return sdWebImageAnimatedFrameCount(at: url) > 1
        }
        let frameCount = CGImageSourceGetCount(source)
        if frameCount > 1 {
            return true
        }
        return sdWebImageAnimatedFrameCount(at: url) > 1
    }

    @MainActor
    private func applyAnimationMetadata(_ metadata: AnimationMetadata, autoPlay: Bool) {
        previewIsAnimated = metadata.isAnimated
        singleLoopPlaybackDuration = metadata.singleLoopDuration
        playbackStopTask?.cancel()
        playbackStopTask = nil
        previewIsAnimating = false
        if metadata.isAnimated {
            animatedPlaybackPhase = .ready
            if autoPlay {
                restartAnimatedPlayback()
            }
        } else {
            animatedPlaybackPhase = .unavailable
        }
    }

    nonisolated private static func animationMetadata(at url: URL) async -> AnimationMetadata {
        await Task(priority: .utility) {
            readAnimationMetadata(at: url)
        }
        .value
    }

    nonisolated private static func readAnimationMetadata(at url: URL) -> AnimationMetadata {
        guard url.isFileURL else { return .unavailable }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            let fallbackFrameCount = sdWebImageAnimatedFrameCount(at: url)
            guard fallbackFrameCount > 1 else { return .unavailable }
            return .animated(singleLoopDuration: fallbackDuration(frameCount: fallbackFrameCount))
        }

        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 1 else { return .unavailable }

        var duration: TimeInterval = 0
        for frameIndex in 0 ..< frameCount {
            guard
                let properties = CGImageSourceCopyPropertiesAtIndex(source, frameIndex, nil) as? [CFString: Any]
            else {
                duration += 0.1
                continue
            }
            duration += max(frameDelay(from: properties), 0.02)
        }

        if duration <= 0 {
            duration = fallbackDuration(frameCount: UInt(frameCount))
        }
        return .animated(singleLoopDuration: min(max(duration, 0.12), 60))
    }

    nonisolated private static func fallbackDuration(frameCount: UInt) -> TimeInterval {
        min(max(TimeInterval(frameCount) * 0.1, 0.9), 60)
    }

    nonisolated private static func frameDelay(from properties: [CFString: Any]) -> TimeInterval {
        let dictionaries: [[CFString: Any]] = [
            properties[kCGImagePropertyGIFDictionary] as? [CFString: Any],
            properties[kCGImagePropertyPNGDictionary] as? [CFString: Any],
            properties[kCGImagePropertyWebPDictionary] as? [CFString: Any],
            properties["WebP" as CFString] as? [CFString: Any],
            properties["{WebP}" as CFString] as? [CFString: Any],
        ]
        .compactMap { $0 }

        for dictionary in dictionaries {
            if let unclamped = readDelayValue(from: dictionary, matching: "UnclampedDelayTime"), unclamped > 0 {
                return max(unclamped, 0.02)
            }
            if let delay = readDelayValue(from: dictionary, matching: "DelayTime"), delay > 0 {
                return max(delay, 0.02)
            }
        }
        return 0.1
    }

    nonisolated private static func readDelayValue(
        from dictionary: [CFString: Any],
        matching keyword: String
    ) -> TimeInterval? {
        for (key, value) in dictionary {
            let keyString = (key as String).lowercased()
            guard keyString.contains(keyword.lowercased()) else { continue }
            if let number = value as? NSNumber {
                return number.doubleValue
            }
        }
        return nil
    }

    nonisolated private static func sdWebImageAnimatedFrameCount(at fileURL: URL) -> UInt {
#if canImport(SDWebImage) && !os(watchOS)
        guard let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]),
              let animatedImage = SDAnimatedImage(data: data)
        else {
            return 0
        }
        return animatedImage.animatedImageFrameCount
#else
        return 0
#endif
    }

#if os(macOS)
    private static func localShareableSourceURL(primaryURL: URL?, fallbackURL: URL) -> URL? {
        if let primaryURL, primaryURL.isFileURL {
            return primaryURL
        }
        if fallbackURL.isFileURL {
            return fallbackURL
        }
        return nil
    }
#endif

    private enum AnimatedPlaybackPhase {
        case unavailable
        case ready
        case playing
    }

    private struct AnimationMetadata: Sendable {
        let isAnimated: Bool
        let singleLoopDuration: TimeInterval

        static let unavailable = AnimationMetadata(isAnimated: false, singleLoopDuration: 0)

        static func animated(singleLoopDuration: TimeInterval) -> AnimationMetadata {
            AnimationMetadata(isAnimated: true, singleLoopDuration: singleLoopDuration)
        }
    }
}

#if os(iOS)
private struct PushGoShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif

#if os(iOS)
private struct PushGoImageSharePayload: Identifiable {
    let id = UUID()
    let fileURL: URL
}
#endif

#if os(macOS)
private let macPreviewOverlayActionButtonSize: CGFloat = 34
private let macPreviewOverlayActionIconSize: CGFloat = 15
private let macPreviewOverlayActionCornerRadius: CGFloat = 10

private extension View {
    func pushgoMacPreviewActionChrome(isEnabled: Bool = true) -> some View {
        self
            .frame(width: macPreviewOverlayActionButtonSize, height: macPreviewOverlayActionButtonSize)
            .background(
                RoundedRectangle(cornerRadius: macPreviewOverlayActionCornerRadius, style: .continuous)
                    .fill(Color.black.opacity(isEnabled ? 0.42 : 0.24))
            )
            .overlay(
                RoundedRectangle(cornerRadius: macPreviewOverlayActionCornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(isEnabled ? 0.16 : 0.08), lineWidth: 1)
            )
            .opacity(isEnabled ? 1 : 0.72)
    }
}

private struct PushGoMacShareButton: NSViewRepresentable {
    let fileURL: URL?

    func makeCoordinator() -> Coordinator {
        Coordinator(fileURL: fileURL)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.image = Self.shareIcon()
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .white
        button.toolTip = NSLocalizedString("Share", comment: "Share image")
        button.isEnabled = fileURL != nil
        button.target = context.coordinator
        button.action = #selector(Coordinator.shareTapped(_:))
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        nsView.target = context.coordinator
        nsView.action = #selector(Coordinator.shareTapped(_:))
        context.coordinator.fileURL = fileURL
        nsView.isEnabled = fileURL != nil
        nsView.contentTintColor = fileURL == nil ? NSColor.white.withAlphaComponent(0.45) : .white
        nsView.image = Self.shareIcon()
    }

    private static func shareIcon() -> NSImage? {
        let icon = NSImage(
            systemSymbolName: "square.and.arrow.up",
            accessibilityDescription: NSLocalizedString("Share", comment: "Share image"),
        )
        let configuration = NSImage.SymbolConfiguration(
            pointSize: macPreviewOverlayActionIconSize,
            weight: .semibold
        )
        return icon?.withSymbolConfiguration(configuration)
    }

    final class Coordinator: NSObject {
        var fileURL: URL?

        init(fileURL: URL?) {
            self.fileURL = fileURL
        }

        @MainActor
        @objc
        func shareTapped(_ sender: NSButton) {
            guard let fileURL else { return }
            let picker = NSSharingServicePicker(items: [fileURL])
            let anchorRect = NSRect(
                x: sender.bounds.midX - 1,
                y: sender.bounds.midY - 1,
                width: 2,
                height: 2
            )
            picker.show(relativeTo: anchorRect, of: sender, preferredEdge: .maxY)
        }
    }
}
#endif

#if os(iOS)
private typealias PreviewPlatformImage = UIImage
#elseif os(macOS)
private typealias PreviewPlatformImage = NSImage
#endif
