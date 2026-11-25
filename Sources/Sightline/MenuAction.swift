enum MenuAction: UInt32 {
    case placeCenter = 1
    case placeLeftTop
    case placeLeftBottom
    case placeRightTop
    case placeRightBottom
    case hopLeft
    case hopRight
    case hopUp
    case hopDown
    case cycleForward
    case cycleBackward
    case stageFocused
    case nudgeNarrower
    case nudgeWider
    case fillScreen
    case centerWindow
    case saveArrangement
    case restoreArrangement
    case openSettings
    case arrangeAll

    var title: String {
        switch self {
        case .placeCenter: return "Centre board"
        case .placeLeftTop: return "Left top"
        case .placeLeftBottom: return "Left bottom"
        case .placeRightTop: return "Right top"
        case .placeRightBottom: return "Right bottom"
        case .hopLeft: return "Hop left"
        case .hopRight: return "Hop right"
        case .hopUp: return "Hop up"
        case .hopDown: return "Hop down"
        case .cycleForward: return "Next staged window"
        case .cycleBackward: return "Previous staged window"
        case .stageFocused: return "Stage focused window"
        case .nudgeNarrower: return "Nudge centre narrower"
        case .nudgeWider: return "Nudge centre wider"
        case .fillScreen: return "Fill screen"
        case .centerWindow: return "Centre at current size"
        case .saveArrangement: return "Save arrangement"
        case .restoreArrangement: return "Restore arrangement"
        case .openSettings: return "Open settings"
        case .arrangeAll: return "Arrange all windows"
        }
    }
}
