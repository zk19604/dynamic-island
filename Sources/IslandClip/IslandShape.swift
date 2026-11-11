import SwiftUI

/// Island outline: flat top flush with the screen edge, small concave flares
/// at the top corners (like the MacBook notch), large rounded bottom corners.
/// Both radii animate smoothly.
struct IslandShape: Shape {
    var topFlare: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topFlare, bottomRadius) }
        set { topFlare = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let flare = max(0, min(topFlare, w / 4, h / 2))
        let bodyWidth = w - flare * 2
        let r = max(0, min(bottomRadius, bodyWidth / 2, h - flare))
        // Control-point factor for a smooth, "continuous"-looking corner.
        let k: CGFloat = 0.55

        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        // Left flare (concave), curving down into the body.
        p.addCurve(to: CGPoint(x: rect.minX + flare, y: rect.minY + flare),
                   control1: CGPoint(x: rect.minX + flare * k, y: rect.minY),
                   control2: CGPoint(x: rect.minX + flare, y: rect.minY + flare * (1 - k)))
        p.addLine(to: CGPoint(x: rect.minX + flare, y: rect.maxY - r))
        // Bottom-left corner.
        p.addCurve(to: CGPoint(x: rect.minX + flare + r, y: rect.maxY),
                   control1: CGPoint(x: rect.minX + flare, y: rect.maxY - r * (1 - k)),
                   control2: CGPoint(x: rect.minX + flare + r * (1 - k), y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - flare - r, y: rect.maxY))
        // Bottom-right corner.
        p.addCurve(to: CGPoint(x: rect.maxX - flare, y: rect.maxY - r),
                   control1: CGPoint(x: rect.maxX - flare - r * (1 - k), y: rect.maxY),
                   control2: CGPoint(x: rect.maxX - flare, y: rect.maxY - r * (1 - k)))
        p.addLine(to: CGPoint(x: rect.maxX - flare, y: rect.minY + flare))
        // Right flare.
        p.addCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                   control1: CGPoint(x: rect.maxX - flare, y: rect.minY + flare * (1 - k)),
                   control2: CGPoint(x: rect.maxX - flare * k, y: rect.minY))
        p.closeSubpath()
        return p
    }
}
