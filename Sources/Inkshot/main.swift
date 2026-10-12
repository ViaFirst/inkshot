import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    if SelfTest.runIfRequested() {
        app.setActivationPolicy(.accessory) // same as the real app: allowed to show windows
        app.run()
    }
    LegacyMigration.run() // before AppDelegate: it opens the history store
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
