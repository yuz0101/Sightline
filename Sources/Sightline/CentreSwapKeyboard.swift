import AppKit
import SightlineCore

// The port is set before the thread starts. Only that thread touches input.
private final class SwapTap: @unchecked Sendable {
    let input: CentreSwapInput
    var port: CFMachPort?

    init(input: CentreSwapInput) { self.input = input }

    func run() {
        guard let port, let source = CFMachPortCreateRunLoopSource(nil, port, 0) else { return }
        let mode = CFRunLoopMode("Sightline.centreSwap" as CFString)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, mode)
        CGEvent.tapEnable(tap: port, enable: true)
        CFRunLoopRunInMode(mode, .greatestFiniteMagnitude, false)
    }

    static let callback: CGEventTapCallBack = { _, type, event, context in
        guard let context else { return Unmanaged.passUnretained(event) }
        let tap = Unmanaged<SwapTap>.fromOpaque(context).takeUnretainedValue()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            tap.input.reset()
            if let port = tap.port { CGEvent.tapEnable(tap: port, enable: true) }
        } else if tap.input.consumes(type, key: Int(event.getIntegerValueField(.keyboardEventKeycode)),
                                     flags: event.flags, repeated: event.getIntegerValueField(.keyboardEventAutorepeat) != 0) {
            return nil
        }
        return Unmanaged.passUnretained(event)
    }
}

@MainActor
final class CentreSwapKeyboard {
    private let handle: (CentreSwapUpdate) -> Void
    private var tap: SwapTap?

    init(handle: @escaping (CentreSwapUpdate) -> Void) { self.handle = handle }

    func installIfNeeded() {
        guard tap == nil, Accessibility.isTrusted else { return }
        let input = CentreSwapInput { [weak self] update in
            DispatchQueue.main.async { self?.handle(update) }
        }
        let tap = SwapTap(input: input)
        let mask: CGEventMask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(0) { $0 | (1 << $1.rawValue) }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: mask,
                                           callback: SwapTap.callback, userInfo: Unmanaged.passUnretained(tap).toOpaque())
        else { return } // Retried by the display watcher, including after an Accessibility grant.
        tap.port = port
        self.tap = tap
        // AX calls and a tracking NSMenu can both block the main run loop.
        // Keep the input callback short and deliver ordered UI work to the main queue.
        let thread = Thread { tap.run() }
        thread.name = "Sightline.centreSwap"
        thread.start()
    }

    func uninstall() {
        if let port = tap?.port { CFMachPortInvalidate(port) }
        tap = nil
        handle(.cancel)
    }
}
