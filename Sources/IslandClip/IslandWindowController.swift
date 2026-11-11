import AppKit
import Combine
import SwiftUI

/// Owns the panel and drives every island state change.
///
/// Sizing strategy: the window is resized instantly (never animated) to fit
/// the larger of the old and new shape, SwiftUI springs the shape inside it,
/// and once the animation settles the window shrinks to fit again. Because
/// the island is pinned to the window's top-center, resizing never moves it.
/// Keeping the window tight matters: its transparent area would otherwise
/// sit over other apps.
final class IslandWindowController {
    let panel = IslandPanel()
    let model: IslandViewModel
    private let services: IslandServices
    private var hostingView: IslandHostingView<IslandRootView>!

    private var isHovering = false
    /// After clicking an item the island collapses under the cursor; don't
    /// re-open until the mouse has left once.
    private var suppressHoverUntilExit = false
    private var collapseWork: DispatchWorkItem?
    private var settleWork: DispatchWorkItem?
    private var toastWork: DispatchWorkItem?
    private var musicHideWork: DispatchWorkItem?
    private var outsideClickMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    /// `--expanded` launch flag: stay open (handy for screenshots/debugging).
    private let stayExpanded: Bool

    private(set) var isVisible = true

    init(services: IslandServices, stayExpanded: Bool = false) {
        self.services = services
        self.stayExpanded = stayExpanded
        self.model = IslandViewModel(geometry: .current())

        let actions = IslandActions(
            copy: { [weak self] item in self?.copyBack(item) },
            collapse: { [weak self] in self?.collapse(force: true) },
            focusPanel: { [weak self] in self?.panel.makeKey() },
            showPlayerControls: { [weak self] id in self?.showPlayerControls(id) })
        let root = IslandRootView(model: model, services: services, actions: actions)
        hostingView = IslandHostingView(rootView: root)
        hostingView.sizingOptions = []
        hostingView.onMouse = { [weak self] point in self?.mouseMoved(to: point) }
        panel.contentView = hostingView
        panel.onCancel = { [weak self] in self?.endEditingAndCollapse() }

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.screenParametersChanged()
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                               object: panel, queue: .main) { [weak self] _ in
            self?.scheduleCollapse()
        }

        model.$theme
            .sink { [weak self] theme in
                guard let self else { return }
                switch theme {
                case .dark: self.panel.appearance = NSAppearance(named: .darkAqua)
                case .light: self.panel.appearance = NSAppearance(named: .aqua)
                case .glass: self.panel.appearance = NSAppearance(named: .darkAqua) // white text on clear glass
                }
                // Switching to Glass while open: render it clear right away.
                if theme == .glass && self.model.isExpanded { self.takeFocusForGlass() }
            }
            .store(in: &cancellables)

        services.nowPlaying.$info
            .combineLatest(services.nowPlaying.$players.map(\.count).removeDuplicates())
            .receive(on: DispatchQueue.main)
            .sink { [weak self] info, count in self?.nowPlayingChanged(info, playerCount: count) }
            .store(in: &cancellables)

