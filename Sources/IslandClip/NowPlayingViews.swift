import AppKit
import SwiftUI

/// A row per app with media (like Control Center). Hovering a row for a
/// moment, or clicking it, opens its full controls underneath; with a
/// single app they are always open.
struct NowPlayingSection: View {
    @ObservedObject var service: NowPlayingService
    @ObservedObject var model: IslandViewModel
    /// Asks the window to open (id) or close (nil) a row's controls.
    let showControls: (String?) -> Void

    @State private var pinnedID: String?
    @State private var hoverWork: DispatchWorkItem?

    var body: some View {
        let rows = Array(service.players.prefix(Constants.maxMediaRows))
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, player in
                if index > 0 {
                    Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 0.5)
                }
                let open = rows.count == 1 || model.expandedPlayerID == player.id
                NowPlayingRow(service: service, player: player, showsControls: open)
                    .contentShape(Rectangle())
                    .onTapGesture { togglePin(player.id) }
                    .onHover { inside in if inside { hovered(player.id) } }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onHover { inside in if !inside { hovered(nil) } }
        .onChange(of: model.isExpanded) { expanded in
            if !expanded { pinnedID = nil; hoverWork?.cancel() }
        }
    }

    private func togglePin(_ id: String) {
        guard service.players.count > 1 else { return }
        hoverWork?.cancel()
        pinnedID = pinnedID == id ? nil : id
        showControls(pinnedID)
    }

    /// Short dwell before opening (so passing over a row doesn't resize the
    /// panel); a bit longer before closing after the pointer leaves.
    private func hovered(_ id: String?) {
        hoverWork?.cancel()
        guard service.players.count > 1 else { return }
        let target = pinnedID ?? id
        guard target != model.expandedPlayerID else { return }
        let work = DispatchWorkItem { showControls(target) }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (id == nil ? 0.4 : 0.3), execute: work)
    }
}

/// Artwork with app badge, title/artist and play/pause + skip; when open,
/// back / play-pause / forward and a progress bar underneath.
struct NowPlayingRow: View {
    @ObservedObject var service: NowPlayingService
    let player: NowPlayingInfo
    let showsControls: Bool

    private var controllable: Bool { service.canControl(player) }

    var body: some View {
        VStack(spacing: 0) {
            header.frame(height: Constants.mediaRowHeight)
            if showsControls {
                controls
                    .frame(height: Constants.mediaControlsHeight, alignment: .top)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .clipped()
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { service.openApp(of: player) } label: { artwork }
                .buttonStyle(PressableButtonStyle(pressedScale: 0.93))
                .help("Open \(service.appName(for: player) ?? "player")")

            VStack(alignment: .leading, spacing: 2) {
                Text(player.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                let subtitle = player.artist.isEmpty ? (service.appName(for: player) ?? player.album) : player.artist
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary.opacity(0.55))
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)

            if showsControls {
                WaveformView(isPlaying: player.isPlaying,
                             color: service.accentColor(for: player, onLight: false), barCount: 5)
                    .frame(width: 22, height: 16)
                    .padding(.trailing, 6)
            } else {
                controlButton(player.isPlaying ? "pause.fill" : "play.fill", size: 20,
                              dim: !player.isPlaying) { service.togglePlayPause(player) }
                controlButton("forward.fill", size: 15, dim: true) { service.next(player) }
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 6) {
            HStack(spacing: 34) {
                controlButton("backward.fill", size: 17, dim: true) { service.previous(player) }
                controlButton(player.isPlaying ? "pause.fill" : "play.fill", size: 24, dim: false) {
                    service.togglePlayPause(player)
                }
                controlButton("forward.fill", size: 17, dim: true) { service.next(player) }
            }
            ProgressScrubber(info: player, accent: .accentColor) { service.seek(player, to: $0) }
        }
    }

    private func controlButton(_ symbol: String, size: CGFloat, dim: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffectIfAvailable)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .foregroundStyle(.primary.opacity(dim ? 0.6 : 0.9))
        .disabled(!controllable)
        .opacity(controllable ? 1 : 0.35)
        .help(controllable ? "" : "Control this one from \(service.appName(for: player) ?? "its app")")
    }

    /// Album art with a small app icon in the corner; just the app icon when
    /// there's no art (e.g. a browser tab).
    @ViewBuilder
    private var artwork: some View {
        let icon = service.appIcon(for: player)
        if let image = service.artwork(for: player) {
            ArtworkView(image: image, cornerRadius: 8)
                .frame(width: 40, height: 40)
                .overlay(alignment: .bottomTrailing) {
                    if let icon {
                        Image(nsImage: icon).resizable()
                            .frame(width: 18, height: 18)
                            .offset(x: 5, y: 5)
                    }
                }
                .padding(.trailing, 4)
        } else if let icon {
            Image(nsImage: icon).resizable()
                .frame(width: 40, height: 40)
                .padding(.trailing, 4)
        } else {
            ArtworkView(image: nil, cornerRadius: 8)
                .frame(width: 40, height: 40)
                .padding(.trailing, 4)
        }
    }
}

private extension ContentTransition {
    static var symbolEffectIfAvailable: ContentTransition {
        if #available(macOS 14.0, *) { return .symbolEffect(.replace) }
        return .opacity
    }
}

/// Bar with elapsed / remaining underneath. Drag or click the bar to seek;
/// it thickens on hover.
struct ProgressScrubber: View {
    let info: NowPlayingInfo
    let accent: Color
    let onSeek: (Double) -> Void

