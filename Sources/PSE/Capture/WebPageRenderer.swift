import AppKit
import WebKit

/// Width used for full-page website captures.
enum PageWidth: String, CaseIterable {
    case window, desktop, mobile

    static let defaultsKey = "pageWidth"

    static var current: PageWidth {
        get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(PageWidth.init) ?? .window }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    func points(windowWidth: CGFloat) -> CGFloat {
        switch self {
        case .window: windowWidth
        case .desktop: 1440
        case .mobile: 390
        }
    }
}

/// Renders a whole web page in a hidden WKWebView and returns one tall image — no stitching.
/// The page is loaded fresh (as a guest: no browser cookies), scrolled through once so lazy images
/// load, then captured viewport by viewport at exact offsets (see snapshotTiles).
@MainActor
final class WebPageRenderer: NSObject, WKNavigationDelegate {
    enum Failure: LocalizedError {
        case load(String), empty, timeout

        var errorDescription: String? {
            switch self {
            case let .load(reason): String(format: L("The page could not be loaded: %@"), reason)
            case .empty: L("The page came out empty.")
            case .timeout: L("The page took too long to load.")
            }
        }
    }

    static let maxHeightPoints: CGFloat = 30000
    private static let maxPixels: CGFloat = 150_000_000

    private let webView: WKWebView
    private let host: NSWindow
    private let viewportHeight: CGFloat
    private var loadHandler: ((Result<Void, Error>) -> Void)?
    private var cancelled = false
    /// Tiling passes used by the last render (diagnostics).
    private(set) var attempts = 0

