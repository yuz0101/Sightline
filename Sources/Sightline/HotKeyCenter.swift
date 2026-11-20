import AppKit
import Carbon.HIToolbox

/// Every user-triggerable command. Raw values are also the Carbon hotkey ids.
enum HotKeyAction: UInt32, CaseIterable {
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
    case toggleSplit
    case presetPrevious
    case presetNext
    case nudgeNarrower
    case nudgeWider
    case fillScreen
    case centerWindow
    case saveArrangement
    case restoreArrangement
    case openSettings
    case arrangeAll

    private static let base = UInt32(controlKey | optionKey)
    private static let baseShift = UInt32(controlKey | optionKey | shiftKey)

    /// Control-Option for placing and for the rare keys Rectangle leaves
    /// alone; Control-Option-Shift for everything else, because Rectangle's
    /// stock set owns most of the plain Control-Option letters and arrows.
    var modifiers: UInt32 {
        switch self {
        case .placeCenter, .placeLeftTop, .placeLeftBottom, .placeRightTop, .placeRightBottom,
             .cycleForward, .presetPrevious, .presetNext, .nudgeNarrower, .nudgeWider,
             .openSettings:
            return Self.base
        default:
            return Self.baseShift
        }
    }

    var keyCode: UInt32 {
        switch self {
        case .placeCenter: return UInt32(kVK_ANSI_1)
        case .placeLeftTop: return UInt32(kVK_ANSI_2)
        case .placeLeftBottom: return UInt32(kVK_ANSI_3)
        case .placeRightTop: return UInt32(kVK_ANSI_4)
        case .placeRightBottom: return UInt32(kVK_ANSI_5)
        // Arrows are unusable here: the window server / Mission Control takes
        // control-arrow combinations before Carbon sees them (verified on
        // macOS 15.8 — ⌃⌥⇧← never reached our handler, while ⌃⌥⇧T did).
        case .hopLeft: return UInt32(kVK_ANSI_H)
        case .hopRight: return UInt32(kVK_ANSI_L)
        case .hopUp: return UInt32(kVK_ANSI_K)
        case .hopDown: return UInt32(kVK_ANSI_J)
        case .cycleForward: return UInt32(kVK_ANSI_Grave)
        case .cycleBackward: return UInt32(kVK_ANSI_Grave)
        case .stageFocused: return UInt32(kVK_ANSI_T)
        case .toggleSplit: return UInt32(kVK_ANSI_S)
        case .presetPrevious: return UInt32(kVK_ANSI_LeftBracket)
        case .presetNext: return UInt32(kVK_ANSI_RightBracket)
        case .nudgeNarrower: return UInt32(kVK_ANSI_Minus)
        case .nudgeWider: return UInt32(kVK_ANSI_Equal)
        case .fillScreen: return UInt32(kVK_ANSI_F)
        case .centerWindow: return UInt32(kVK_ANSI_C)
        case .saveArrangement: return UInt32(kVK_ANSI_A)
        case .restoreArrangement: return UInt32(kVK_ANSI_Z)
        case .openSettings: return UInt32(kVK_ANSI_Comma)
        case .arrangeAll: return UInt32(kVK_ANSI_R)
        }
    }

    var shortcut: String {
        let mods = modifiers == Self.baseShift ? "⌃⌥⇧" : "⌃⌥"
        switch self {
        case .placeCenter: return "⌃⌥1"
        case .placeLeftTop: return "⌃⌥2"
        case .placeLeftBottom: return "⌃⌥3"
        case .placeRightTop: return "⌃⌥4"
        case .placeRightBottom: return "⌃⌥5"
        case .hopLeft: return mods + "H"
        case .hopRight: return mods + "L"
        case .hopUp: return mods + "K"
        case .hopDown: return mods + "J"
        case .cycleForward: return "⌃⌥`"
        case .cycleBackward: return mods + "`"
        case .stageFocused: return mods + "T"
        case .toggleSplit: return mods + "S"
        case .presetPrevious: return "⌃⌥["
        case .presetNext: return "⌃⌥]"
        case .nudgeNarrower: return "⌃⌥−"
        case .nudgeWider: return "⌃⌥="
        case .fillScreen: return mods + "F"
        case .centerWindow: return mods + "C"
        case .saveArrangement: return mods + "A"
        case .restoreArrangement: return mods + "Z"
        case .openSettings: return "⌃⌥,"
        case .arrangeAll: return mods + "R"
        }
    }

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
        case .toggleSplit: return "Split side boards"
        case .presetPrevious: return "Narrower centre"
        case .presetNext: return "Wider centre"
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

/// Carbon hotkeys: no extra permission, work while another app is focused, and
/// are consumed before the keystroke reaches the frontmost app.
@MainActor
final class HotKeyCenter {
    private static let signature = OSType(0x5342_7264)  // 'SBrd'

    private var handler: EventHandlerRef?
    private var hotKeys: [EventHotKeyRef] = []
    private(set) var failures: [HotKeyAction] = []
    var onAction: ((HotKeyAction) -> Void)?

    func install() {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &id
                )
                guard status == noErr else { return OSStatus(eventNotHandledErr) }
                guard let action = HotKeyAction(rawValue: id.id) else { return OSStatus(eventNotHandledErr) }
                let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
                MainActor.assumeIsolated { center.onAction?(action) }
                return noErr
            },
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )

        for action in HotKeyAction.allCases {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: action.rawValue)
            let status = RegisterEventHotKey(
                action.keyCode,
                action.modifiers,
                id,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if status == noErr, let ref {
                hotKeys.append(ref)
            } else {
                failures.append(action)
                NSLog("Sightline: hotkey \(action.shortcut) failed with OSStatus \(status)")
            }
        }
    }

    func uninstall() {
        for ref in hotKeys { UnregisterEventHotKey(ref) }
        hotKeys.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}
