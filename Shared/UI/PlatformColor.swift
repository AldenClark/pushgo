import SwiftUI
#if os(iOS)
import UIKit
#elseif os(watchOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum AppSemanticTone {
    case info
    case neutral
    case success
    case warning
    case danger

    var foreground: Color {
        switch self {
        case .info:
            return .appStateInfoForeground
        case .neutral:
            return .appStateNeutralForeground
        case .success:
            return .appStateSuccessForeground
        case .warning:
            return .appStateWarningForeground
        case .danger:
            return .appStateDangerForeground
        }
    }

    var background: Color {
        switch self {
        case .info:
            return .appStateInfoBackground
        case .neutral:
            return .appStateNeutralBackground
        case .success:
            return .appStateSuccessBackground
        case .warning:
            return .appStateWarningBackground
        case .danger:
            return .appStateDangerBackground
        }
    }

    var border: Color {
        switch self {
        case .info:
            return .appStateInfoBorder
        case .neutral:
            return .appStateNeutralBorder
        case .success:
            return .appStateSuccessBorder
        case .warning:
            return .appStateWarningBorder
        case .danger:
            return .appStateDangerBorder
        }
    }

    var mutedForeground: Color {
        switch self {
        case .info:
            return .appTextSecondary
        case .neutral:
            return .appTextSecondary
        case .success:
            return .appStateSuccessForeground
        case .warning:
            return .appStateWarningForeground
        case .danger:
            return .appStateDangerForeground
        }
    }
}

extension Color {
    static var appWindowBackground: Color {
        appSurfaceBase
    }

    static var platformGroupedBackground: Color {
        appWindowBackground
    }

    static var platformCardBackground: Color {
        appSurfaceRaised
    }

    static var messageListBackground: Color {
        appWindowBackground
    }

    static var appInfoIconBackground: Color {
        appStateInfoBackground
    }

    static var appDangerIconBackground: Color {
        appStateDangerBackground
    }

    static var appCardBorder: Color {
        appBorderSubtle
    }

    static var appDividerSubtle: Color {
        appBorderSubtle
    }

    static var appDividerStrong: Color {
        appBorderStrong
    }

}