    @State private var dragFraction: Double?
    @State private var hovering = false

    var body: some View {
        // Re-render once a second.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let duration = max(info.duration, 0)
            let position = dragFraction.map { $0 * duration } ?? info.position(at: context.date)
            let fraction = duration > 0 ? position / duration : 0
            let active = hovering || dragFraction != nil

            VStack(spacing: 3) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.18))
                        Capsule().fill(accent)
                            .frame(width: max(0, geo.size.width * fraction))
                    }
                    .frame(height: active ? 7 : 5)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard info.canSeek else { return }
                            dragFraction = min(max(value.location.x / geo.size.width, 0), 1)
                        }
                        .onEnded { value in
                            guard info.canSeek else { return }
                            let f = min(max(value.location.x / geo.size.width, 0), 1)
                            if duration > 0 { onSeek(f * duration) }
                            dragFraction = nil
                        })
                }
                .frame(height: 12)
                .onHover { hovering = $0 && info.canSeek }
                .animation(.spring(response: 0.3, dampingFraction: 0.75), value: active)

                HStack {
                    Text(Self.format(position))
                    Spacer()
                    Text("\u{2212}" + Self.format(max(0, duration - position)))
                }
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.primary.opacity(0.5))
            }
            .opacity(duration > 0 ? 1 : 0.4)
        }
    }

    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "00:00" }
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Waveform

/// Animated equalizer bars. Uses Core Animation (rendered by the window
/// server), so it costs almost no CPU in the app even while visible.
struct WaveformView: NSViewRepresentable {
    var isPlaying: Bool
    var color: Color
    var barCount: Int

    func makeNSView(context: Context) -> WaveformNSView {
        WaveformNSView(barCount: barCount)
    }

    func updateNSView(_ view: WaveformNSView, context: Context) {
        view.update(color: NSColor(color), playing: isPlaying)
    }
}

final class WaveformNSView: NSView {
    private var bars: [CALayer] = []
    private var playing = false
    private static let durations: [Double] = [0.42, 0.55, 0.36, 0.5, 0.46, 0.6]

    init(barCount: Int) {
        super.init(frame: .zero)
        wantsLayer = true
        for _ in 0..<barCount {
            let bar = CALayer()
            bar.cornerCurve = .continuous
            layer?.addSublayer(bar)
            bars.append(bar)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let count = CGFloat(bars.count)
        let spacing = max(1.5, bounds.width * 0.12)
        let width = max(1.5, (bounds.width - spacing * (count - 1)) / count)
        for (i, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height)
            bar.position = CGPoint(x: CGFloat(i) * (width + spacing) + width / 2, y: bounds.midY)
            bar.cornerRadius = width / 2
        }
        CATransaction.commit()
    }

    func update(color: NSColor, playing: Bool) {
        bars.forEach { $0.backgroundColor = color.cgColor }
        guard playing != self.playing || bars.first?.animationKeys() == nil else { return }
        self.playing = playing
        for (i, bar) in bars.enumerated() {
            bar.removeAnimation(forKey: "wave")
            if playing {
                let anim = CABasicAnimation(keyPath: "transform.scale.y")
                anim.fromValue = 0.25
                anim.toValue = 1.0
                anim.duration = Self.durations[i % Self.durations.count]
                anim.autoreverses = true
                anim.repeatCount = .infinity
                anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                anim.beginTime = CACurrentMediaTime() + Double(i) * 0.07
                anim.fillMode = .backwards
                bar.add(anim, forKey: "wave")
                bar.transform = CATransform3DIdentity
            } else {
                bar.transform = CATransform3DMakeScale(1, 0.25, 1)
            }
        }
    }
}
