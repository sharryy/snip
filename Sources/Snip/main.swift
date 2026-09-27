import AppKit
import Carbon

// MARK: - Settings (edit these)

/// Hotkeys. Key codes: X = 0x07, A = 0x00, 9 = 0x19. Modifiers: cmdKey, shiftKey, optionKey, controlKey.
/// ⌃⌘X: capture an area.   ⌃⌘A: capture the whole screen under the cursor.
let areaHotKey = (code: UInt32(kVK_ANSI_X), modifiers: UInt32(cmdKey | controlKey))
let screenHotKey = (code: UInt32(kVK_ANSI_A), modifiers: UInt32(cmdKey | controlKey))

/// Where "Save" puts PNG files.
let saveDirectory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Pictures/Snips")

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate!

    private var statusItem: NSStatusItem!
    private var overlays: [OverlayWindow] = []
    private var editors: [EditorWindow] = []
    private var hotKeyRefs: [EventHotKeyRef?] = [nil, nil]
    private var grabbing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        try? FileManager.default.createDirectory(at: saveDirectory, withIntermediateDirectories: true)
        setupStatusItem()
        registerHotKey()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "scissors", accessibilityDescription: "Snip")

        let menu = NSMenu()
        let area = NSMenuItem(title: "Capture Area", action: #selector(startCapture), keyEquivalent: "x")
        area.keyEquivalentModifierMask = [.command, .control]
        menu.addItem(area)
        let full = NSMenuItem(title: "Capture Screen", action: #selector(captureFullScreen), keyEquivalent: "a")
        full.keyEquivalentModifierMask = [.command, .control]
        menu.addItem(full)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Open Folder", action: #selector(openFolder), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Clear Storage…", action: #selector(clearSnips), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
        statusItem.menu = menu
    }

    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            DispatchQueue.main.async {
                if hotKeyID.id == 2 {
                    AppDelegate.shared.captureFullScreen()
                } else {
                    AppDelegate.shared.startCapture()
                }
            }
            return noErr
        }, 1, &spec, nil, nil)
        let signature = OSType(0x534E4950) // "SNIP"
        let areaStatus = RegisterEventHotKey(areaHotKey.code, areaHotKey.modifiers, EventHotKeyID(signature: signature, id: 1),
                                             GetApplicationEventTarget(), 0, &hotKeyRefs[0])
        let screenStatus = RegisterEventHotKey(screenHotKey.code, screenHotKey.modifiers, EventHotKeyID(signature: signature, id: 2),
                                               GetApplicationEventTarget(), 0, &hotKeyRefs[1])

        // macOS refuses a combo another app has already claimed; say so instead of failing silently.
        var taken: [String] = []
        if areaStatus != noErr { taken.append("⌃⌘X (capture area)") }
        if screenStatus != noErr { taken.append("⌃⌘A (capture screen)") }
        if !taken.isEmpty {
            DispatchQueue.main.async {
                self.showError("Hotkey already in use",
                               "Another app has claimed: \(taken.joined(separator: ", ")). Snip still works from the menu bar. Change the combo at the top of main.swift and rebuild.")
            }
        }
    }

    private func showError(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc func openFolder() {
        NSWorkspace.shared.open(saveDirectory)
    }

    /// Moves every file in the Snips folder to the Trash, after confirming.
    @objc func clearSnips() {
        let files = ((try? FileManager.default.contentsOfDirectory(at: saveDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        guard !files.isEmpty else {
            alert.messageText = "Nothing to clear"
            alert.informativeText = "The Snips folder is already empty."
            alert.runModal()
            return
        }
        alert.messageText = "Move \(files.count) snip\(files.count == 1 ? "" : "s") to the Trash?"
        alert.informativeText = "Everything in \(saveDirectory.path) will be moved to the Trash."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        NSWorkspace.shared.recycle(files) { _, error in
            if let error {
                let failed = NSAlert(error: error)
                failed.runModal()
            }
        }
    }

    /// Captures the whole display under the mouse cursor and opens it in the editor.
    @objc func captureFullScreen() {
        guard overlays.isEmpty, !grabbing else { return }
        guard ensureScreenRecordingPermission() else { return }
        grabbing = true
        ScreenGrabber.captureAllDisplays { [self] images in
            grabbing = false
            guard !images.isEmpty else {
                showPermissionHelp()
                return
            }
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.screens[0]
            guard let cgImage = images[screen.displayID] else { return }
            openEditor(with: cgImage, pointSize: screen.frame.size)
        }
    }

    private func openEditor(with cgImage: CGImage, pointSize: NSSize) {
        let editor = EditorWindow(image: image(from: cgImage, pointSize: pointSize))
        editor.onClose = { window in
            self.editors.removeAll { $0 === window }
        }
        editors.append(editor)
        editor.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Freezes the screen (grabs every display), then shows the selection overlay on top of it.
    @objc func startCapture() {
        guard overlays.isEmpty, !grabbing else { return }
        guard ensureScreenRecordingPermission() else { return }
        grabbing = true
        ScreenGrabber.captureAllDisplays { [self] images in
            grabbing = false
            guard !images.isEmpty else {
                showPermissionHelp()
                return
            }
            NSApp.activate(ignoringOtherApps: true)
            NSCursor.crosshair.push()
            overlays = NSScreen.screens.compactMap { screen in
                images[screen.displayID].map { OverlayWindow(screen: screen, image: $0) }
            }
            overlays.forEach { $0.orderFrontRegardless() }
            let mouse = NSEvent.mouseLocation
            (overlays.first { $0.frame.contains(mouse) } ?? overlays.first)?.makeKey()
        }
    }

    /// Called by the overlay when the user confirms a selection (or presses Esc, with nil rect).
    func overlayFinished(window: OverlayWindow?, localRect: NSRect?, action: OverlayAction = .edit) {
        NSCursor.pop()
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()

        guard let window, let localRect, localRect.width >= 2, localRect.height >= 2 else { return }

        // Crop the frozen screen image. Image pixels are top-down; the view's points are bottom-up.
        let scale = window.scale
        let source = window.screenImage
        let pixelRect = CGRect(x: localRect.minX * scale,
                               y: CGFloat(source.height) - localRect.maxY * scale,
                               width: localRect.width * scale,
                               height: localRect.height * scale).integral
        guard let cropped = source.cropping(to: pixelRect) else { return }
        let pointSize = NSSize(width: pixelRect.width / scale, height: pixelRect.height / scale)
        switch action {
        case .edit:
            openEditor(with: cropped, pointSize: pointSize)
        case .copy:
            Export.copy(image(from: cropped, pointSize: pointSize))
        case .save:
            Export.save(image(from: cropped, pointSize: pointSize))
        }
    }

    private func image(from cgImage: CGImage, pointSize: NSSize) -> NSImage {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = pointSize
        let image = NSImage(size: pointSize)
        image.addRepresentation(rep)
        return image
    }

    /// Returns true when Screen Recording is already granted. Otherwise triggers the system prompt
    /// (first time only) or explains how to enable it.
    private func ensureScreenRecordingPermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        // Shows the macOS "would like to record this computer's screen" prompt the first time.
        // Returns false either way until the app is relaunched with the permission granted.
        if !CGRequestScreenCaptureAccess() {
            showPermissionHelp()
        }
        return false
    }

    private func showPermissionHelp() {
        let alert = NSAlert()
        alert.messageText = "Snip needs Screen Recording access"
        alert.informativeText = "Turn on Snip under Screen & System Audio Recording, then quit and reopen Snip. macOS only applies this permission on the next launch."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Quit Snip")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        case .alertSecondButtonReturn:
            NSApp.terminate(nil)
        default:
            break
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
