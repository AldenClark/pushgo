import SwiftUI

struct ToastView: View {
    let toast: AppEnvironment.ToastMessage
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack {
            Text(toast.text)
                .font(.subheadline)
                .multilineTextAlignment(.leading)
                .foregroundStyle(Color.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(radius: 8, y: 4)
    }

    private var backgroundColor: Color {
        switch toast.style {
        case .info:
            reduceTransparency ? Color.accentColor : Color.accentColor.opacity(0.92)
        case .success:
            reduceTransparency ? Color.accentColor : Color.accentColor.opacity(0.92)
        case .error:
            reduceTransparency ? Color.red : Color.red.opacity(0.9)
        }
    }
}
