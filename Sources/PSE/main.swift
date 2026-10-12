import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    if RenderSelfTest.runIfRequested() {
        app.setActivationPolicy(.prohibited)
        app.run()
    }
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
