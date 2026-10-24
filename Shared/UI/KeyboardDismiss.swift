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

private struct TransientPresentationFocusDisabledKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var transientPresentationFocusDisabled: Bool {
        get { self[TransientPresentationFocusDisabledKey.self] }
        set { self[TransientPresentationFocusDisabledKey.self] = newValue }
    }
}

@MainActor
func dismissKeyboard() {
#if os(iOS)
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
#endif
}

@MainActor
@ViewBuilder
func navigationContainer(@ViewBuilder _ content: () -> some View) -> some View {
#if os(macOS)
    content()
#else
    NavigationStack { content() }
#endif
}

enum PushgoSheetSizingStyle {
    case form
    case detail
    case fitted
}

extension View {
    @ViewBuilder
    func transientPresentationRoot() -> some View {
#if os(macOS)
        environment(\.transientPresentationFocusDisabled, true)
            .focusEffectDisabled()
#else
        self
#endif
    }

    @ViewBuilder
    func transientPresentationFocusEffectDisabled() -> some View {
#if os(macOS)
        focusEffectDisabled()
#else
        self
#endif
    }

    @ViewBuilder
    func transientPresentationActionControl() -> some View {
#if os(macOS)
        focusable(false)
            .focusEffectDisabled()
#else
        self
#endif
    }

    @ViewBuilder
    func transientPresentationSelectionControl() -> some View {
#if os(macOS)
        focusable(false)
            .focusEffectDisabled()
#else
        self
#endif
    }

    @ViewBuilder
    func pushgoSheetSizing(_ style: PushgoSheetSizingStyle) -> some View {
#if os(iOS)
        if #available(iOS 18.0, *) {
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
        } else {
            switch style {
            case .form:
                self
                    .presentationDetents([.medium, .large])
                    .presentationContentInteraction(.scrolls)
                    .presentationDragIndicator(.visible)
            case .detail:
                self
                    .presentationDetents([.large])
                    .presentationContentInteraction(.scrolls)
                    .presentationDragIndicator(.visible)
            case .fitted:
                self
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
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
        self.toolbar(.hidden, for: .tabBar)
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
    func legacyScrollViewOffsetObserver(
        onOffsetChange: @escaping @MainActor (CGFloat) -> Void
    ) -> some View {
#if os(iOS)
        self.background(
            LegacyScrollViewOffsetObserver(onOffsetChange: onOffsetChange)
                .frame(width: 0, height: 0)
        )
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

#if os(iOS)
private struct LegacyScrollViewOffsetObserver: UIViewRepresentable {
    let onOffsetChange: @MainActor (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onOffsetChange: onOffsetChange)
    }

    func makeUIView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: ObserverView, context: Context) {
        context.coordinator.onOffsetChange = onOffsetChange
        uiView.coordinator = context.coordinator
        uiView.bindIfNeeded()
    }

    @MainActor
    final class Coordinator: NSObject {
        var onOffsetChange: @MainActor (CGFloat) -> Void
        private weak var scrollView: UIScrollView?
        private var displayLink: CADisplayLink?
        private var lastOffsetY: CGFloat?

        init(onOffsetChange: @escaping @MainActor (CGFloat) -> Void) {
            self.onOffsetChange = onOffsetChange
        }

        func bind(to scrollView: UIScrollView) {
            guard self.scrollView !== scrollView else { return }
            self.scrollView = scrollView
            lastOffsetY = nil
            restartDisplayLinkIfNeeded()
            publishCurrentOffset()
        }

        nonisolated deinit {
            MainActor.assumeIsolated {
                displayLink?.invalidate()
            }
        }

        @objc
        func handleDisplayLinkTick() {
            publishCurrentOffset()
        }

        private func restartDisplayLinkIfNeeded() {
            displayLink?.invalidate()
            let displayLink = CADisplayLink(target: self, selector: #selector(handleDisplayLinkTick))
            displayLink.add(to: .main, forMode: .common)
            self.displayLink = displayLink
        }

        private func publishCurrentOffset() {
            guard let scrollView else {
                displayLink?.invalidate()
                displayLink = nil
                return
            }
            let offsetY = scrollView.contentOffset.y
            guard lastOffsetY != offsetY else { return }
            lastOffsetY = offsetY
            onOffsetChange(offsetY)
        }
    }

    final class ObserverView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            bindIfNeeded()
        }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            bindIfNeeded()
        }

        func bindIfNeeded() {
            guard let coordinator else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard let scrollView = self.enclosingScrollView() else { return }
                coordinator.bind(to: scrollView)
            }
        }

