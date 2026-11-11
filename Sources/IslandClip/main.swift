import AppKit

// Agent app: no Dock icon, no app-switcher entry (LSUIElement in Info.plist;
// set here too so `swift run` behaves the same).
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
