import AppKit

/// Where the island lives: the top-center of the primary (menu bar) screen.
struct ScreenGeometry: Equatable {
    var screenFrame: CGRect
    var hasNotch: Bool
    /// Size of the camera notch, or zero.
    var notchSize: CGSize
    /// Horizontal center for the island, in global screen coordinates.
    var centerX: CGFloat

    static func current() -> ScreenGeometry {
        // screens.first is the display with the menu bar ("main display" in System Settings).
        guard let screen = NSScreen.screens.first ?? NSScreen.main else {
            return ScreenGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                  hasNotch: false, notchSize: .zero, centerX: 720)
        }
        let frame = screen.frame
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            // The notch is the gap between the two usable menu bar areas.
            let width = right.minX - left.maxX
            let height = screen.safeAreaInsets.top
            if width > 0 {
                return ScreenGeometry(screenFrame: frame, hasNotch: true,
                                      notchSize: CGSize(width: width, height: height),
                                      centerX: frame.minX + (left.maxX + right.minX) / 2)
            }
        }
        return ScreenGeometry(screenFrame: frame, hasNotch: false, notchSize: .zero, centerX: frame.midX)
    }
}
