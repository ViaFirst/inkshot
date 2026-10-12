import AppKit
import ScreenCaptureKit

/// A frozen picture of one display, taken before the overlay appears.
struct DisplayShot {
    let displayID: CGDirectDisplayID
    let image: CGImage
    /// Display bounds in global CG coordinates (points, top-left origin).
    let frame: CGRect

    /// Image pixels per point.
    var scale: CGFloat { CGFloat(image.width) / frame.width }
}

enum ScreenGrabber {
    static func captureAllDisplays() async throws -> [DisplayShot] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let pid = ProcessInfo.processInfo.processIdentifier
        let ownApps = content.applications.filter { $0.processID == pid }

        var shots: [DisplayShot] = []
        for display in content.displays {
            let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            let config = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            config.width = Int(filter.contentRect.width * scale)
            config.height = Int(filter.contentRect.height * scale)
            config.showsCursor = false
            config.captureResolution = .best
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            shots.append(DisplayShot(displayID: display.displayID, image: image, frame: CGDisplayBounds(display.displayID)))
        }
        return shots
    }
}

enum WindowList {
    /// Frames of normal app windows, front to back, in global CG coordinates.
    static func frontToBack() -> [CGRect] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let pid = ProcessInfo.processInfo.processIdentifier
        return info.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? Int32) != pid,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width > 40, rect.height > 40 else { return nil }
            return rect
        }
    }
}
