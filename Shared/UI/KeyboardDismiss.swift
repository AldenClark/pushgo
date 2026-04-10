import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
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
    ) -> some View {
#if os(iOS)
        fullScreenCover(item: previewItem) { payload in
            PushgoImagePreviewOverlay(imageURL: imageURL(payload))
        }
#else
        sheet(item: previewItem) { payload in
            PushgoImagePreviewOverlay(imageURL: imageURL(payload))
        }
#endif
    }
}

private struct PushgoImagePreviewOverlay: View {
    let imageURL: URL

    @Environment(\.dismiss) private var dismiss
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager
    @Environment(AppEnvironment.self) private var environment: AppEnvironment
    @State private var currentScale: CGFloat = 1.0
    @State private var baseScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var loadedImage: PreviewPlatformImage?
#if os(iOS)
    @State private var sharePayload: PushGoImageSharePayload?
#elseif os(macOS)
    @State private var macShareFileURL: URL?
#endif

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.appImagePreviewScrim.ignoresSafeArea()

                RemoteImageView(url: imageURL, rendition: .original) { image in
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: geo.size.width, maxHeight: geo.size.height)
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

                VStack {
                    HStack {
                        Spacer()
#if os(iOS)
                        Button {
                            Task {
                                await prepareSharePayload()
                            }
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(Color.appOverlayForegroundMuted)
                        }
                        .padding(.trailing, 6)
#elseif os(macOS)
                        PushGoMacShareButton(fileURL: macShareFileURL)
                        .frame(width: 22, height: 22)
                        .padding(.trailing, 6)
                        Button {
                            Task {
                                await saveImageToDisk()
                            }
                        } label: {
                            Image(systemName: "square.and.arrow.down")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(Color.appOverlayForegroundMuted)
                        }
                        .padding(.trailing, 6)
#endif
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title.weight(.bold))
                                .foregroundStyle(Color.appOverlayForegroundMuted)
                        }
                        .accessibilityLabel(LocalizedStringKey("close"))
                        .padding()
                    }
                    Spacer()
                }
            }
        }
#if os(macOS)
        .frame(minWidth: 980, minHeight: 620)
#endif
        .task(id: imageURL) {
            _ = await resolveLoadedImage()
#if os(macOS)
            macShareFileURL = await shareableImageFileURL()
#endif
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
            showSaveFailure(reason: error.localizedDescription)
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
private struct PushGoMacShareButton: NSViewRepresentable {
    let fileURL: URL?

    func makeCoordinator() -> Coordinator {
        Coordinator(fileURL: fileURL)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.image = NSImage(
            systemSymbolName: "square.and.arrow.up",
            accessibilityDescription: NSLocalizedString("Share", comment: "Share image"),
        )
        button.contentTintColor = .white
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
