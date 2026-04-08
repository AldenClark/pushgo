import SwiftUI
#if os(iOS)
import UIKit
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
    @State private var currentScale: CGFloat = 1.0
    @State private var baseScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(0.95).ignoresSafeArea()

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
                    ProgressView().foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack {
                    HStack {
                        Spacer()
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title.weight(.bold))
                                .foregroundStyle(.white.opacity(0.9))
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
}
