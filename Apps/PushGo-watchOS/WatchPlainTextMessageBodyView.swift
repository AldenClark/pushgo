import SwiftUI

struct WatchPlainTextMessageBodyView: View {
    let text: String
    var font: Font = .body
    var foreground: Color = .primary

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(foreground)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
    }
}
