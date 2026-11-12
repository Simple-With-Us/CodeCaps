import AppKit

/// SwiftUI's ScrollViews and row gestures consume background mouse events.
/// Move in screen coordinates after an actual drag, keeping clicks and
/// scrolling intact. Resize edges and the hover controls retain their events.
@MainActor
final class PipDragMonitor {
    private weak var window: NSWindow?
    private var monitor: Any?
    private var mouseDown: NSEvent?
    private var startScreenPoint = NSPoint.zero
    private var startOrigin = NSPoint.zero
    private var dragging = false

    init(window: NSWindow) {
        self.window = window
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    static func canStart(at point: NSPoint, size: NSSize) -> Bool {
        let inset: CGFloat = 6
        guard point.x > inset, point.x < size.width - inset,
              point.y > inset, point.y < size.height - inset else { return false }
        return !(point.x > size.width - 52 && point.y > size.height - 30)
    }

    static func movedOrigin(start: NSPoint, mouseStart: NSPoint, mouseNow: NSPoint) -> NSPoint {
        NSPoint(x: start.x + mouseNow.x - mouseStart.x, y: start.y + mouseNow.y - mouseStart.y)
    }

    func handle(_ event: NSEvent, screenPoint: NSPoint? = nil) -> NSEvent? {
        guard let window, event.window === window else { return event }
        switch event.type {
        case .leftMouseDown:
            mouseDown = Self.canStart(at: event.locationInWindow, size: window.frame.size) ? event : nil
            startScreenPoint = screenPoint ?? NSEvent.mouseLocation
            startOrigin = window.frame.origin
            dragging = false
        case .leftMouseDragged:
            if mouseDown != nil {
                let current = screenPoint ?? NSEvent.mouseLocation
                let dx = current.x - startScreenPoint.x
                let dy = current.y - startScreenPoint.y
                if dragging || hypot(dx, dy) >= 3 {
                    dragging = true
                    window.setFrameOrigin(Self.movedOrigin(start: startOrigin, mouseStart: startScreenPoint, mouseNow: current))
                    return nil
                }
            }
        case .leftMouseUp:
            mouseDown = nil
            if dragging { dragging = false; return nil }
        default: break
        }
        return event
    }
}
