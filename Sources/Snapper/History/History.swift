import AppKit
import SwiftUI

/// History is just the save folder, newest first. Nothing to maintain.
@MainActor
final class HistoryModel: ObservableObject {
    @Published var files: [URL] = []

    func reload() { files = FileStore.recent(limit: 300) }
}

@MainActor
final class HistoryWindowController: NSObject, NSWindowDelegate {
    static let shared = HistoryWindowController()

    private var window: NSWindow?
    private let model = HistoryModel()

    func show() {
        model.reload()
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 600),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Captures"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: HistoryView(model: model))
        window.setContentSize(NSSize(width: 860, height: 600))
        window.center()
        self.window = window
        DockPresence.windowOpened()
        window.makeKeyAndOrderFront(nil)
    }

    func reloadIfVisible() {
        if window?.isVisible == true { model.reload() }
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        DockPresence.windowClosed()
    }
}

private struct HistoryView: View {
    @ObservedObject var model: HistoryModel

    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 14)]

    var body: some View {
        Group {
            if model.files.isEmpty {
                VStack(spacing: 8) {
                    Text("No captures yet").font(.title3)
                    Text("Press Shift-Option-C to take one.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(model.files, id: \.self) { url in
                            HistoryCell(url: url, model: model)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(minWidth: 480, idealWidth: 860, minHeight: 320, idealHeight: 600)
    }
}

private struct HistoryCell: View {
    let url: URL
    let model: HistoryModel
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor))
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().scaledToFit().padding(4)
                }
            }
            .frame(height: 130)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
            Text(url.deletingPathExtension().lastPathComponent)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { EditorWindowController.open(file: url) }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .contextMenu {
            Button("Open in Editor") { EditorWindowController.open(file: url) }
            Button("Copy") { copy() }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Divider()
            Button("Move to Trash") {
                try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
                model.reload()
            }
        }
        .help("Double-click to open. Right-click for more.")
        .task(id: url) { thumbnail = await Self.loadThumbnail(url) }
    }

    private func copy() {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let shot = Shot(image: image, scale: Self.scale(of: source)) else { return }
        Clipboard.copy(shot)
    }

    static func scale(of source: CGImageSource) -> CGFloat {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let dpi = (properties?[kCGImagePropertyDPIWidth] as? Double) ?? 72
        return dpi >= 140 ? 2 : 1
    }

    private static func loadThumbnail(_ url: URL) async -> NSImage? {
        await Task.detached(priority: .utility) { () -> NSImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 520,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return NSImage(cgImage: image, size: NSSize(width: image.width / 2, height: image.height / 2))
        }.value
    }
}
