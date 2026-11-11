import IslandClipCore
import SwiftUI

typealias ClipItemRef = ClipItem

/// Long-lived objects the views need.
final class IslandServices {
    let clipboard: ClipboardStore
    let notes: NotesStore
    let monitor: ClipboardMonitor
    let nowPlaying: NowPlayingService

    init(clipboard: ClipboardStore, notes: NotesStore, monitor: ClipboardMonitor, nowPlaying: NowPlayingService) {
        self.clipboard = clipboard
        self.notes = notes
        self.monitor = monitor
        self.nowPlaying = nowPlaying
    }

    /// Copies arbitrary text (e.g. a note) and records it at the top of the history.
    func copyText(_ text: String) {
        monitor.write(text)
        clipboard.add(text)
    }

    func copyToPasteboard(_ item: ClipItem) {
        monitor.write(item.text)
        clipboard.touch(item.id)
    }
}

struct IslandActions {
    var copy: (ClipItem) -> Void
    var collapse: () -> Void
    var focusPanel: () -> Void
}

// MARK: - Root

struct IslandRootView: View {
    @ObservedObject var model: IslandViewModel
    let services: IslandServices
    let actions: IslandActions
    /// Light theme uses dark text; dark and clear glass use white text
    /// (Apple's clear glass pairs with bright, white content).
    private var contentColorScheme: ColorScheme {
        model.isThemed && model.theme == .light ? .light : .dark
    }

    var body: some View {
        let size = model.shapeSize
        let shape = IslandShape(topFlare: model.topFlare, bottomRadius: model.bottomRadius)

        ZStack(alignment: .top) {
            IslandBackground(shape: shape, theme: model.theme, themed: model.isThemed, expanded: model.isExpanded)

            // Clear Liquid Glass as its own layer. The dark tint sits on top
            // of it (not inside it): glass adapts to whatever is inside it, and
            // a dark layer inside makes the system switch to a frosted blur.
            let glassOn = model.isThemed && model.theme == .glass
            Color.clear.islandGlass(glassOn, in: shape)
                .id(model.glassGeneration)
                // The island never becomes the active window (it mustn't steal
                // focus), and glass in inactive windows renders frosted.
                // Always render it in its active, clear form.
                .environment(\.controlActiveState, .key)
            shape
                .fill(Color.black.opacity(Constants.glassDimming))
                .opacity(glassOn ? 1 : 0)
                .allowsHitTesting(false)

            ZStack(alignment: .top) {
                if model.isExpanded {
                    ExpandedIslandView(model: model, services: services, actions: actions)
                        // Laid out at the final size and revealed by the growing shape,
                        // so text never squishes mid-animation.
                        .frame(width: model.expandedSize.width, height: model.expandedSize.height, alignment: .top)
                        .transition(.panelContent)
                } else if model.activity != .none {
                    LiveActivityView(model: model, nowPlaying: services.nowPlaying)
                        .frame(width: size.width, height: size.height)
                        .transition(.islandContent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipShape(shape)
        }
        .frame(width: size.width, height: size.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, contentColorScheme)
        .animation(.easeInOut(duration: 0.3), value: model.theme)
    }
}

/// Island fill. Collapsed: always black (blends with the notch).
/// Expanded: dark, light, or Liquid Glass.
struct IslandBackground<S: Shape>: View {
    let shape: S
    let theme: IslandTheme
    /// Apply the theme (otherwise plain black for the notch).
    let themed: Bool
    /// Open panel: draws the drop shadow.
    let expanded: Bool

    var body: some View {
        let showLight = themed && theme == .light
        let showGlass = themed && theme == .glass
        ZStack {
            shape
                .fill(Color.black)
                .opacity(showGlass ? 0 : 1)
                .shadow(color: .black.opacity(expanded && !showGlass ? (showLight ? 0.25 : 0.5) : 0),
                        radius: 16, y: 8)
            shape
                .fill(Color(white: 0.97))
                .opacity(showLight ? 1 : 0)
        }
    }
}

extension View {
    /// Applies Liquid Glass (macOS 26+) behind this view's content, following
    /// Apple's "Adopting Liquid Glass": the system `.clear` material (highly
    /// transparent, refracts what's behind it) with no
    /// custom tint, blur, border or background under it. Toggling between
    /// `.regular` and `.identity` lets the system animate the glass in and out.
    /// Older systems get a frosted blur instead.
    @ViewBuilder
    func islandGlass<S: Shape>(_ active: Bool, in shape: S) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            glassEffect(active ? .clear : .identity, in: shape)
                .glassEffectTransition(.materialize)
        } else {
            background { if active { FrostedFallback(shape: shape).transition(.opacity) } }
        }
        #else
        background { if active { FrostedFallback(shape: shape).transition(.opacity) } }
        #endif
    }
}

/// Pre-macOS 26 stand-in for Liquid Glass: the system behind-window blur.
struct FrostedFallback<S: Shape>: View {
    let shape: S

    var body: some View {
        VisualEffectBlur()
            .clipShape(shape)
            .overlay(shape.stroke(Color.white.opacity(0.2), lineWidth: 1))
    }
}

/// Behind-window blur (the system's frosted material).
struct VisualEffectBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Dark / Light / Glass switcher shown in the panel's top-right corner.
struct ThemePicker: View {
    @Binding var theme: IslandTheme
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 2) {
            ForEach(IslandTheme.allCases) { option in
                let selected = option == theme
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { theme = option }
                } label: {
                    Image(systemName: option.symbol)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.primary.opacity(selected ? 0.95 : 0.45))
                        .frame(width: 22, height: 18)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(Color.primary.opacity(0.16))
                                    .matchedGeometryEffect(id: "theme", in: highlight)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(PressableButtonStyle(pressedScale: 0.9))
                .help("\(option.label) theme")
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
    }
}


