import SwiftUI
#if os(iOS)
import UIKit
#elseif os(watchOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

extension Color {
    static var appWindowBackground: Color {
#if os(iOS)
        Color(UIColor.systemBackground)
#elseif os(watchOS)
        Color.black
#else
        Color(nsColor: NSColor.windowBackgroundColor)
#endif
    }

    static var platformGroupedBackground: Color {
#if os(iOS)
        appWindowBackground
#elseif os(watchOS)
        Color.black
#else
        appWindowBackground
#endif
    }

    static var platformCardBackground: Color {
#if os(iOS)
        Color(UIColor.secondarySystemBackground)
#elseif os(watchOS)
        Color.white.opacity(0.08)
#else
        Color(nsColor: NSColor.controlBackgroundColor)
#endif
    }

    static var messageListBackground: Color {
#if os(iOS)
        Color(UIColor.systemBackground)
#elseif os(watchOS)
        Color.black
#else
        appWindowBackground
#endif
    }
}