    init(width: CGFloat, viewportHeight: CGFloat = 900, mobile: Bool) {
        self.viewportHeight = viewportHeight
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
        let frame = CGRect(x: 0, y: 0, width: width, height: viewportHeight)
        webView = WKWebView(frame: frame, configuration: config)
        if mobile {
            // Some sites (and WPFF's server-side is_mobile) pick the layout by user agent, not width.
            webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 "
                + "(KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        }
        // The page needs a real window on a real display: requestAnimationFrame (GSAP, scroll-reveal
        // animations) is driven by the display the window is on, so an off-screen window never
        // animates. Put it on the main screen but below the desktop, where nobody sees it.
        let origin = NSScreen.screens.first?.frame.origin ?? .zero
        host = NSWindow(contentRect: CGRect(origin: origin, size: frame.size), styleMask: .borderless,
                        backing: .buffered, defer: false)
        host.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        host.ignoresMouseEvents = true
        host.hasShadow = false
        host.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        host.isReleasedWhenClosed = false
        host.contentView = webView
        super.init()
        webView.navigationDelegate = self
        host.orderFrontRegardless()
    }

    func cancel() {
        cancelled = true
        webView.stopLoading()
    }

    /// Returns the image and its scale (pixels per point).
    func render(_ url: URL, scale: CGFloat) async throws -> (CGImage, CGFloat) {
        defer { host.orderOut(nil) }

        try await waitForLoad(url)
        try checkCancelled()

        _ = try? await webView.callAsyncJavaScript(Self.preparePageScript, arguments: [:], contentWorld: .page)
        try checkCancelled()

        // Late content (ads, banners) can shift the layout mid-way and misalign the tiles:
        // redo the pass when that happens.
        var attempt = 0
        while true {
            attempt += 1
            attempts = attempt
            let pageHeight = try await pageHeight()
            // Pages with live blocks (typing effects, tickers) never fully settle; a third pass
            // doesn't help them, so the second pass is accepted as is.
            if let result = try await snapshotTiles(height: pageHeight, scale: scale, strict: attempt < 2) {
                return result
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func scrollY() async throws -> CGFloat {
        CGFloat((try? await webView.evaluateJavaScript("window.scrollY") as? Double) ?? 0)
    }

    private func pageHeight() async throws -> CGFloat {
        let h = (try? await webView.evaluateJavaScript(
            "Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0)"
        ) as? Double).map { CGFloat($0) } ?? viewportHeight
        return max(viewportHeight, min(Self.maxHeightPoints, h))
    }

    /// Didn't-finish-loading is normal for news sites (ads, counters keep loading): proceed once
    /// the document is complete, or 8 s after it became interactive. Fails only if nothing loads.
    private func waitForLoad(_ url: URL) async throws {
        var finished = false
        var failure: Error?
        loadHandler = { result in
            switch result {
            case .success: finished = true
            case let .failure(error): failure = error
            }
        }
        webView.load(URLRequest(url: url))
        let start = Date()
        var interactiveSince: Date?
        while true {
            try await Task.sleep(nanoseconds: 250_000_000)
            try checkCancelled()
            if let failure { throw failure }
            if finished { return }
            // Before the navigation commits, the view still shows about:blank, which is "complete"
            // right away: only trust readyState once the real page is there.
            let href = (try? await webView.evaluateJavaScript("location.href") as? String) ?? "about:blank"
            guard href.hasPrefix("http") || href.hasPrefix("file") else { continue }
            let state = (try? await webView.evaluateJavaScript("document.readyState") as? String) ?? ""
            if state == "complete" { return }
            if state == "interactive" {
                interactiveSince = interactiveSince ?? Date()
                if Date().timeIntervalSince(interactiveSince!) > 8 { return }
            }
            if Date().timeIntervalSince(start) > 40 { throw Failure.timeout }
        }
    }

    /// Scrolls the page viewport by viewport and draws each screenshot at its exact offset.
    /// Fixed and sticky elements are hidden after the first viewport so they appear once.
    /// In `strict` mode returns nil when the layout moved during the pass (caller retries).
    private func snapshotTiles(height: CGFloat, scale wanted: CGFloat, strict: Bool) async throws -> (CGImage, CGFloat)? {
        let width = webView.bounds.width
        let scale = min(wanted, sqrt(Self.maxPixels / (width * height)))
        let w = Int(width * scale), h = Int(height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw Failure.empty }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high

        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = true
        _ = try? await webView.evaluateJavaScript(Self.showFixedScript)
        _ = try? await webView.evaluateJavaScript(Self.hideConsentScript)
        var y: CGFloat = 0
        var first = true
        var layout: String?
        while y < height {
            try checkCancelled()
            let now = try? await webView.evaluateJavaScript(Self.layoutFingerprintScript) as? String
            if layout == nil { layout = now }
            if strict, now != layout {
                if ProcessInfo.processInfo.environment["PSE_DEBUG"] != nil {
                    let a = (layout ?? "").split(separator: ":").first ?? "", b = (now ?? "").split(separator: ":").first ?? ""
                    FileHandle.standardError.write("layout moved at y=\(Int(y)): height \(a) -> \(b)\n".data(using: .utf8)!)
                    let old = (layout ?? "").split(separator: ":").last?.split(separator: ",") ?? []
                    let new = (now ?? "").split(separator: ":").last?.split(separator: ",") ?? []
                    let moved = zip(old, new).enumerated().filter { $0.element.0 != $0.element.1 }.prefix(6)
                    for (i, pair) in moved {
                        let desc = (try? await webView.evaluateJavaScript(
                            "(e => e.tagName + '.' + e.className + ' ' + (e.textContent||'').trim().slice(0,40))(window.__pseEls[\(i)])") as? String) ?? "?"
                        FileHandle.standardError.write("  #\(i) \(pair.0) -> \(pair.1): \(desc)\n".data(using: .utf8)!)
                    }
                }
                return nil
            }
            // 'instant' overrides CSS smooth scrolling; the position is read only after it settled
            // and checked again after the snapshot.
            _ = try? await webView.evaluateJavaScript(
                "document.documentElement.style.scrollBehavior = 'auto';"
                // No scroll anchoring: animated blocks above (typing terminals, tickers) must not
                // nudge the scroll position while we snapshot.
                + "document.documentElement.style.overflowAnchor = 'none'; document.body.style.overflowAnchor = 'none';"
                + "window.scrollTo({top: \(Int(y)), behavior: 'instant'}); true")
            try await Task.sleep(nanoseconds: 350_000_000) // let scroll-triggered animations settle
            let actual = try await scrollY()
            let shot = try await webView.takeSnapshot(configuration: config)
            let after = try await scrollY()
            if strict, after != actual {
                if ProcessInfo.processInfo.environment["PSE_DEBUG"] != nil {
                    FileHandle.standardError.write("scroll moved during snapshot at y=\(Int(y)): \(actual) -> \(after)\n".data(using: .utf8)!)
                }
                return nil
            }
            guard let cg = shot.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw Failure.empty }
            // CG origin is bottom-left: a tile at page offset `actual` sits (height - actual - viewport) up.
            let tile = CGRect(x: 0, y: (height - actual - viewportHeight) * scale,
                              width: width * scale, height: viewportHeight * scale)
            ctx.draw(cg, in: tile)
            if first {
                first = false
                _ = try? await webView.evaluateJavaScript(Self.hideFixedScript)
            }
            if actual + viewportHeight >= height { break }
            y = actual + viewportHeight
        }
        guard let image = ctx.makeImage() else { throw Failure.empty }
        return (image, scale)
    }

    /// Page height plus the page positions of the first images, headings and blocks.
    private static let layoutFingerprintScript = """
        (() => {
            // Sticky/fixed elements legitimately move while scrolling: leave them out.
            const pinned = e => { for (; e && e !== document.body; e = e.parentElement) {
                const p = getComputedStyle(e).position; if (p === 'fixed' || p === 'sticky') return true; } return false; };
            if (!window.__pseEls) window.__pseEls = Array.from(document.querySelectorAll('img, h1, h2, h3, article, section'))
                .filter(e => !pinned(e)).slice(0, 120);
            const els = window.__pseEls;
            // Layout position (offsetTop chain): ignores transforms, so reveal animations that slide
            // content in don't count as a layout change. Invisible elements are skipped.
            const top = e => { let y = 0; for (; e; e = e.offsetParent) y += e.offsetTop; return y; };
            const tops = els.map(e => e.offsetWidth && e.offsetHeight ? top(e) : 'x');
            return document.documentElement.scrollHeight + ':' + tops.join(',');
        })()
        """

    private static let hideFixedScript = """
        for (const el of document.querySelectorAll('body *')) {
            const p = getComputedStyle(el).position;
            if ((p === 'fixed' || p === 'sticky') && !el.hasAttribute('data-pse-hidden')) {
                el.setAttribute('data-pse-hidden', el.style.visibility || '');
                el.style.setProperty('visibility', 'hidden', 'important');
            }
        }
        true
        """

    /// Cookie / consent banners: fixed elements whose id or class says so are hidden everywhere,
    /// including the first viewport.
    private static let hideConsentScript = """
        for (const el of document.querySelectorAll('body *')) {
            if (getComputedStyle(el).position !== 'fixed') continue;
            const name = (el.id + ' ' + (typeof el.className === 'string' ? el.className : '')).toLowerCase();
            if (/cookie|consent|gdpr|\\bcmp\\b/.test(name)) el.style.setProperty('display', 'none', 'important');
        }
        true
        """

    /// Undoes hideFixedScript before a new pass, so the header is in the first viewport again.
    private static let showFixedScript = """
        for (const el of document.querySelectorAll('[data-pse-hidden]')) {
            el.style.visibility = el.getAttribute('data-pse-hidden');
            el.removeAttribute('data-pse-hidden');
        }
        true
        """

    /// Diagnostics: animation frames per second, libraries and hidden content on the page.
    func probe(_ url: URL) async -> String {
        try? await waitForLoad(url)
        var out: [String] = []
        func js(_ code: String) async -> String {
            do { return "\(try await webView.evaluateJavaScript(code) ?? "nil")" } catch { return "ERR \(error.localizedDescription)" }
        }
        out.append("url: " + (await js("location.href")))
        out.append("visibility: " + (await js("document.visibilityState + ' hidden=' + document.hidden")))
        _ = await js("window.__raf = 0; (function f(){ window.__raf++; requestAnimationFrame(f); })(); window.__t = 0; setInterval(() => window.__t++, 100); true")
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        out.append("rAF/s: " + (await js("window.__raf")) + ", timers/s: " + (await js("window.__t")))
        out.append("libs: " + (await js("JSON.stringify({gsap: !!window.gsap, st: !!window.ScrollTrigger, lenis: !!(window.lenis || window.Lenis)})")))
        out.append("opacity0: " + (await js("Array.from(document.querySelectorAll('section, h2, p')).filter(e => getComputedStyle(e).opacity === '0').length + ' of ' + document.querySelectorAll('section, h2, p').length")))
        out.append("fixed: " + (await js("Array.from(document.querySelectorAll('body *')).filter(e => ['fixed','sticky'].includes(getComputedStyle(e).position)).map(e => e.tagName + '.' + e.className).slice(0,5).join(' | ')")))
        out.append("scroller: " + (await js("JSON.stringify({docH: document.documentElement.scrollHeight, bodyH: document.body.scrollHeight, htmlOverflow: getComputedStyle(document.documentElement).overflow, bodyOverflow: getComputedStyle(document.body).overflow, winH: innerHeight})")))
        return out.joined(separator: "\n")
    }

    private func checkCancelled() throws {
        if cancelled { throw CancellationError() }
    }

    /// Loads lazy images (scrolls through once), waits for pending images and fonts, back to top.
    private static let preparePageScript = """
        document.querySelectorAll('img[loading="lazy"]').forEach(i => { i.loading = 'eager'; });
        const sleep = ms => new Promise(r => setTimeout(r, ms));
        const step = Math.max(200, window.innerHeight * 0.8);
        const limit = 30000;
        for (let y = 0; y < Math.min(document.documentElement.scrollHeight, limit); y += step) {
            window.scrollTo(0, y);
            await sleep(120);
        }
        window.scrollTo(0, document.documentElement.scrollHeight);
        await sleep(400);
        const pending = Array.from(document.images).filter(i => !i.complete)
            .map(i => new Promise(r => { i.onload = i.onerror = r; }));
        await Promise.race([Promise.all(pending), sleep(4000)]);
        if (document.fonts) { await Promise.race([document.fonts.ready, sleep(2000)]); }
        window.scrollTo(0, 0);
        await sleep(600);
        """

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishLoad(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishLoad(.failure(Failure.load(error.localizedDescription)))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishLoad(.failure(Failure.load(error.localizedDescription)))
    }

    private func finishLoad(_ result: Result<Void, Error>) {
        loadHandler?(result)
    }
}
