import AppKit
import IslandClipCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var services: IslandServices!
    private var island: IslandWindowController!
    private var menuBar: MenuBarController!

    private static let islandHiddenKey = "IslandHidden"

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN) // a dead media helper must not kill the app

        Persistence.migrateLegacyDirectory() // IslandClip → dynamic-island, once
        let persistence = Persistence(directory: Persistence.defaultDirectory())
        let clipboard = ClipboardStore(persistence: persistence, maxUnpinned: Constants.maxUnpinnedClipboardItems)
        let notes = NotesStore(persistence: persistence, saveDelay: Constants.notesSaveDebounce)
        let monitor = ClipboardMonitor { text in clipboard.add(text) }
        let nowPlaying = NowPlayingService()
        services = IslandServices(clipboard: clipboard, notes: notes, monitor: monitor, nowPlaying: nowPlaying)

        let args = ProcessInfo.processInfo.arguments
        island = IslandWindowController(services: services, stayExpanded: args.contains("--expanded"))

        menuBar = MenuBarController(
            isIslandVisible: { [weak self] in self?.island.isVisible ?? false },
            setIslandVisible: { [weak self] visible in
                guard let self else { return }
                visible ? self.island.show() : self.island.hide()
                UserDefaults.standard.set(!visible, forKey: Self.islandHiddenKey)
            },
            clearHistory: { clipboard.clearUnpinned() })

        if UserDefaults.standard.bool(forKey: Self.islandHiddenKey) && !args.contains("--expanded") {
            island.hide()
        } else {
            island.show()
        }
        monitor.start()
        nowPlaying.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        services?.monitor.stop()
        services?.clipboard.saveNow()
        services?.notes.saveNow()
        services?.nowPlaying.stop()
    }
}
