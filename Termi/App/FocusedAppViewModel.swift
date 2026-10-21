import SwiftUI

/// FocusedValueKey for routing menu commands to the focused window's AppViewModel.
/// Each window creates its own AppViewModel; the menu bar reads the focused one.
struct FocusedAppViewModelKey: FocusedValueKey {
    typealias Value = AppViewModel
}

extension FocusedValues {
    var appViewModel: AppViewModel? {
        get { self[FocusedAppViewModelKey.self] }
        set { self[FocusedAppViewModelKey.self] = newValue }
    }
}
