import SwiftUI
struct LiquidGlassToolbarIcon: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.callout.weight(.semibold))
            .padding(9)
            .background(
                Circle()
                    .fill(circleBackground),
            )
    }

    private var circleBackground: some ShapeStyle {
        .ultraThinMaterial
    }
}

struct LiquidGlassSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(containerBackground),
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.appGlassStrokeSubtle, lineWidth: 0.7),
            )
    }

    private var containerBackground: some ShapeStyle {
        .ultraThinMaterial
    }
}

extension View {
    func liquidGlassSurface(cornerRadius: CGFloat = 14) -> some View {
        modifier(LiquidGlassSurfaceModifier(cornerRadius: cornerRadius))
    }
}
