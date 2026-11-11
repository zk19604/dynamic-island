import SwiftUI

/// Look of the expanded panel. The collapsed pill is always black so it
/// blends with the notch.
enum IslandTheme: String, CaseIterable, Identifiable {
    case dark, light, glass
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .dark: return "moon.fill"
        case .light: return "sun.max.fill"
        case .glass: return "drop.fill"
        }
    }
}

/// Tabs in the expanded panel.
enum IslandTab: String, CaseIterable, Identifiable {
    case clipboard = "Clipboard"
    case notes = "Notes"
    var id: String { rawValue }
    var symbol: String { self == .clipboard ? "doc.on.clipboard" : "note.text" }
}

/// What the collapsed island is showing besides the plain pill.
enum LiveActivity: Equatable {
    case none
    case music
    case copied
}

/// UI state for the island. Layout math lives here so the window controller
/// and the SwiftUI view always agree on sizes.
final class IslandViewModel: ObservableObject {
    @Published var isExpanded = false
    @Published var activity: LiveActivity = .none
    /// How many media apps the expanded panel shows (0 = no media area).
    @Published var mediaPlayerCount = 0
    var showsMediaCard: Bool { mediaPlayerCount > 0 }
    /// Player whose full controls are open (hovered or clicked row).
    @Published var expandedPlayerID: String?
    @Published var selectedTab: IslandTab = .clipboard
    /// Bumped after a resize animation settles to rebuild the glass layer.
    /// Glass created mid-animation (while the window resizes) renders frosted
    /// instead of clear; rebuilding it once things are still fixes that.
    @Published var glassGeneration = 0
    @Published var theme: IslandTheme =
        IslandTheme(rawValue: UserDefaults.standard.string(forKey: "Theme") ?? "") ?? .dark {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: "Theme") }
    }
    @Published var geometry: ScreenGeometry

    init(geometry: ScreenGeometry) {
        self.geometry = geometry
    }

    /// Whether the island currently shows the theme's look. The plain
    /// collapsed pill on a notch Mac stays black so it disappears into the
    /// notch; anything visible (open panel, music/"Copied" wings, or the pill
    /// on Macs without a notch) follows the theme.
    var isThemed: Bool {
        isExpanded || activity != .none || !geometry.hasNotch
    }

    // MARK: - Layout

    /// The visible pill (without top flares) when collapsed and idle.
    var collapsedBodySize: CGSize {
        geometry.hasNotch ? geometry.notchSize : Constants.collapsedPillSize
    }

    /// Space at the top of the expanded panel hidden by the notch / menu bar.
    var contentTopInset: CGFloat {
        // Room for the theme switcher in the top-right corner.
        geometry.hasNotch ? geometry.notchSize.height + 4 : 34
    }

    func shapeSize(expanded: Bool, activity: LiveActivity, mediaPlayers: Int, mediaControls: Bool) -> CGSize {
        if expanded {
            let height = contentTopInset + Constants.expandedContentHeight
                + Constants.mediaHeight(players: mediaPlayers, showsControls: mediaControls)
            return CGSize(width: Constants.expandedWidth,
                          height: min(height, geometry.screenFrame.height * 0.85))
        }
        var body = collapsedBodySize
        switch activity {
        case .none: break
        case .music: body.width += Constants.liveActivityWing * 2
        case .copied: body.width += Constants.copiedWing * 2
        }
        return CGSize(width: body.width + topFlare(expanded: false) * 2, height: body.height)
    }

    var shapeSize: CGSize { shapeSize(expanded: isExpanded, activity: activity, mediaPlayers: mediaPlayerCount,
                                                 mediaControls: expandedPlayerID != nil) }
    var expandedSize: CGSize { shapeSize(expanded: true, activity: activity, mediaPlayers: mediaPlayerCount,
                                                 mediaControls: expandedPlayerID != nil) }

    func topFlare(expanded: Bool) -> CGFloat {
        expanded ? Constants.expandedTopFlare : Constants.collapsedTopFlare
    }

    var topFlare: CGFloat { topFlare(expanded: isExpanded) }

    var bottomRadius: CGFloat {
        if isExpanded { return Constants.expandedBottomRadius }
        return geometry.hasNotch ? Constants.collapsedBottomRadiusNotch : collapsedBodySize.height / 2
    }
}
