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

    /// ⌘X/C/V/A/Z and ⇧⌘Z. Apps normally get these from the Edit menu, but
    /// this app has no menu bar and the panel never activates the app, so
    /// send them to the focused text view directly.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), !flags.contains(.control), !flags.contains(.option),
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        let shift = flags.contains(.shift)
        let action: Selector?
        switch (key, shift) {
        case ("x", false): action = #selector(NSText.cut(_:))
        case ("c", false): action = #selector(NSText.copy(_:))
        case ("v", false): action = #selector(NSText.paste(_:))
        case ("v", true): action = #selector(NSTextView.pasteAsPlainText(_:))
        case ("a", false): action = #selector(NSText.selectAll(_:))
        case ("z", false): action = Selector(("undo:"))
        case ("z", true): action = Selector(("redo:"))
        default: action = nil
        }
        if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
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
