import AppKit

/// A finished capture, encoded once and reused for clipboard and file.
struct Shot {
    let image: CGImage
    let scale: CGFloat
    let png: Data
    let tiff: Data?

    init?(image: CGImage, scale: CGFloat) {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        self.image = image
        self.scale = scale
        self.png = png
        self.tiff = rep.tiffRepresentation
    }

    var nsImage: NSImage {
        NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
    }
}

enum Clipboard {
    /// Writes the image, then reads it back. Returns false only if every attempt failed.
    @discardableResult
    static func copy(_ shot: Shot) -> Bool {
        let pasteboard = NSPasteboard.general
        for attempt in 1...3 {
            pasteboard.clearContents()
            var types: [NSPasteboard.PasteboardType] = [.png]
            if shot.tiff != nil { types.append(.tiff) }
            pasteboard.declareTypes(types, owner: nil)
            pasteboard.setData(shot.png, forType: .png)
            if let tiff = shot.tiff { pasteboard.setData(tiff, forType: .tiff) }
            if pasteboard.data(forType: .png)?.count == shot.png.count { return true }
            Log.write("clipboard write attempt \(attempt) did not read back")
            usleep(60_000)
        }
        return false
    }
}

enum FileStore {
    private static let folderKey = "saveFolder"

    static var folder: URL {
        get {
            if let path = UserDefaults.standard.string(forKey: folderKey) { return URL(fileURLWithPath: path) }
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Screenshots")
        }
        set { UserDefaults.standard.set(newValue.path, forKey: folderKey) }
    }

    static func save(_ shot: Shot) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let base = formatter.string(from: Date())
        var url = folder.appendingPathComponent("\(base).png")
        var n = 2
        while manager.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(n).png")
            n += 1
        }
        try shot.png.write(to: url, options: .atomic)
        return url
    }

    /// Newest first.
    static func recent(limit: Int) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                  options: [.skipsHiddenFiles])) ?? []
        return files
            .filter { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
            .map { ($0, (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { $0.0 }
    }
}
