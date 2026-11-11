import CoreGraphics
import Foundation
import SwiftUI

/// All tunable sizes and timings in one place.
enum Constants {
    // MARK: Island shape (points)

    /// Visible pill on Macs without a notch.
    static let collapsedPillSize = CGSize(width: 120, height: 30)
    /// Expanded panel width (including the small flares at the top corners).
    static let expandedWidth: CGFloat = 420
    /// Expanded height below the notch / menu-bar inset, without the music card.
    static let expandedContentHeight: CGFloat = 318
    /// Each app with media gets a row; the open one (or a lone app) also
    /// shows transport buttons and a progress bar underneath.
    static let mediaRowHeight: CGFloat = 54
    static let mediaControlsHeight: CGFloat = 70
    static let maxMediaRows = 3

    /// Height the media area adds for `players` apps (0 = none).
    static func mediaHeight(players: Int, showsControls: Bool) -> CGFloat {
        guard players > 0 else { return 0 }
        let rows = CGFloat(min(players, maxMediaRows))
        let controls = players == 1 || showsControls ? mediaControlsHeight : 0
        return rows * mediaRowHeight + controls + 12
    }
    /// Width added on each side of the collapsed pill for live activities (music, "Copied").
    static let liveActivityWing: CGFloat = 40
    /// Wider wings for the "Copied" confirmation so the word fits beside the notch.
    static let copiedWing: CGFloat = 76

    /// Concave "flare" where the island meets the top screen edge.
    static let collapsedTopFlare: CGFloat = 6
    static let expandedTopFlare: CGFloat = 14
    static let collapsedBottomRadiusNotch: CGFloat = 12
    static let expandedBottomRadius: CGFloat = 34

    /// Collapsed hover target is this much larger than the visible pill.
    static let hoverPadding: CGFloat = 6
    /// Transparent room around the expanded panel for its shadow.
    static let shadowMargin: CGFloat = 30

    // MARK: Timing

    static let collapseDelay: TimeInterval = 0.3
    /// Liquid open: width and height move together (no lag), with a small
    /// droplet-like wobble as it settles.
    static let expandSpring = Animation.spring(response: 0.4, dampingFraction: 0.72)
    /// Liquid close: quick pull back into the pill with a gentle wobble.
    static let collapseSpring = Animation.spring(response: 0.34, dampingFraction: 0.8)
    /// How long to keep the window big after a shrink animation starts.
    static let settleDelay: TimeInterval = 0.85
    static let copiedToastDuration: TimeInterval = 1.3
    /// Dark tint between the clear glass and the content (0 = none).
    static let glassDimming: Double = 0.4

    static let clipboardPollInterval: TimeInterval = 0.5
    static let maxUnpinnedClipboardItems = 5
    static let notesSaveDebounce: TimeInterval = 0.5

}
