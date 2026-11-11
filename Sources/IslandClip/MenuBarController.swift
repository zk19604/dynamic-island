import AppKit
import ServiceManagement

/// Menu bar item: Show/Hide island, Clear history, Launch at login, Quit.
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let toggleIslandItem = NSMenuItem(title: "Hide Island", action: #selector(toggleIsland), keyEquivalent: "")
    private let launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")

    private let isIslandVisible: () -> Bool
    private let setIslandVisible: (Bool) -> Void
    private let clearHistory: () -> Void

    // TODO: Optional global keyboard shortcut to toggle the island. A Carbon
    // RegisterEventHotKey hot key needs no Accessibility permission.

    init(isIslandVisible: @escaping () -> Bool,
         setIslandVisible: @escaping (Bool) -> Void,
         clearHistory: @escaping () -> Void) {
        self.isIslandVisible = isIslandVisible
        self.setIslandVisible = setIslandVisible
        self.clearHistory = clearHistory
        super.init()

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "IslandClip")
                ?? NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "IslandClip")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "IslandClip"
        }

        let menu = NSMenu()
        menu.delegate = self
        toggleIslandItem.target = self
        launchAtLoginItem.target = self
        let clearItem = NSMenuItem(title: "Clear Clipboard History", action: #selector(clearClipboard), keyEquivalent: "")
        clearItem.target = self
        let quitItem = NSMenuItem(title: "Quit IslandClip", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self

        menu.addItem(toggleIslandItem)
        menu.addItem(clearItem)
        menu.addItem(.separator())
        menu.addItem(launchAtLoginItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        toggleIslandItem.title = isIslandVisible() ? "Hide Island" : "Show Island"
        launchAtLoginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func toggleIsland() {
        setIslandVisible(!isIslandVisible())
    }

    @objc private func clearClipboard() {
        clearHistory()
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = "\(error.localizedDescription)\n\nYou can also add IslandClip in System Settings › General › Login Items."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil) // AppDelegate saves in applicationWillTerminate
    }
}
