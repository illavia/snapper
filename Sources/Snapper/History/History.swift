import AppKit
import SwiftUI

/// History is just the save folder, newest first, grouped by day. Nothing to maintain.
@MainActor
final class HistoryModel: ObservableObject {
    struct Day: Identifiable {
        let id: Date
        let title: String
        let files: [URL]
    }

    @Published var days: [Day] = []
    @Published var selected: URL?
    @Published var edited: Set<URL> = []
    /// Test hook: show every cell's hover button so it can be photographed.
    static var showButtonsForSnapshot = false

    func reload() {
        let files = FileStore.recent(limit: 300)
        let calendar = Calendar.current
        // Order by when the capture was taken, so editing an old one does not move it to the top.
        let dated = files.map { file -> (URL, Date) in
            let values = try? file.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            return (file, values?.creationDate ?? values?.contentModificationDate ?? .distantPast)
        }.sorted { $0.1 > $1.1 }
        var order: [Date] = []
        var groups: [Date: [URL]] = [:]
        for (file, date) in dated {
            let day = calendar.startOfDay(for: date)
            if groups[day] == nil { order.append(day) }
            groups[day, default: []].append(file)
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE d MMMM"
        days = order.sorted(by: >).map { day in
            let title: String
            if calendar.isDateInToday(day) { title = "Today" }
            else if calendar.isDateInYesterday(day) { title = "Yesterday" }
            else { title = formatter.string(from: day) }
            return Day(id: day, title: title, files: groups[day] ?? [])
        }
        edited = Set(files.filter { EditStore.hasEdits(for: $0) })
        if let selected, !files.contains(selected) { self.selected = nil }
    }
}

@MainActor
final class HistoryWindowController: NSObject, NSWindowDelegate, NSMenuItemValidation {
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Captures"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let hosting = NSHostingController(rootView: HistoryView(model: model))
        // Without this the hosting controller shrinks the window to the view's minimum size.
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.contentMinSize = NSSize(width: 520, height: 360)
        window.setContentSize(NSSize(width: 900, height: 640))
        window.center()
        self.window = window
        DockPresence.windowOpened()
        window.makeKeyAndOrderFront(nil)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == Selector(("printDocument:")) ? model.selected != nil : true
    }

    func reloadIfVisible() {
        if window?.isVisible == true { model.reload() }
    }

    func windowDidBecomeKey(_ notification: Notification) { model.reload() }

    /// File > Print (⌘P) prints the selected capture.
    @objc func printDocument(_ sender: Any?) {
        if let file = model.selected { Printer.print(file: file, window: window) }
    }

    func print(_ file: URL) { Printer.print(file: file, window: window) }

    func windowWillClose(_ notification: Notification) {
        window = nil
        DockPresence.windowClosed()
    }
}

private struct HistoryView: View {
    @ObservedObject var model: HistoryModel

    private let columns = [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 16)]

    var body: some View {
        Group {
            if model.days.isEmpty {
                VStack(spacing: 8) {
                    Text("No captures yet").font(.title3)
                    Text("Take one from the menu bar icon or with your capture shortcut.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        ForEach(model.days) { day in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(day.title).font(.headline)
                                    Text("\(day.files.count)").font(.subheadline).foregroundStyle(.secondary)
                                }
                                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                                    ForEach(day.files, id: \.self) { url in
                                        HistoryCell(url: url, model: model)
                                    }
                                }
                            }
                        }
                    }
                    .padding(20)
                }
                .safeAreaInset(edge: .bottom) {
                    Text("Click to select  ·  double-click to open  ·  drag out to use the file  ·  right-click for more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(.bar)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 360)
    }
}

private struct HistoryCell: View {
    let url: URL
    @ObservedObject var model: HistoryModel
    @State private var thumbnail: NSImage?
    @State private var hovering = false

    private var isSelected: Bool { model.selected == url }

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor))
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().scaledToFit().padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if model.edited.contains(url) {
                    Text("Edited")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor, in: Capsule())
                        .foregroundStyle(.white)
                        .padding(6)
                }
            }
            .frame(height: 140)
            .overlay(alignment: .topLeading) {
                // Top left, away from the Edited badge. The Trash keeps the file, so a slip can be put back.
                if hovering || HistoryModel.showButtonsForSnapshot {
                    Button(action: moveToTrash) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(Color.black.opacity(0.72), in: Circle())
                            .overlay(Circle().stroke(Color.white.opacity(0.6), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                    .help("Move to Trash")
                    .accessibilityLabel("Move to Trash")
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor : Color(nsColor: .separatorColor).opacity(hovering ? 1 : 0.6),
                            lineWidth: isSelected ? 3 : (hovering ? 2 : 1))
            )
            Text(Self.label(for: url))
                .font(.caption)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { EditorWindowController.open(file: url) }
        .simultaneousGesture(TapGesture().onEnded { model.selected = url })
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .contextMenu {
            Button("Open in Editor") { EditorWindowController.open(file: url) }
            Button("Copy") { copy() }
            Button("Print…") {
                model.selected = url
                HistoryWindowController.shared.print(url)
            }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Divider()
            Button("Move to Trash") { moveToTrash() }
        }
        .accessibilityLabel(Self.label(for: url))
        .task(id: url) { thumbnail = await Self.loadThumbnail(url) }
    }

    /// Timestamped captures show just the time, since the day is in the heading; named files keep their name.
    static func label(for url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        let parts = name.split(separator: " ")
        if parts.count >= 2, parts[0].count == 10, parts[0].filter({ $0 == "-" }).count == 2 {
            let time = parts[1].split(separator: ".")
            if time.count == 3 { return "\(time[0]):\(time[1]):\(time[2])" + (parts.count > 2 ? " (\(parts[2...].joined(separator: " ")))" : "") }
        }
        return name
    }

    private func moveToTrash() {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            EditStore.remove(for: url)
            Log.write("history: moved to Trash \(url.lastPathComponent)")
        } catch {
            Log.write("history: could not move to Trash \(url.lastPathComponent): \(error.localizedDescription)")
            Toast.show("Could not move to Trash", warn: true)
        }
        model.reload()
    }

    private func copy() {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let shot = Shot(image: image, scale: Self.scale(of: source)) else { return }
        let copied = Clipboard.copy(shot)
        Toast.show(copied ? "Copied to clipboard" : "Could not copy", warn: !copied)
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
