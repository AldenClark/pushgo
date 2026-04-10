import SwiftUI

struct ToastView: View {
    let toast: AppEnvironment.ToastMessage

    var body: some View {
        HStack {
            Text(toast.text)
                .font(.subheadline)
                .multilineTextAlignment(.leading)
                .foregroundStyle(Color.appToastForeground)
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
            Color.appToastInfoBackground
        case .success:
            Color.appToastSuccessBackground
        case .error:
            Color.appToastErrorBackground
        }
    }
}
