import AppKit
import SwiftUI
import os

struct NowPlayingInfo: Equatable, Identifiable {
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var elapsed: Double
    /// When `elapsed` was measured.
    var timestamp: Date
    var rate: Double
    var isPlaying: Bool
    var bundleID: String?
    var artworkID: String?
    /// False when showing an app other than the system's now-playing app.
    var canSeek: Bool = true
    /// The system's "now playing" app (as opposed to another app with media).
    var isSystem: Bool = true

    var id: String { bundleID ?? "system" }

    /// Playback position at `date`, extrapolated while playing.
    func position(at date: Date) -> Double {
        var value = elapsed
        if isPlaying {
            value += date.timeIntervalSince(timestamp) * (rate > 0 ? rate : 1)
        }
        if duration > 0 { value = min(value, duration) }
        return max(0, value)
    }
}

/// Reads system "Now Playing" info (Music, Spotify, browsers, …) and sends
/// play/pause/skip/seek commands.
///
/// Runs `/usr/bin/perl` hosting `libIslandMediaHelper.dylib`; see
/// IslandMediaHelper.m for why. Communication is plain pipes; all local.
final class NowPlayingService: ObservableObject {
    /// Every app with media (Spotify, a browser tab, …), in the order they
    /// first appeared so rows don't jump around while you click them.
    @Published private(set) var players: [NowPlayingInfo] = []
    /// The most recently played one: shown in the collapsed island and the
    /// single-player card.
    @Published private(set) var info: NowPlayingInfo?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var accentColor: Color = .white
    /// Same hue, darkened: readable on the white (Light theme) island.
    @Published private(set) var accentColorOnLight: Color = Color(white: 0.25)

    private struct Artwork {
        let image: NSImage
        let color: Color
        let onLight: Color
    }

    private static let log = Logger(subsystem: "com.zk19604.dynamic-island", category: "nowplaying")
    private static let perlLoader = """
    use strict; use DynaLoader;
    my $h = DynaLoader::dl_load_file($ARGV[0], 0) or die DynaLoader::dl_error();
    my $s = DynaLoader::dl_find_symbol($h, "islandmedia_run") or die DynaLoader::dl_error();
    DynaLoader::dl_install_xsub("main::islandmedia_run", $s);
    main::islandmedia_run();
    """

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var restartCount = 0
    private var isStopping = false
    private var artworks: [String: Artwork] = [:]
    /// Player id -> when it last started playing / was last seen playing.
    private var startedAt: [String: Date] = [:]
    private var lastPlayingAt: [String: Date] = [:]
    private var appearanceOrder: [String] = []
    private var iconCache: [String: NSImage] = [:]
    private let parseQueue = DispatchQueue(label: "islandclip.nowplaying")

