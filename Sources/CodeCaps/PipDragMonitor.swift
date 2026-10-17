import AppKit

/// SwiftUI's ScrollViews and row gestures consume background mouse events.
/// Wait for an actual drag before handing it to AppKit, keeping clicks and
/// scrolling intact. Resize edges and the hover controls retain their events.
@MainActor
final class PipDragMonitor {
    private weak var window: NSWindow?
    private var monitor: Any?
    private var mouseDown: NSEvent?

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

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window else { return event }
        switch event.type {
        case .leftMouseDown:
            mouseDown = Self.canStart(at: event.locationInWindow, size: window.frame.size) ? event : nil
        case .leftMouseDragged:
            if let down = mouseDown {
                let dx = event.locationInWindow.x - down.locationInWindow.x
                let dy = event.locationInWindow.y - down.locationInWindow.y
                if hypot(dx, dy) >= 3 {
                    mouseDown = nil
                    window.performDrag(with: down)
                    return nil
                }
            }
        case .leftMouseUp:
            mouseDown = nil
        default: break
        }
        return event
    }
}
