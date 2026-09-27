import AppKit

/// Clipboard and file output shared by the overlay and the editor.
enum Export {
    static func copy(_ image: NSImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    /// Writes a PNG into the Snips folder and also copies it. Returns the file URL.
    @discardableResult
    static func save(_ image: NSImage) -> URL? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let url = saveDirectory.appendingPathComponent("Snip \(formatter.string(from: Date())).png")
        do {
            try png.write(to: url)
        } catch {
            return nil
        }
        copy(image)
        return url
    }
}