    func start() {
        guard process == nil else { return }
        isStopping = false
        guard let library = Self.helperLibraryURL() else {
            Self.log.notice("Media helper library not found; Now Playing disabled")
            return
        }
        let perl = URL(fileURLWithPath: "/usr/bin/perl")
        guard FileManager.default.isExecutableFile(atPath: perl.path) else {
            Self.log.notice("/usr/bin/perl missing; Now Playing disabled")
            return
        }

        let process = Process()
        process.executableURL = perl
        process.arguments = ["-e", Self.perlLoader, library.path]
        let stdout = Pipe(), stdin = Pipe()
        process.standardOutput = stdout
        process.standardInput = stdin
        process.standardError = FileHandle.nullDevice

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self?.parseQueue.async { self?.consume(data) }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.helperExited() }
        }
        do {
            try process.run()
            self.process = process
            self.input = stdin.fileHandleForWriting
        } catch {
            Self.log.error("Could not start media helper: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        isStopping = true
        try? input?.close()
        process?.terminate()
        process = nil
        input = nil
    }

    // MARK: - Commands

    func togglePlayPause(_ player: NowPlayingInfo) {
        // Explicit play/pause (not toggle) so a stale state can't flip it twice.
        send(player.isPlaying ? "pause" : "play", to: player)
        update(player.id) { current in // optimistic, so the button reacts instantly
            current.elapsed = current.position(at: Date())
            current.timestamp = Date()
            current.isPlaying.toggle()
        }
    }

    func next(_ player: NowPlayingInfo) { send("next", to: player) }
    func previous(_ player: NowPlayingInfo) { send("prev", to: player) }

    func seek(_ player: NowPlayingInfo, to seconds: Double) {
        guard player.canSeek else { return }
        send(String(format: "seek %.2f", seconds), to: player)
        update(player.id) { current in
            current.elapsed = seconds
            current.timestamp = Date()
        }
    }

    func openApp(of player: NowPlayingInfo) {
        guard let id = player.bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    var sourceAppIcon: NSImage? { info.flatMap(appIcon(for:)) }

    func appIcon(for player: NowPlayingInfo) -> NSImage? {
        guard let id = player.bundleID else { return nil }
        if let cached = iconCache[id] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        iconCache[id] = icon
        return icon
    }

    func appName(for player: NowPlayingInfo) -> String? {
        guard let id = player.bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    func artwork(for player: NowPlayingInfo) -> NSImage? {
        player.artworkID.flatMap { artworks[$0]?.image }
    }

    func accentColor(for player: NowPlayingInfo, onLight: Bool) -> Color {
        guard let art = player.artworkID.flatMap({ artworks[$0] }) else {
            return onLight ? Color(white: 0.25) : .white
        }
        return onLight ? art.onLight : art.color
    }

    /// Whether the island's buttons can control this player.
    func canControl(_ player: NowPlayingInfo) -> Bool {
        player.isSystem || ScriptablePlayer(bundleID: player.bundleID) != nil
    }

    private func send(_ command: String, to player: NowPlayingInfo) {
        // macOS only delivers media commands to its "now playing" app, so
        // other players are driven over AppleScript when they support it.
        if !player.isSystem {
            ScriptablePlayer(bundleID: player.bundleID)?.run(command)
            return
        }
        var line = command
        if let id = player.bundleID, !id.contains(" ") { line += " " + id }
        guard let input else { return }
        try? input.write(contentsOf: Data((line + "\n").utf8))
    }

    private func update(_ id: String, _ change: (inout NowPlayingInfo) -> Void) {
        guard let index = players.firstIndex(where: { $0.id == id }) else { return }
        var list = players
        change(&list[index])
        apply(list)
    }

    // MARK: - Helper output

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            handle(line: Data(line))
        }
    }

    /// Runs on parseQueue; publishes on main.
    private func handle(line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        guard let list = object["players"] as? [[String: Any]] else {
            if object["empty"] != nil || object["error"] != nil {
                DispatchQueue.main.async { self.apply([]) }
            }
            return
        }
        let now = Date()
        var parsed: [NowPlayingInfo] = []
        var newArtwork: [String: Artwork] = [:]
        for entry in list {
            guard let title = entry["title"] as? String else { continue }
            let player = NowPlayingInfo(
                title: title,
                artist: entry["artist"] as? String ?? "",
                album: entry["album"] as? String ?? "",
                duration: entry["duration"] as? Double ?? 0,
                elapsed: entry["elapsed"] as? Double ?? 0,
                timestamp: (entry["timestamp"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? now,
                rate: entry["rate"] as? Double ?? 0,
                isPlaying: entry["playing"] as? Bool ?? false,
                bundleID: entry["bundleID"] as? String,
                artworkID: entry["artworkID"] as? String,
                canSeek: (entry["canSeek"] as? Bool ?? true)
                    || ScriptablePlayer(bundleID: entry["bundleID"] as? String) != nil,
                isSystem: entry["system"] as? Bool ?? true)
            if let id = player.artworkID, let base64 = entry["artwork"] as? String,
               let data = Data(base64Encoded: base64), let image = NSImage(data: data) {
                newArtwork[id] = Artwork(image: image, color: Self.accentColor(for: image),
                                         onLight: Self.accentColor(for: image, onLight: true))
            }
            parsed.append(player)
        }

        DispatchQueue.main.async {
            self.artworks.merge(newArtwork) { _, new in new }
            self.apply(parsed)
            self.restartCount = 0
        }
    }

    /// Updates recency, order, the primary player and its artwork. Main thread.
    private func apply(_ list: [NowPlayingInfo]) {
        let now = Date()
        let previous = Dictionary(players.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for player in list where player.isPlaying {
            if previous[player.id]?.isPlaying != true { startedAt[player.id] = now }
            lastPlayingAt[player.id] = now
        }

        let ids = Set(list.map(\.id))
        appearanceOrder.removeAll { !ids.contains($0) }
        for player in list where !appearanceOrder.contains(player.id) { appearanceOrder.append(player.id) }
        let ordered = list.sorted {
            (appearanceOrder.firstIndex(of: $0.id) ?? 0) < (appearanceOrder.firstIndex(of: $1.id) ?? 0)
        }

        // Most recently played: the one that started playing last; if nothing
        // plays, the one that played last; otherwise the system's app.
        let distantPast = Date.distantPast
        let primary = list.filter(\.isPlaying).max {
            (startedAt[$0.id] ?? distantPast) < (startedAt[$1.id] ?? distantPast)
        } ?? list.max {
            let a = lastPlayingAt[$0.id] ?? distantPast, b = lastPlayingAt[$1.id] ?? distantPast
            if a != b { return a < b }
            return !$0.isSystem && $1.isSystem
        }

        if players != ordered { players = ordered }
        if info != primary { info = primary }

        let art = primary?.artworkID.flatMap { artworks[$0] }
        if artwork !== art?.image { artwork = art?.image }
        accentColor = art?.color ?? .white
        accentColorOnLight = art?.onLight ?? Color(white: 0.25)

        // Drop artwork nobody shows any more.
        // Drop artwork nobody shows any more; ask the helper to resend
        // images when they come back.
        if artworks.count > 30 {
            let used = Set(list.compactMap(\.artworkID))
            artworks = artworks.filter { used.contains($0.key) }
            if let input { try? input.write(contentsOf: Data("forget-artwork\n".utf8)) }
        }
    }

    private func helperExited() {
        process = nil
        input = nil
        parseQueue.async { self.buffer.removeAll() }
        guard !isStopping else { return }
        // Retry a few times with backoff, then give up quietly.
        restartCount += 1
        guard restartCount <= 5 else {
            Self.log.error("Media helper keeps exiting; Now Playing disabled")
            apply([])
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(restartCount * 2)) { [weak self] in
            self?.start()
        }
    }

    // MARK: - Utilities

    static func helperLibraryURL() -> URL? {
        let name = "libIslandMediaHelper.dylib"
        var candidates: [URL] = []
        if let frameworks = Bundle.main.privateFrameworksURL {
            candidates.append(frameworks.appendingPathComponent(name))
        }
        if let exe = Bundle.main.executableURL {
            // `swift run` / `.build/release/IslandClip`
            candidates.append(exe.deletingLastPathComponent().appendingPathComponent(name))
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Average artwork color, brightened to read on black (or darkened to
    /// read on white when `onLight`).
    static func accentColor(for image: NSImage, onLight: Bool = false) -> Color {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return .white }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .white }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let color = NSColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
                            blue: CGFloat(pixel[2]) / 255, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.usingColorSpace(.deviceRGB)?.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        if onLight {
            return Color(hue: h, saturation: max(min(s, 0.8), 0.35), brightness: min(b, 0.5))
        }
        return Color(hue: h, saturation: min(s, 0.75), brightness: max(b, 0.82))
    }
}

/// Players that take commands over AppleScript (asks for Automation
/// permission the first time). Used for apps other than the system's
/// now-playing app, which MediaRemote can't target.
struct ScriptablePlayer {
    let bundleID: String

    private static let supported: Set<String> = ["com.spotify.client", "com.apple.Music"]
    private static let queue = DispatchQueue(label: "islandclip.applescript")

    init?(bundleID: String?) {
        guard let bundleID, Self.supported.contains(bundleID) else { return nil }
        self.bundleID = bundleID
    }

    /// Takes the helper's command words: play, pause, toggle, next, prev, seek <seconds>.
    func run(_ command: String) {
        let parts = command.split(separator: " ")
        let verb: String
        switch parts.first {
        case "play": verb = "play"
        case "pause": verb = "pause"
        case "toggle": verb = "playpause"
        case "next": verb = "next track"
        case "prev": verb = "previous track"
        case "seek":
            guard parts.count > 1, let seconds = Double(parts[1]) else { return }
            verb = String(format: "set player position to %.2f", seconds)
        default: return
        }
        let source = "tell application id \"\(bundleID)\" to \(verb)"
        Self.queue.async {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
        }
    }
}
