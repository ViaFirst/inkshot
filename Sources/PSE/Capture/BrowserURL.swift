import AppKit

/// Reads the address of the front tab of a browser via AppleScript (Automation permission).
enum BrowserURL {
    enum Failure: LocalizedError {
        case notBrowser(String), notAllowed(String), noPage(String)

        var errorDescription: String? {
            switch self {
            case let .notBrowser(app):
                String(format: L("“%@” is not a supported browser. Full-page capture works with Safari, Chrome, Arc, Edge, Brave, Vivaldi and Opera."), app)
            case let .notAllowed(app):
                String(format: L("PSE isn't allowed to read the address from “%@”. Turn it on in System Settings → Privacy & Security → Automation → PSE."), app)
            case let .noPage(app):
                String(format: L("“%@” has no web page open in the front window."), app)
            }
        }
    }

    private static let safari: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]
    private static let chromium: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "company.thebrowser.Browser", "com.microsoft.edgemac", "com.brave.Browser", "com.vivaldi.Vivaldi",
        "org.chromium.Chromium", "com.operasoftware.Opera",
    ]

    @MainActor
    static func frontTabURL(of app: NSRunningApplication) throws -> URL {
        let name = app.localizedName ?? "?"
        guard let id = app.bundleIdentifier else { throw Failure.notBrowser(name) }
        let source: String
        if safari.contains(id) {
            source = "tell application id \"\(id)\" to get URL of current tab of front window"
        } else if chromium.contains(id) {
            source = "tell application id \"\(id)\" to get URL of active tab of front window"
        } else {
            throw Failure.notBrowser(name)
        }
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            throw code == -1743 ? Failure.notAllowed(name) : Failure.noPage(name)
        }
        guard let string = result?.stringValue, let url = URL(string: string),
              ["http", "https", "file"].contains(url.scheme ?? "") else { throw Failure.noPage(name) }
        return url
    }
}
