import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    if RenderSelfTest.runIfRequested() {
        app.setActivationPolicy(.accessory) // same as the real app: allowed to show windows
        app.run()
    }
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
