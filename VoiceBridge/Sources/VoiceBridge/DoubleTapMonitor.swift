import AppKit

/// Detects a double-tap of a bare modifier key, the way Dictation's own shortcut
/// works. Carbon's RegisterEventHotKey can't express this — it needs a real key —
/// so this watches the global event stream instead, which costs an Accessibility
/// grant. That is the unavoidable price of a modifier-only trigger.
final class DoubleTapMonitor {
    private var flagsMonitor: Any?
    private var keyMonitor: Any?

    private var lastTapAt: Date?
    private var isDown = false
    /// Set when a real key is pressed while the modifier is held, which means the
    /// user was typing a chord like ⌃C rather than tapping.
    private var wasChord = false

    /// Two taps must land inside this window to count.
    private let window: TimeInterval = 0.45
    private let flag: NSEvent.ModifierFlags

    var onTrigger: (() -> Void)?

    init(flag: NSEvent.ModifierFlags = .control) {
        self.flag = flag
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func requestTrust() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func start() {
        stop()
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
        }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] _ in
            self?.noteKeyPress()
        }
    }

    /// A real key pressed while the modifier is held means this was a chord.
    func noteKeyPress() {
        if isDown { wasChord = true }
    }

    func stop() {
        [flagsMonitor, keyMonitor].compactMap { $0 }.forEach(NSEvent.removeMonitor)
        flagsMonitor = nil
        keyMonitor = nil
    }

    private func handle(_ event: NSEvent) {
        if process(flags: event.modifierFlags, at: Date()) { onTrigger?() }
    }

    /// The state transition, kept free of NSEvent so it can be driven directly.
    /// Returns true when this transition completes a double tap.
    @discardableResult
    func process(flags rawFlags: NSEvent.ModifierFlags, at now: Date) -> Bool {
        let flags = rawFlags.intersection(.deviceIndependentFlagsMask)
        let down = flags.contains(flag)
        let othersHeld = !flags.subtracting(flag)
            .intersection([.command, .option, .shift, .control]).isEmpty

        if down, !isDown {
            isDown = true
            wasChord = false
            // A tap combined with another modifier isn't a tap.
            guard !othersHeld else { lastTapAt = nil; return false }
            if let last = lastTapAt, now.timeIntervalSince(last) <= window {
                lastTapAt = nil
                return true
            }
            lastTapAt = now
            return false
        }
        if !down, isDown {
            isDown = false
            if wasChord { lastTapAt = nil }
        }
        return false
    }

    deinit {
        [flagsMonitor, keyMonitor].compactMap { $0 }.forEach(NSEvent.removeMonitor)
    }
}
