import AppKit
import SwiftUI
import os

struct NowPlayingInfo: Equatable {
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
    @Published private(set) var info: NowPlayingInfo?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var accentColor: Color = .white
    /// Same hue, darkened: readable on the white (Light theme) island.
    @Published private(set) var accentColorOnLight: Color = Color(white: 0.25)

    private static let log = Logger(subsystem: "com.example.islandclip", category: "nowplaying")
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
    private var artworkCache: (id: String, image: NSImage, color: Color, onLight: Color)?
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

    func togglePlayPause() {
        send("toggle")
        if var current = info { // optimistic update so the button reacts instantly
            current.elapsed = current.position(at: Date())
            current.timestamp = Date()
            current.isPlaying.toggle()
            info = current
        }
    }

    func next() { send("next") }
    func previous() { send("prev") }

    func seek(to seconds: Double) {
        send(String(format: "seek %.2f", seconds))
        if var current = info {
            current.elapsed = seconds
            current.timestamp = Date()
            info = current
        }
    }

    func openSourceApp() {
        guard let id = info?.bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    var sourceAppIcon: NSImage? {
        guard let id = info?.bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private func send(_ command: String) {
        guard let input else { return }
        try? input.write(contentsOf: Data((command + "\n").utf8))
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
        if object["empty"] != nil || object["error"] != nil {
            DispatchQueue.main.async {
                self.info = nil
                self.artwork = nil
            }
            return
        }
        guard let title = object["title"] as? String else { return }
        let parsed = NowPlayingInfo(
            title: title,
            artist: object["artist"] as? String ?? "",
            album: object["album"] as? String ?? "",
            duration: object["duration"] as? Double ?? 0,
            elapsed: object["elapsed"] as? Double ?? 0,
            timestamp: Date(timeIntervalSince1970: object["timestamp"] as? Double ?? Date().timeIntervalSince1970),
            rate: object["rate"] as? Double ?? 0,
            isPlaying: object["playing"] as? Bool ?? false,
            bundleID: object["bundleID"] as? String,
            artworkID: object["artworkID"] as? String)

        var newArtwork: (id: String, image: NSImage, color: Color, onLight: Color)?
        if let id = parsed.artworkID, let base64 = object["artwork"] as? String,
           let data = Data(base64Encoded: base64), let image = NSImage(data: data) {
            newArtwork = (id, image, Self.accentColor(for: image), Self.accentColor(for: image, onLight: true))
        }

        DispatchQueue.main.async {
            if let newArtwork { self.artworkCache = newArtwork }
            if let id = parsed.artworkID, let cache = self.artworkCache, cache.id == id {
                if self.artwork !== cache.image { self.artwork = cache.image }
                self.accentColor = cache.color
                self.accentColorOnLight = cache.onLight
            } else if parsed.artworkID == nil {
                self.artwork = nil
                self.accentColor = .white
                self.accentColorOnLight = Color(white: 0.25)
            }
            if self.info != parsed { self.info = parsed }
            self.restartCount = 0
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
            info = nil
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
