import AppKit
import ScreenCaptureKit

extension NSScreen {
    var displayID: CGDirectDisplayID {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
    }
}

/// Grabs a full-resolution image of every display using ScreenCaptureKit.
enum ScreenGrabber {
    static func captureAllDisplays(completion: @escaping ([CGDirectDisplayID: CGImage]) -> Void) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, _ in
            guard let content else {
                DispatchQueue.main.async { completion([:]) }
                return
            }
            let group = DispatchGroup()
            let lock = NSLock()
            var images: [CGDirectDisplayID: CGImage] = [:]

            for display in content.displays {
                let scale = NSScreen.screens.first { $0.displayID == display.displayID }?.backingScaleFactor ?? 2
                let config = SCStreamConfiguration()
                config.width = Int(CGFloat(display.width) * scale)
                config.height = Int(CGFloat(display.height) * scale)
                config.showsCursor = false
                config.captureResolution = .best
                let filter = SCContentFilter(display: display, excludingWindows: [])

                group.enter()
                SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, _ in
                    if let image {
                        lock.lock()
                        images[display.displayID] = image
                        lock.unlock()
                    }
                    group.leave()
                }
            }
            group.notify(queue: .main) { completion(images) }
        }
    }
}
