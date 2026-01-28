import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class AppState {
    private(set) var appearanceMode: AppearanceMode = .followSystem

    var preferredColorScheme: ColorScheme? {
        nil
    }
}
