import ApplicationServices
import CoreGraphics
import Foundation

/// Turns tablet input into macOS mouse/scroll/keyboard events on the virtual display.
/// Posting synthetic events requires the Accessibility permission.
public final class InputInjector: @unchecked Sendable {
    private let displayID: CGDirectDisplayID
    private let fallbackBounds: CGRect
    private let videoPixelWidth: Int
    private let queue = DispatchQueue(label: "unbound.input", qos: .userInteractive)
    private let source = CGEventSource(stateID: .hidSystemState)

    // Accessed only on `queue`.
    private var leftDown = false
    private var rightDown = false
    private var lastClickTime: TimeInterval = 0
    private var lastClickPoint = CGPoint.zero
    private var clickCount: Int64 = 0
    private var warnedNoPermission = false
    private var lastPoint = CGPoint.zero

    public init(displayID: CGDirectDisplayID, fallbackBounds: CGRect, videoPixelWidth: Int) {
        self.displayID = displayID
        self.fallbackBounds = fallbackBounds
        self.videoPixelWidth = videoPixelWidth
    }

    public static func hasPermission(prompt: Bool) -> Bool {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    public func handle(_ event: InputEvent) {
        queue.async { [self] in
            guard Self.hasPermission(prompt: false) else {
                if !warnedNoPermission {
                    warnedNoPermission = true
                    log("input: Accessibility permission missing — tablet input is ignored. Grant it in "
                        + "System Settings › Privacy & Security › Accessibility, then restart the host.")
                }
                return
            }
            switch event {
            case .pointer(let action, let button, let x, let y): pointer(action, button, point(x, y))
            case .scroll(let dx, let dy): scroll(dx: dx, dy: dy)
            case .key(let down, let modifiers, let keyCode): key(down, modifiers, keyCode)
            }
        }
    }

    /// Releases any held buttons (e.g. when the client disconnects mid-drag).
    public func reset() {
        queue.async { [self] in
            if leftDown { post(.leftMouseUp, lastPoint, .left) }
            if rightDown { post(.rightMouseUp, lastPoint, .right) }
            leftDown = false; rightDown = false
        }
    }

    // MARK: - Private

    private var bounds: CGRect {
        let b = CGDisplayBounds(displayID)
        return b.isEmpty ? fallbackBounds : b
    }

    private func point(_ x: Float, _ y: Float) -> CGPoint {
        let b = bounds
        let cx = min(max(Double(x), 0), 0.9999), cy = min(max(Double(y), 0), 0.9999)
        return CGPoint(x: b.minX + cx * b.width, y: b.minY + cy * b.height)
    }

    private func pointer(_ action: InputEvent.PointerAction, _ button: InputEvent.Button, _ p: CGPoint) {
        lastPoint = p
        switch (action, button) {
        case (.move, _):
            if leftDown { post(.leftMouseDragged, p, .left) }
            else if rightDown { post(.rightMouseDragged, p, .right) }
            else { post(.mouseMoved, p, .left) }
        case (.down, .left):
            updateClickCount(p)
            leftDown = true
            post(.leftMouseDown, p, .left)
        case (.up, .left), (.cancel, .left):
            guard leftDown else { return }
            leftDown = false
            post(.leftMouseUp, p, .left)
        case (.down, .right):
            clickCount = 1
            rightDown = true
            post(.rightMouseDown, p, .right)
        case (.up, .right), (.cancel, .right):
            guard rightDown else { return }
            rightDown = false
            post(.rightMouseUp, p, .right)
        }
    }

    private func updateClickCount(_ p: CGPoint) {
        let now = ProcessInfo.processInfo.systemUptime
        let close = hypot(p.x - lastClickPoint.x, p.y - lastClickPoint.y) < 8
        clickCount = (now - lastClickTime < NSEventDoubleClickInterval && close) ? clickCount + 1 : 1
        lastClickTime = now
        lastClickPoint = p
    }

    private func post(_ type: CGEventType, _ p: CGPoint, _ button: CGMouseButton) {
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button)
        else { return }
        if type != .mouseMoved { e.setIntegerValueField(.mouseEventClickState, value: max(clickCount, 1)) }
        e.post(tap: .cghidEventTap)
    }

    private func scroll(dx: Float, dy: Float) {
        // Video pixels → points on the virtual display; finger direction = content direction ("natural").
        let b = bounds
        let scale = videoPixelWidth > 0 && b.width > 0 ? b.width / Double(videoPixelWidth) : 1.0
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                              wheel1: Int32((Double(dy) * scale).rounded()),
                              wheel2: Int32((Double(dx) * scale).rounded()), wheel3: 0)
        else { return }
        e.location = lastPoint
        e.post(tap: .cghidEventTap)
    }

    private func key(_ down: Bool, _ modifiers: InputEvent.Modifiers, _ keyCode: UInt16) {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: down) else { return }
        var flags = CGEventFlags()
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.capsLock) { flags.insert(.maskAlphaShift) }
        e.flags = flags
        e.post(tap: .cghidEventTap)
    }
}

// AppKit's NSEvent.doubleClickInterval without importing AppKit into the core.
private let NSEventDoubleClickInterval: TimeInterval = {
    let v = UserDefaults.standard.double(forKey: "com.apple.mouse.doubleClickThreshold")
    return v > 0 ? v : 0.5
}()
