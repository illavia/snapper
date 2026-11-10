import AppKit

extension CGImage {
    /// An image read from a file is decoded lazily, from the file. If the file is then rewritten
    /// (which saving an edit does), the image silently turns into the new contents. This makes a
    /// copy that lives in memory and no longer depends on the file.
    func inMemoryCopy() -> CGImage {
        let space = colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return self
        }
        context.interpolationQuality = .none
        context.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? self
    }
}

/// Keeps what is needed to reopen an edited capture with its marks still editable:
/// the untouched original and the list of marks. The PNG in the save folder stays a normal,
/// flattened image; this lives beside it in Application Support.
enum EditStore {
    struct Saved {
        let original: CGImage
        let scale: CGFloat
        let annotations: [Annotation]
        let crop: CGRect?
    }

    private struct State: Codable {
        var path: String
        var scale: Double
        var savedAt: Double
        var crop: [Double]?
        var marks: [Mark]
    }

    private struct Mark: Codable {
        var kind: String
        var sx: Double, sy: Double, ex: Double, ey: Double
        var r: Double, g: Double, b: Double, a: Double
        var text: String
        var number: Int
    }

    private static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Snapper/Edits", isDirectory: true)
    }

    private static func folder(for file: URL) -> URL {
        // A stable hash of the full path keeps two files with the same name apart.
        var hash: UInt64 = 5381
        for byte in file.standardizedFileURL.path.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        let name = file.deletingPathExtension().lastPathComponent
        return root.appendingPathComponent("\(name)-\(String(hash, radix: 16))", isDirectory: true)
    }

    private static func modified(_ file: URL) -> Double? {
        (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)?
            .timeIntervalSince1970
    }

    /// Call after the flattened PNG has been written to `file`.
    static func save(file: URL, original: CGImage, writeOriginal: Bool, scale: CGFloat,
                     annotations: [Annotation], crop: CGRect?) {
        let folder = folder(for: file)
        if annotations.isEmpty, crop == nil {
            // Nothing to remember: the file is the original.
            try? FileManager.default.removeItem(at: folder)
            return
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let originalURL = folder.appendingPathComponent("original.png")
            if writeOriginal || !FileManager.default.fileExists(atPath: originalURL.path) {
                guard let png = Shot(image: original, scale: scale)?.png else { return }
                try png.write(to: originalURL, options: .atomic)
            }
            let marks = annotations.map { mark -> Mark in
                let c = mark.color.usingColorSpace(.sRGB) ?? .systemRed
                return Mark(kind: name(of: mark.kind), sx: mark.start.x, sy: mark.start.y, ex: mark.end.x, ey: mark.end.y,
                            r: c.redComponent, g: c.greenComponent, b: c.blueComponent, a: c.alphaComponent,
                            text: mark.text, number: mark.number)
            }
            let state = State(path: file.path, scale: Double(scale), savedAt: modified(file) ?? 0,
                              crop: crop.map { [$0.minX, $0.minY, $0.width, $0.height] }, marks: marks)
            try JSONEncoder().encode(state).write(to: folder.appendingPathComponent("state.json"), options: .atomic)
        } catch {
            Log.write("editor: could not store edit data: \(error.localizedDescription)")
        }
    }

    /// Returns the editable version, or nil if there is none or the PNG was changed by something else since.
    static func load(file: URL) -> Saved? {
        let folder = folder(for: file)
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("state.json")),
              let state = try? JSONDecoder().decode(State.self, from: data),
              let fileTime = modified(file), abs(fileTime - state.savedAt) < 2,
              let source = CGImageSourceCreateWithURL(folder.appendingPathComponent("original.png") as CFURL, nil),
              let original = CGImageSourceCreateImageAtIndex(source, 0, nil)?.inMemoryCopy() else { return nil }
        let annotations = state.marks.compactMap { mark -> Annotation? in
            guard let kind = kind(named: mark.kind) else { return nil }
            return Annotation(kind: kind, start: CGPoint(x: mark.sx, y: mark.sy), end: CGPoint(x: mark.ex, y: mark.ey),
                              color: NSColor(srgbRed: mark.r, green: mark.g, blue: mark.b, alpha: mark.a),
                              text: mark.text, number: mark.number)
        }
        let crop = state.crop.flatMap { $0.count == 4 ? CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) : nil }
        return Saved(original: original, scale: CGFloat(state.scale), annotations: annotations, crop: crop)
    }

    static func remove(for file: URL) {
        try? FileManager.default.removeItem(at: folder(for: file))
    }

    /// Drops stored edits whose capture file no longer exists.
    static func prune() {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for folder in folders {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("state.json")),
                  let state = try? JSONDecoder().decode(State.self, from: data) else { continue }
            if !FileManager.default.fileExists(atPath: state.path) { try? FileManager.default.removeItem(at: folder) }
        }
    }

    private static func name(of kind: Annotation.Kind) -> String {
        switch kind {
        case .arrow: return "arrow"
        case .box: return "box"
        case .text: return "text"
        case .highlight: return "highlight"
        case .step: return "step"
        case .blur: return "blur"
        }
    }

    private static func kind(named name: String) -> Annotation.Kind? {
        switch name {
        case "arrow": return .arrow
        case "box": return .box
        case "text": return .text
        case "highlight": return .highlight
        case "step": return .step
        case "blur": return .blur
        default: return nil
        }
    }
}