/// Apple-style content reveal: fade + slight scale + blur, slightly delayed
/// on the way in so the shape leads; quick fade on the way out.
private struct RevealModifier: ViewModifier {
    let hidden: Bool
    func body(content: Content) -> some View {
        content
            .opacity(hidden ? 0 : 1)
            .scaleEffect(hidden ? 0.94 : 1, anchor: .top)
            .blur(radius: hidden ? 6 : 0)
    }
}

/// Fade + gentle scale, no blur (cheap enough to stay at full frame rate).
private struct PanelRevealModifier: ViewModifier {
    let hidden: Bool
    func body(content: Content) -> some View {
        content
            .opacity(hidden ? 0 : 1)
            .scaleEffect(hidden ? 0.96 : 1, anchor: .top)
    }
}

extension AnyTransition {
    static var panelContent: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: PanelRevealModifier(hidden: true), identity: PanelRevealModifier(hidden: false))
                .animation(.easeOut(duration: 0.28).delay(0.12)),
            removal: .modifier(active: PanelRevealModifier(hidden: true), identity: PanelRevealModifier(hidden: false))
                .animation(.easeIn(duration: 0.1)))
    }

    static var islandContent: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: RevealModifier(hidden: true), identity: RevealModifier(hidden: false))
                .animation(.easeOut(duration: 0.26).delay(0.08)),
            removal: .modifier(active: RevealModifier(hidden: true), identity: RevealModifier(hidden: false))
                .animation(.easeIn(duration: 0.12)))
    }
}

// MARK: - Collapsed live activity

struct LiveActivityView: View {
    @ObservedObject var model: IslandViewModel
    @ObservedObject var nowPlaying: NowPlayingService

    var body: some View {
        let height = model.collapsedBodySize.height
        let iconSize = max(14, min(24, height - 12))
        HStack(spacing: 0) {
            switch model.activity {
            case .copied:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: iconSize * 0.8, weight: .semibold))
                    .foregroundStyle(.green)
                    .frame(width: iconSize, height: iconSize)
                Spacer(minLength: 0)
                Text("Copied")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                    .fixedSize()
            case .music, .none:
                ArtworkView(image: nowPlaying.artwork, cornerRadius: 5)
                    .frame(width: iconSize, height: iconSize)
                Spacer(minLength: 0)
                WaveformView(isPlaying: nowPlaying.info?.isPlaying == true,
                             color: model.theme == .light ? nowPlaying.accentColorOnLight : nowPlaying.accentColor,
                             barCount: 4)
                    .frame(width: iconSize * 0.9, height: iconSize * 0.7)
            }
        }
        .padding(.horizontal, model.topFlare + 10)
        .frame(height: height)
    }
}

// MARK: - Expanded

struct ExpandedIslandView: View {
    @ObservedObject var model: IslandViewModel
    let services: IslandServices
    let actions: IslandActions

    var body: some View {
        VStack(spacing: 12) {
            Color.clear.frame(height: model.contentTopInset - 4)
            if model.showsMediaCard {
                NowPlayingCard(service: services.nowPlaying)
                    .frame(height: Constants.mediaCardHeight - 12)
                    .transition(.opacity)
            }
            IslandTabBar(selection: $model.selectedTab)

            ZStack(alignment: .top) {
                switch model.selectedTab {
                case .clipboard:
                    ClipboardSectionView(store: services.clipboard, monitor: services.monitor,
                                         onCopy: actions.copy, focusPanel: actions.focusPanel)
                        .transition(.tabContent(edge: .leading))
                case .notes:
                    NotesSectionView(store: services.notes, onCopyText: { services.copyText($0) })
                        .transition(.tabContent(edge: .trailing))
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, Constants.expandedTopFlare + 14)
        .padding(.bottom, 16)
        .overlay(alignment: .topTrailing) {
            ThemePicker(theme: $model.theme)
                .frame(height: model.contentTopInset - 4)
                .padding(.trailing, Constants.expandedTopFlare + 14)
        }
    }
}

/// Segmented control with a highlight that slides between tabs.
struct IslandTabBar: View {
    @Binding var selection: IslandTab
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 2) {
            ForEach(IslandTab.allCases) { tab in
                let selected = tab == selection
                Button {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) { selection = tab }
                } label: {
                    Label(tab.rawValue, systemImage: tab.symbol)
                        .font(.system(size: 12, weight: selected ? .semibold : .medium))
                        .foregroundStyle(.primary.opacity(selected ? 0.95 : 0.5))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(Color.primary.opacity(0.14))
                                    .matchedGeometryEffect(id: "tab", in: highlight)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(PressableButtonStyle(pressedScale: 0.96))
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }
}

extension AnyTransition {
    /// Tab switch: slide a little from the tab's side and fade.
    static func tabContent(edge: Edge) -> AnyTransition {
        let dx: CGFloat = edge == .leading ? -24 : 24
        return .modifier(active: SlideFade(dx: dx, hidden: true), identity: SlideFade(dx: dx, hidden: false))
    }
}

private struct SlideFade: ViewModifier {
    let dx: CGFloat
    let hidden: Bool
    func body(content: Content) -> some View {
        content.offset(x: hidden ? dx : 0).opacity(hidden ? 0 : 1)
    }
}

struct ArtworkView: View {
    let image: NSImage?
    var cornerRadius: CGFloat = 10

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [Color(white: 0.28), Color(white: 0.16)], startPoint: .top, endPoint: .bottom)
                Image(systemName: "music.note")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// Scales down slightly while pressed, springs back. Used for all island buttons.
struct PressableButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.86
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
