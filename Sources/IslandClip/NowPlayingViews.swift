import AppKit
import SwiftUI

/// Expanded music card: artwork, title/artist, waveform, scrubber, controls.
struct NowPlayingCard: View {
    @ObservedObject var service: NowPlayingService
    @Environment(\.colorScheme) private var colorScheme

    /// Album color, darkened on the Light theme so it stays visible on white.
    private var accent: Color {
        colorScheme == .light ? service.accentColorOnLight : service.accentColor
    }

    var body: some View {
        if let info = service.info {
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    Button(action: service.openSourceApp) {
                        ArtworkView(image: service.artwork, cornerRadius: 10)
                            .frame(width: 50, height: 50)
                            .shadow(color: accent.opacity(0.25), radius: 8, y: 2)
                    }
                    .buttonStyle(PressableButtonStyle(pressedScale: 0.93))
                    .help("Open \(appName(info) ?? "player")")

                    VStack(alignment: .leading, spacing: 2) {
                        Text(info.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(info.artist.isEmpty ? info.album : info.artist)
                            .font(.system(size: 12))
                            .foregroundStyle(.primary.opacity(0.55))
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(.easeInOut(duration: 0.2), value: info.title)

                    WaveformView(isPlaying: info.isPlaying, color: accent, barCount: 5)
                        .frame(width: 22, height: 16)
                }

                ProgressScrubber(info: info, accent: accent, onSeek: service.seek(to:))

                HStack(spacing: 0) {
                    sourceAppButton(info)
                    Spacer()
                    controlButton("backward.fill", size: 17, action: service.previous)
                    Spacer().frame(width: 34)
                    controlButton(info.isPlaying ? "pause.fill" : "play.fill", size: 24, action: service.togglePlayPause)
                        .frame(width: 30)
                    Spacer().frame(width: 34)
                    controlButton("forward.fill", size: 17, action: service.next)
                    Spacer()
                    Color.clear.frame(width: 22, height: 22) // balances the app icon
                }
            }
        }
    }

    private func appName(_ info: NowPlayingInfo) -> String? {
        guard let id = info.bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    @ViewBuilder
    private func sourceAppButton(_ info: NowPlayingInfo) -> some View {
        if let icon = service.sourceAppIcon {
            Button(action: service.openSourceApp) {
                Image(nsImage: icon).resizable().frame(width: 22, height: 22)
            }
            .buttonStyle(PressableButtonStyle())
            .help("Open \(appName(info) ?? "player")")
        } else {
            Color.clear.frame(width: 22, height: 22)
        }
    }

    private func controlButton(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.primary)
                .contentTransition(.symbolEffectIfAvailable)
                .frame(width: 36, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
    }
}

private extension ContentTransition {
    static var symbolEffectIfAvailable: ContentTransition {
        if #available(macOS 14.0, *) { return .symbolEffect(.replace) }
        return .opacity
    }
}

/// Elapsed / bar / remaining. Drag or click the bar to seek; it thickens on hover.
struct ProgressScrubber: View {
    let info: NowPlayingInfo
    let accent: Color
    let onSeek: (Double) -> Void

    @State private var dragFraction: Double?
    @State private var hovering = false

    var body: some View {
        // Re-render once a second only while playing.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let duration = max(info.duration, 0)
            let position = dragFraction.map { $0 * duration } ?? info.position(at: context.date)
            let fraction = duration > 0 ? position / duration : 0

            HStack(spacing: 8) {
                Text(Self.format(position))
                    .frame(width: 36, alignment: .leading)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.18))
                        Capsule().fill(hovering || dragFraction != nil ? accent : Color.primary.opacity(0.85))
                            .frame(width: max(0, geo.size.width * fraction))
                    }
                    .frame(height: hovering || dragFraction != nil ? 7 : 4)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            dragFraction = min(max(value.location.x / geo.size.width, 0), 1)
                        }
                        .onEnded { value in
                            let f = min(max(value.location.x / geo.size.width, 0), 1)
                            if duration > 0 { onSeek(f * duration) }
                            dragFraction = nil
                        })
                }
                .frame(height: 14)
                .onHover { hovering = $0 }
                .animation(.spring(response: 0.3, dampingFraction: 0.75), value: hovering)
                Text("-" + Self.format(max(0, duration - position)))
                    .frame(width: 40, alignment: .trailing)
            }
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(.primary.opacity(0.5))
            .opacity(duration > 0 ? 1 : 0.4)
        }
    }

    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
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