        setWindowFrame(for: model.shapeSize, shadow: false)
        if stayExpanded {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.expand() }
        }
    }

    // MARK: - Visibility

    func show() {
        isVisible = true
        panel.orderFrontRegardless()
    }

    func hide() {
        isVisible = false
        collapse(force: true)
        panel.orderOut(nil)
    }

    // MARK: - Hover & focus

    /// The window is often bigger than the island (shadow room, or while it
    /// shrinks after closing), so only the island's own outline counts as
    /// hovering: the visible pill plus a few points when closed, the panel
    /// itself when open.
    private func mouseMoved(to point: CGPoint?) {
        let inside = point.map { hoverRect().contains($0) } ?? false
        guard inside != isHovering else { return }
        hoverChanged(inside)
    }

    /// Island outline in window coordinates (origin bottom-left).
    private func hoverRect() -> CGRect {
        let shape = model.shapeSize
        let pad: CGFloat = model.isExpanded ? 0 : Constants.hoverPadding
        let window = panel.frame.size
        return CGRect(x: (window.width - shape.width) / 2 - pad,
                      y: window.height - shape.height - pad,
                      width: shape.width + pad * 2,
                      height: shape.height + pad + 1) // +1: include the very top screen edge
    }

    private func hoverChanged(_ inside: Bool) {
        isHovering = inside
        if inside {
            collapseWork?.cancel()
            if !suppressHoverUntilExit { expand() }
        } else {
            suppressHoverUntilExit = false
            scheduleCollapse()
        }
    }

    private func scheduleCollapse() {
        collapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.collapse() }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.collapseDelay, execute: work)
    }

    private func endEditingAndCollapse() {
        panel.makeFirstResponder(nil)
        collapse(force: true)
    }

    /// Clicks in other apps end editing (a non-activating panel can stay
    /// "key" even after you click elsewhere). Mouse-only global monitors
    /// need no special permission. Installed only while expanded.
    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self else { return }
            if !self.panel.frame.contains(NSEvent.mouseLocation) {
                self.panel.makeFirstResponder(nil)
                self.scheduleCollapse()
            }
        }
    }

    private func removeOutsideClickMonitor() {
        if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor) }
        outsideClickMonitor = nil
    }

    // MARK: - Expand / collapse

    func expand() {
        guard isVisible, !model.isExpanded else { return }
        collapseWork?.cancel()
        // Close the "Copied" toast instantly so it doesn't fight the expansion.
        toastWork?.cancel()
        let activity = model.activity == .copied ? currentMusicActivity : model.activity
        transition(expanded: true, activity: activity, animation: Constants.expandSpring)
        installOutsideClickMonitor()
        if model.theme == .glass { takeFocusForGlass() }
    }

    func collapse(force: Bool = false) {
        guard model.isExpanded else { return }
        if !force {
            if stayExpanded || isHovering || panel.isEditingText { return }
        }
        if panel.isReallyKey { panel.makeFirstResponder(nil) }
        returnFocusIfTaken()
        services.notes.saveNow()
        removeOutsideClickMonitor()
        transition(expanded: false, activity: model.activity, animation: Constants.collapseSpring)
    }

    // MARK: - Glass focus

    /// Set while the island holds keyboard focus only so Liquid Glass renders.
    private var tookFocusForGlass = false

    /// Liquid Glass renders its clear, refractive look only in the key
    /// window (elsewhere it falls back to frosted). In the Glass theme the
    /// open island therefore becomes key; nothing inside gets text focus.
    private func takeFocusForGlass() {
        guard !panel.isReallyKey else { return }
        tookFocusForGlass = true
        panel.makeKey()
        panel.makeFirstResponder(hostingView) // not the search field
    }

    /// Gives keyboard focus back to the app you were using. Ordering the
    /// key panel out makes the system return key status to the active app;
    /// it's ordered straight back in within the same update, so nothing flickers.
    private func returnFocusIfTaken() {
        guard tookFocusForGlass else { return }
        tookFocusForGlass = false
        guard panel.isReallyKey else { return }
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        panel.orderOut(nil)
        panel.orderFrontRegardless()
        NSAnimationContext.endGrouping()
    }

    private func copyBack(_ item: ClipItemRef) {
        services.copyToPasteboard(item)
        suppressHoverUntilExit = isHovering
        collapse(force: true)
        showCopiedToast()
    }

    private func showCopiedToast() {
        toastWork?.cancel()
        transition(activity: .copied, animation: Constants.expandSpring)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.model.activity == .copied else { return }
            self.transition(activity: self.currentMusicActivity, animation: Constants.collapseSpring)
        }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.copiedToastDuration, execute: work)
    }

    // MARK: - Now Playing

    private var currentMusicActivity: LiveActivity {
        services.nowPlaying.info?.isPlaying == true ? .music : .none
    }

    private func showPlayerControls(_ id: String?) {
        guard id != model.expandedPlayerID, model.isExpanded || id == nil else { return }
        transition(expandedPlayer: .some(id), animation: Constants.expandSpring)
    }

    private func nowPlayingChanged(_ info: NowPlayingInfo?, playerCount: Int) {
        let count = min(playerCount, Constants.maxMediaRows)
        // Close a row whose app went away, or when only one app is left.
        let visible = services.nowPlaying.players.prefix(Constants.maxMediaRows).map(\.id)
        let openID = model.expandedPlayerID.flatMap { count > 1 && visible.contains($0) ? $0 : nil }
        if count != model.mediaPlayerCount || openID != model.expandedPlayerID {
            transition(mediaPlayers: count, expandedPlayer: .some(openID), animation: Constants.expandSpring)
        }
        guard model.activity != .copied else { return }
        if info?.isPlaying == true {
            musicHideWork?.cancel()
            if model.activity != .music { transition(activity: .music, animation: Constants.expandSpring) }
        } else if model.activity == .music, musicHideWork == nil || musicHideWork!.isCancelled {
            // Short grace period: players briefly report "paused" between tracks.
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.model.activity == .music, self.currentMusicActivity == .none else { return }
                self.transition(activity: LiveActivity.none, animation: Constants.collapseSpring)
            }
            musicHideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
        }
    }

    // MARK: - Geometry

    /// Applies a state change with a spring, growing the window first if
    /// needed and shrinking it after the animation settles.
    private func transition(expanded: Bool? = nil, activity: LiveActivity? = nil,
                            mediaPlayers: Int? = nil, expandedPlayer: String?? = nil,
                            animation: Animation) {
        let newExpanded = expanded ?? model.isExpanded
        let newActivity = activity ?? model.activity
        let newMedia = mediaPlayers ?? model.mediaPlayerCount
        // Collapsing the island closes any open media row.
        let newOpenPlayer = newExpanded ? (expandedPlayer ?? model.expandedPlayerID) : nil
        let old = model.shapeSize
        let new = model.shapeSize(expanded: newExpanded, activity: newActivity, mediaPlayers: newMedia,
                                  mediaControls: newOpenPlayer != nil)
        let shadow = newExpanded || model.isExpanded
        setWindowFrame(for: CGSize(width: max(old.width, new.width), height: max(old.height, new.height)),
                       shadow: shadow)

        withAnimation(animation) {
            model.isExpanded = newExpanded
            model.activity = newActivity
            model.mediaPlayerCount = newMedia
            model.expandedPlayerID = newOpenPlayer
        }

        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.setWindowFrame(for: self.model.shapeSize, shadow: self.model.isExpanded)
            if self.model.theme == .glass && self.model.isThemed {
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { self.model.glassGeneration += 1 }
            }
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.settleDelay, execute: work)
    }

    private func setWindowFrame(for shapeSize: CGSize, shadow: Bool) {
        let margin = shadow ? Constants.shadowMargin : Constants.hoverPadding
        let size = CGSize(width: ceil(shapeSize.width + margin * 2), height: ceil(shapeSize.height + margin))
        let geometry = model.geometry
        let frame = CGRect(x: round(geometry.centerX - size.width / 2),
                           y: geometry.screenFrame.maxY - size.height,
                           width: size.width, height: size.height)
        if panel.frame != frame {
            panel.setFrame(frame, display: false)
            // Lay out at the new size right now, outside any animation.
            // Otherwise SwiftUI keeps the old (narrower) layout for a frame and
            // the spring then slides the island sideways into the center.
            hostingView.layoutSubtreeIfNeeded()
            panel.displayIfNeeded()
        }
    }

    private func screenParametersChanged() {
        let geometry = ScreenGeometry.current()
        guard geometry != model.geometry else { return }
        model.geometry = geometry
        setWindowFrame(for: model.shapeSize, shadow: model.isExpanded)
    }
}