        private func enclosingScrollView() -> UIScrollView? {
            var candidate = superview
            while let view = candidate {
                if let scrollView = view as? UIScrollView {
                    return scrollView
                }
                candidate = view.superview
            }
            return nil
        }
    }
}
#endif

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
    @Environment(\.pushgoResourceOwner) private var resourceOwner
    @Environment(\.scenePhase) private var scenePhase
    @State private var originalData: Data?
    @State private var coverImage: CGImage?
    @State private var loadFailed = false
    @State private var previewIsStale = false
    @State private var retryGeneration = 0
    @State private var previewIsAnimated = false
    @State private var previewIsAnimationLimited = false
    @State private var previewIsAnimating = false
    @State private var animatedPlaybackToken = UUID()
    @State private var playbackPermit = UUID()
    @State private var previewLoadGeneration = UUID()
#if os(iOS)
    @State private var sharePayload: PushGoImageSharePayload?
#endif

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.appImagePreviewScrim.ignoresSafeArea()

                previewMediaView(maxWidth: geo.size.width, maxHeight: geo.size.height)
                    .overlay(alignment: .bottomTrailing) {
                        if previewIsAnimationLimited {
                            Label(LocalizedStringKey("image_static_preview"), systemImage: "photo")
                                .font(.caption)
                                .foregroundStyle(Color.appOverlayForeground)
                                .padding(8)
                                .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                                .padding(20)
                        } else if shouldShowReplayButton {
                            replayButton
                                .padding(.trailing, 20)
                                .padding(.bottom, 20)
                        }
                    }
                    .overlay(alignment: .bottomLeading) {
                        if previewIsStale {
                            Button { retryGeneration += 1 } label: {
                                Label(LocalizedStringKey("image_cached_preview_retry"), systemImage: "clock.arrow.circlepath")
                                    .font(.caption).padding(8)
                                    .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                            }
                            .foregroundStyle(Color.appOverlayForeground)
                            .padding(20)
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
                            .accessibilityIdentifier("action.image.preview.share")

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
                            PushGoMacShareButton(originalData: originalData)
                                .pushgoMacPreviewActionChrome(isEnabled: originalData != nil)
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
                            .accessibilityLabel(Text("save"))
                            .accessibilityIdentifier("action.image.preview.save")
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
                            .accessibilityIdentifier("action.image.preview.close")
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dialog.image.preview")
#if os(macOS)
        .frame(minWidth: 980, minHeight: 620)
#endif
        .task(id: PreviewIdentity(url: imageURL, owner: resourceOwner, retry: retryGeneration, active: scenePhase == .active)) {
            let generation = UUID()
            previewLoadGeneration = generation
            resetPreviewStateForNewImage()
            guard scenePhase == .active else { return }
            PushGoAnimatedImageRuntime.bootstrapIfNeeded()
            do {
                let resolved = try await SharedImageCache.resolve(
                    for: imageURL, rendition: .original,
                    maxBytes: AppConstants.maxMessageImageBytes, timeout: 10,
                    owner: resourceOwner
                )
                defer { withExtendedLifetime(resolved) {} }
                guard isCurrentPreviewLoad(generation) else { return }
                guard let metadata = ImageDisplayPolicy.metadata(for: resolved.data),
                      let cover = await ResourceImageDecode.shared.image(
                        data: resolved.data,
                        immutableFile: resolved.isPersistent ? resolved.fileURL : nil,
                        rendition: .original
                      )
                else { loadFailed = true; return }
                guard isCurrentPreviewLoad(generation) else { return }
                originalData = resolved.data
                previewIsStale = resolved.isStale
                coverImage = cover
                // The cover is cheap; full animation is a per-view, user-triggered session.
                // no-store bytes remain exclusively in memory, including playback.
                previewIsAnimated = metadata.mayAnimate
                previewIsAnimationLimited = metadata.isAnimated && !metadata.mayAnimate
                previewIsAnimating = false
            } catch {
                guard isCurrentPreviewLoad(generation) else { return }
                loadFailed = true
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                previewLoadGeneration = UUID()
                stopAnimatedPlayback()
                originalData = nil
                coverImage = nil
            }
        }
        .onDisappear {
            onDismiss?()
            previewLoadGeneration = UUID()
            stopAnimatedPlayback()
            originalData = nil
            coverImage = nil
        }
        .onAppear {
            onPresent?()
        }
#if os(iOS)
        .sheet(item: $sharePayload) { payload in
            PushGoShareSheet(fileURL: payload.fileURL)
        }
        .toastOverlay(environment: environment)
#else
        .toastOverlay(environment: environment)
#endif
    }

    private var combinedGesture: some Gesture {
        SimultaneousGesture(dragGesture, magnificationGesture)
    }

    @ViewBuilder
    private func previewMediaView(maxWidth: CGFloat, maxHeight: CGFloat) -> some View {
#if canImport(SDWebImageSwiftUI) && !os(watchOS)
        if previewIsAnimated, previewIsAnimating, let originalData {
            AnimatedImage(data: originalData, isAnimating: $previewIsAnimating)
            .maxBufferSize(ImageDisplayPolicy.animationBufferBytes)
            .pausable(true)
            .purgeable(true)
            .customLoopCount(0)
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
        } else {
            staticPreviewMediaView(maxWidth: maxWidth, maxHeight: maxHeight)
        }
#else
        staticPreviewMediaView(maxWidth: maxWidth, maxHeight: maxHeight)
#endif
    }

    @ViewBuilder
    private func staticPreviewMediaView(maxWidth: CGFloat, maxHeight: CGFloat) -> some View {
        if let coverImage {
            Image(decorative: coverImage, scale: 1)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: maxWidth, maxHeight: maxHeight)
                .scaleEffect(currentScale)
                .offset(offset)
                .animation(.spring(response: 0.2, dampingFraction: 0.85), value: currentScale)
                .animation(.spring(response: 0.2, dampingFraction: 0.85), value: offset)
                .onTapGesture(count: 2) { toggleZoom() }
                .highPriorityGesture(combinedGesture)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if loadFailed {
            Button { retryGeneration += 1 } label: {
                Label(LocalizedStringKey("retry"), systemImage: "arrow.clockwise")
            }
            .foregroundStyle(Color.appOverlayForeground)
        } else {
            ProgressView().foregroundStyle(Color.appOverlayForeground)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private struct PreviewIdentity: Hashable {
        let url: URL
        let owner: SharedImageCache.ResourceOwner?
        let retry: Int
        let active: Bool
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
        guard previewIsAnimated, originalData != nil, scenePhase == .active else { return }
        guard ImagePlaybackBudget.acquire(playbackPermit) else {
            // No queued or hidden player. Keep the already decoded cover.
            return
        }
        animatedPlaybackToken = UUID()
        previewIsAnimating = true
    }

    @MainActor
    private func stopAnimatedPlayback() {
        ImagePlaybackBudget.release(playbackPermit)
        previewIsAnimating = false
    }

    @MainActor
    private func resetPreviewStateForNewImage() {
        stopAnimatedPlayback()
        previewIsAnimated = false
        previewIsAnimationLimited = false
        previewIsAnimating = false
        animatedPlaybackToken = UUID()
        originalData = nil
        coverImage = nil
        loadFailed = false
        previewIsStale = false
        currentScale = 1
        baseScale = 1
        offset = .zero
        lastOffset = .zero
#if os(iOS)
        sharePayload = nil
#endif
    }

    @MainActor
    private func isCurrentPreviewLoad(_ generation: UUID) -> Bool {
        !Task.isCancelled && scenePhase == .active && previewLoadGeneration == generation
    }

    private var shouldShowReplayButton: Bool {
        previewIsAnimated && originalData != nil
    }

    private var replayButton: some View {
        Button {
            if previewIsAnimating { stopAnimatedPlayback() } else { restartAnimatedPlayback() }
        } label: {
            Image(systemName: previewIsAnimating ? "pause.fill" : "play.fill")
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
        .accessibilityLabel(LocalizedStringKey(previewIsAnimating ? "pause" : "play"))
        .accessibilityIdentifier("action.image.preview.playback")
    }

    /// User-initiated export is an attachment, not the HTTP reuse cache. Copy exact acquired
    /// bytes, including animation, orientation and color metadata; never encode the cover.
    private func shareableImageFileURL() async -> URL? {
        guard let originalData, let metadata = ImageDisplayPolicy.metadata(for: originalData) else { return nil }
        return try? PushGoOriginalImageExport.write(originalData, contentType: UTType(metadata.contentTypeIdentifier))
    }


#if os(macOS)
    @MainActor
    private func saveImageToDisk() async {
        guard let data = originalData,
              let metadata = ImageDisplayPolicy.metadata(for: data),
              let contentType = UTType(metadata.contentTypeIdentifier)
        else {
            showSaveFailure(reason: "Unable to load original image.")
            return
        }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        let filenameExtension = contentType.preferredFilenameExtension ?? "png"
        panel.nameFieldStringValue = "pushgo-image.\(filenameExtension)"
        panel.allowedContentTypes = [contentType]
        if let qualitySession = PushGoAutomationContext.qualitySession {
            panel.nameFieldStringValue = "pushgo-image-\(qualitySession.sessionID).\(filenameExtension)"
            let qualitySaveDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("PushGoQualitySavedImages", isDirectory: true)
                .appendingPathComponent(qualitySession.sessionID, isDirectory: true)
            try? FileManager.default.createDirectory(
                at: qualitySaveDirectory,
                withIntermediateDirectories: true
            )
            panel.directoryURL = qualitySaveDirectory
        }
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try data.write(to: destination, options: .atomic)
            if let receiptURL = PushGoAutomationContext.qualityArtifactURL(
                filename: "saved-image-destination.txt"
            ) {
                try? FileManager.default.createDirectory(
                    at: receiptURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? Data(destination.path.utf8).write(to: receiptURL, options: .atomic)
            }
            showSaveSuccess()
        } catch {
            showSaveFailure(reason: environment.userFacingErrorMessage(error))
        }
    }

#elseif os(iOS)
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


}

#if os(iOS)
private struct PushGoShareSheet: UIViewControllerRepresentable {
    let fileURL: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            // The native publisher has completed or been cancelled. Never remove the file
            // while a sharing service still owns the operation.
            try? FileManager.default.removeItem(at: fileURL)
        }
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
    let originalData: Data?

    func makeCoordinator() -> Coordinator {
        Coordinator(originalData: originalData)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.image = Self.shareIcon()
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .white
        button.toolTip = LocalizationProvider.localized("share_image")
        button.setAccessibilityIdentifier("action.image.preview.share")
        button.isEnabled = originalData != nil
        button.target = context.coordinator
        button.action = #selector(Coordinator.shareTapped(_:))
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        nsView.target = context.coordinator
        nsView.action = #selector(Coordinator.shareTapped(_:))
        context.coordinator.originalData = originalData
        nsView.setAccessibilityIdentifier("action.image.preview.share")
        nsView.isEnabled = originalData != nil
        nsView.contentTintColor = originalData == nil ? NSColor.white.withAlphaComponent(0.45) : .white
        nsView.image = Self.shareIcon()
    }

    private static func shareIcon() -> NSImage? {
        let icon = NSImage(
            systemSymbolName: "square.and.arrow.up",
            accessibilityDescription: LocalizationProvider.localized("share_image"),
        )
        let configuration = NSImage.SymbolConfiguration(
            pointSize: macPreviewOverlayActionIconSize,
            weight: .semibold
        )
        return icon?.withSymbolConfiguration(configuration)
    }

    @MainActor
    final class Coordinator: NSObject, NSSharingServicePickerDelegate, NSSharingServiceDelegate {
        var originalData: Data?
        private var activePicker: NSSharingServicePicker?
        private var activeExport: URL?
        private weak var shareButton: NSButton?

        init(originalData: Data?) {
            self.originalData = originalData
        }

        @MainActor
        @objc
        func shareTapped(_ sender: NSButton) {
            guard activeExport == nil, let originalData,
                  let metadata = ImageDisplayPolicy.metadata(for: originalData),
                  let fileURL = try? PushGoOriginalImageExport.write(
                    originalData, contentType: UTType(metadata.contentTypeIdentifier)
                  ) else { return }
            let picker = NSSharingServicePicker(items: [fileURL])
            activeExport = fileURL
            activePicker = picker
            shareButton = sender
            picker.delegate = self
            let anchorRect = NSRect(
                x: sender.bounds.midX - 1,
                y: sender.bounds.midY - 1,
                width: 2,
                height: 2
            )
            picker.show(relativeTo: anchorRect, of: sender, preferredEdge: .maxY)
        }

        func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, delegateFor sharingService: NSSharingService) -> (any NSSharingServiceDelegate)? {
            self
        }

        func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
            if service == nil { finishPublication() }
        }

        func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
            finishPublication()
        }

        func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: any Error) {
            finishPublication()
        }

        private func finishPublication() {
            if let activeExport { try? FileManager.default.removeItem(at: activeExport) }
            activeExport = nil
            activePicker = nil
            shareButton?.isEnabled = originalData != nil
        }
    }
}
#endif
