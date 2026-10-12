import AppKit
import ApplicationServices

/// Global hotkey: RIGHT ⌘ + ⇧ + P.
///
/// Carbon hotkeys can't tell left and right ⌘ apart, so this uses a CGEventTap and checks the
/// device-dependent flag bit for the right Command key. The left ⌘⇧P keeps working in other apps
/// (VS Code command palette etc.). Needs the Accessibility permission.
final class HotKeyMonitor {
    var onTrigger: (() -> Void)?

    private var tap: CFMachPort?
    private var retryTimer: Timer?

    private static let keyP: Int64 = 35                // physical P, independent of keyboard layout
    private static let rightCommandBit: UInt64 = 0x10  // NX_DEVICERCMDKEYMASK

    var isActive: Bool { tap != nil }

    func start() {
        if AXIsProcessTrusted() {
            installTap()
        } else {
            requestAccess()
        }
    }

    /// Shows the system prompt and polls until access is granted.
    func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard AXIsProcessTrusted() else { return }
            timer.invalidate()
            self?.installTap()
        }
    }

    private func installTap() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotKeyCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown,
              event.getIntegerValueField(.keyboardEventKeycode) == Self.keyP else {
            return Unmanaged.passUnretained(event)
        }
        let flags = event.flags
        let matches = flags.contains(.maskCommand)
            && flags.contains(.maskShift)
            && !flags.contains(.maskControl)
            && !flags.contains(.maskAlternate)
            && flags.rawValue & Self.rightCommandBit != 0
        guard matches else { return Unmanaged.passUnretained(event) }

        if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            DispatchQueue.main.async { self.onTrigger?() }
        }
        return nil // swallow the keystroke
    }
}

private func hotKeyCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<HotKeyMonitor>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
}
