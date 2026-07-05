import Foundation

enum PushGoFocusStateStore {
    static let defaultsKey = "pushgo.focus_filter.state.v1"

    static func load(
        defaults: UserDefaults = AppConstants.sharedUserDefaults()
    ) -> PushGoSystemSurfaceSnapshot.FocusState {
        guard let data = defaults.data(forKey: defaultsKey),
              let state = try? JSONDecoder().decode(PushGoSystemSurfaceSnapshot.FocusState.self, from: data)
        else {
            return .default()
        }
        return state
    }

    static func save(
        _ state: PushGoSystemSurfaceSnapshot.FocusState,
        defaults: UserDefaults = AppConstants.sharedUserDefaults()
    ) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}

#if canImport(AppIntents) && !NSE_NO_DATABASE && !os(watchOS)
import AppIntents

enum PushGoFocusMode: String, AppEnum {
    case all
    case priorityOnly
    case quiet

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "PushGo Focus Mode")
    }

    static var caseDisplayRepresentations: [PushGoFocusMode: DisplayRepresentation] {
        [
            .all: DisplayRepresentation(title: "All PushGo updates"),
            .priorityOnly: DisplayRepresentation(title: "Priority PushGo updates"),
            .quiet: DisplayRepresentation(title: "Quiet PushGo mode"),
        ]
    }

    var storedMode: PushGoSystemSurfaceSnapshot.FocusState.Mode {
        switch self {
        case .all:
            return .all
        case .priorityOnly:
            return .priorityOnly
        case .quiet:
            return .quiet
        }
    }
}

struct SetPushGoFocusModeIntent: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Set PushGo Focus Mode"
    static let description = IntentDescription("Adjust how PushGo notifications behave while a Focus is active.")
    static let openAppWhenRun = false

    @Parameter(title: "Mode")
    var mode: PushGoFocusMode?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: LocalizedStringResource(stringLiteral: "PushGo \(resolvedMode.displayTitle)"))
    }

    init() {
        mode = .priorityOnly
    }

    init(mode: PushGoFocusMode) {
        self.mode = mode
    }

    static func suggestedFocusFilters(for context: FocusFilterSuggestionContext) async -> [SetPushGoFocusModeIntent] {
        [
            SetPushGoFocusModeIntent(mode: .priorityOnly),
            SetPushGoFocusModeIntent(mode: .quiet),
            SetPushGoFocusModeIntent(mode: .all),
        ]
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let resolvedMode = resolvedMode
        let state = PushGoSystemSurfaceSnapshot.FocusState(
            mode: resolvedMode.storedMode,
            updatedAtEpochMs: PushGoSystemSurfaceSnapshot.epochMilliseconds(Date())
        )
        PushGoFocusStateStore.save(state)
        await LocalDataStore().rebuildSystemSurfaceSnapshot()
        return .result(dialog: IntentDialog(stringLiteral: "PushGo Focus mode updated."))
    }

    private var resolvedMode: PushGoFocusMode {
        mode ?? .priorityOnly
    }
}

private extension PushGoFocusMode {
    var displayTitle: String {
        switch self {
        case .all:
            return "All Updates"
        case .priorityOnly:
            return "Priority Updates"
        case .quiet:
            return "Quiet Mode"
        }
    }
}
#endif
