import Foundation
import SwiftUI
import ImageIO

private struct PushGoResourceOwnerKey: EnvironmentKey {
    static let defaultValue: SharedImageCache.ResourceOwner? = nil
}

private struct PushGoResourceRevisionKey: EnvironmentKey {
    static let defaultValue: Int? = nil
}

extension EnvironmentValues {
    var pushgoResourceRevision: Int? {
        get { self[PushGoResourceRevisionKey.self] }
        set { self[PushGoResourceRevisionKey.self] = newValue }
    }
    /// The canonical content owner, never the currently selected Gateway configuration.
    var pushgoResourceOwner: SharedImageCache.ResourceOwner? {
        get { self[PushGoResourceOwnerKey.self] }
        set { self[PushGoResourceOwnerKey.self] = newValue }
    }
}

struct RemoteImageView<Content: View, Placeholder: View>: View {
    let url: URL?
    let rendition: SharedImageCache.Rendition
    let explicitOwner: SharedImageCache.ResourceOwner?
    let explicitRevision: Int?
    let content: (Image) -> Content
    let placeholder: () -> Placeholder
    @Environment(\.pushgoResourceOwner) private var owner
    @Environment(\.pushgoResourceRevision) private var resourceRevision
    @Environment(\.scenePhase) private var scenePhase
    @State private var loadedImage: Image?
    @State private var failed = false
    @State private var isStale = false
    @State private var retry = 0
    @State private var generation = UUID()
    @State private var isVisible = false

    init(
        url: URL?,
        rendition: SharedImageCache.Rendition = .original,
        owner: SharedImageCache.ResourceOwner? = nil,
        revision: Int? = nil,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder = { Color.clear }
    ) {
        self.url = url
        self.rendition = rendition
        explicitOwner = owner
        explicitRevision = revision
        self.content = content
        self.placeholder = placeholder
    }

    var body: some View {
        Group {
            if let loadedImage {
                content(loadedImage)
                    .overlay(alignment: .bottomTrailing) {
                        if isStale {
                            Button { retry += 1 } label: {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.caption2).padding(5)
                                    .background(.regularMaterial, in: Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(LocalizedStringKey("image_cached_preview_retry"))
                        }
                    }
            } else if failed {
                Button { retry += 1 } label: {
                    Image(systemName: "arrow.clockwise")
                        .padding(8)
                        .frame(minWidth: 32, minHeight: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LocalizedStringKey("retry"))
            } else {
                placeholder()
            }
        }
        .task(id: identity) {
            if isVisible, scenePhase == .active { await load() }
        }
        .onAppear { isVisible = true }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                generation = UUID()
                loadedImage = nil
            }
        }
        .onDisappear {
            isVisible = false
            generation = UUID()
            loadedImage = nil
        }
    }

    private var identity: LoadIdentity {
        LoadIdentity(url: url, rendition: rendition, owner: explicitOwner ?? owner, retry: retry, visible: isVisible, revision: explicitRevision ?? resourceRevision, active: scenePhase == .active)
    }

    private struct LoadIdentity: Hashable {
        let url: URL?
        let rendition: SharedImageCache.Rendition
        let owner: SharedImageCache.ResourceOwner?
        let retry: Int
        let visible: Bool
        let revision: Int?
        let active: Bool
    }

    private func load() async {
        let token = UUID()
        generation = token
        loadedImage = nil
        failed = false
        isStale = false
        guard let url else { return }
        do {
            // A bound owner resolves an immutable acquired content version. No secondary loader
            // is allowed to follow the original remote URL after this resolution.
            let resource = try await SharedImageCache.resolve(
                for: url,
                rendition: .original,
                maxBytes: AppConstants.maxMessageImageBytes,
                timeout: 10,
                owner: explicitOwner ?? owner
            )
            defer { withExtendedLifetime(resource) {} }
            let image = await ResourceImageDecode.shared.image(
                data: resource.data,
                immutableFile: resource.isPersistent ? resource.fileURL : nil,
                rendition: rendition
            )
            guard !Task.isCancelled, isVisible, scenePhase == .active, generation == token else { return }
            isStale = resource.isStale
            loadedImage = image.map { Image(decorative: $0, scale: 1) }
            failed = image == nil
        } catch {
            guard !Task.isCancelled, isVisible, scenePhase == .active, generation == token else { return }
            failed = true
        }
    }
}
