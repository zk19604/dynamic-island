import AppKit
import SwiftUI

/// Borderless, transparent, non-activating floating panel.
///
/// Hovering and clicking buttons never steals focus from the app you're in.
/// `becomesKeyOnlyIfNeeded` means the panel only becomes key when you click a
/// text view/field (notes, search), which is exactly when typing must work.
final class IslandPanel: NSPanel {
    var onCancel: (() -> Void)?

    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 200, height: 40),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false // drawn by SwiftUI so it follows the island shape
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        appearance = NSAppearance(named: .darkAqua) // updated per theme by the controller
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    private(set) var isReallyKey = false

    override func becomeKey() {
        super.becomeKey()
        isReallyKey = true
    }

    override func resignKey() {
        super.resignKey()
        isReallyKey = false
    }

    /// Esc while typing: drop focus and let the island collapse.
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    /// True while a text view or field inside the panel is being edited.
    var isEditingText: Bool {
        isReallyKey && firstResponder is NSText
    }
}

/// Hosting view that reports where the mouse is inside the window (nil when
/// it leaves) and accepts the first click even though the panel is never
/// "active". The controller decides whether that point is on the island.
final class IslandHostingView<Content: View>: NSHostingView<Content> {
    var onMouse: ((CGPoint?) -> Void)?
    private var hoverArea: NSTrackingArea?

    required init(rootView: Content) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if event.trackingArea === hoverArea { onMouse?(event.locationInWindow) }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onMouse?(event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if event.trackingArea === hoverArea { onMouse?(nil) }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
