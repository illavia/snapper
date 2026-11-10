import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Snapper Settings"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let hosting = NSHostingController(rootView: SettingsView(store: ShortcutStore.shared))
        hosting.sizingOptions = [.preferredContentSize]
        window.contentViewController = hosting
        window.center()
        self.window = window
        DockPresence.windowOpened()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Make sure a half-finished recording never leaves the shortcuts switched off.
        ShortcutStore.shared.resume()
        window = nil
        DockPresence.windowClosed()
    }
}

private struct SettingsView: View {
    @ObservedObject var store: ShortcutStore
    @State private var notes: [ShortcutAction: String] = [:]
    @State private var folder = FileStore.folder
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("Shortcuts") {
                VStack(spacing: 0) {
                    ForEach(Array(ShortcutAction.allCases.enumerated()), id: \.element) { index, action in
                        if index > 0 { Divider() }
                        row(action)
                    }
                }
                HStack {
                    Text("Click a box, then press the keys. Delete clears it, Esc cancels.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore Defaults") {
                        store.restoreDefaults()
                        notes = [:]
                    }
                }
                .padding(.top, 8)
            }

            section("General") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Save captures to")
                        Text(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button("Change…") { chooseFolder() }
                }
                .padding(.vertical, 8)
                Divider()
                HStack {
                    Text("Launch Snapper at login")
                    Spacer()
                    Toggle("Launch Snapper at login", isOn: $launchAtLogin)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .onChange(of: launchAtLogin) { _, wanted in setLaunchAtLogin(wanted) }
                }
                .padding(.vertical, 8)
            }
        }
        .padding(22)
        .frame(width: 560)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 0) { content() }
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor)))
        }
    }

    private func row(_ action: ShortcutAction) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(action.title)
                Spacer()
                ShortcutRecorder(shortcut: store.shortcuts[action]) { new in
                    switch store.set(action, to: new) {
                    case .ok: notes[action] = nil
                    case .swapped(let other):
                        notes = [:]
                        notes[action] = "Those keys belonged to \(other.title), so the two were swapped."
                    case .rejected(let reason): notes[action] = reason
                    case .refused: notes[action] = "macOS would not accept those keys. Another app may own them."
                    }
                }
                .frame(width: 150, height: 26)
            }
            if let note = notes[action] ?? (store.refused.contains(action) ? "macOS would not accept those keys." : nil) {
                Text(note).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 7)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        panel.prompt = "Save Captures Here"
        if panel.runModal() == .OK, let url = panel.url {
            FileStore.folder = url
            folder = url
        }
    }

    private func setLaunchAtLogin(_ wanted: Bool) {
        do {
            if wanted { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.write("launch at login failed: \(error.localizedDescription)")
        }
        let actual = SMAppService.mainApp.status == .enabled
        if actual != launchAtLogin { launchAtLogin = actual }
    }
}

/// A box that shows a shortcut and records a new one when clicked.
private struct ShortcutRecorder: NSViewRepresentable {
    let shortcut: Shortcut?
    let onChange: (Shortcut?) -> Void

    func makeNSView(context: Context) -> RecorderField {
        let field = RecorderField()
        field.onChange = onChange
        return field
    }

    func updateNSView(_ field: RecorderField, context: Context) {
        field.shortcut = shortcut
        field.onChange = onChange
    }
}

final class RecorderField: NSView {
    var shortcut: Shortcut? { didSet { needsDisplay = true } }
    var onChange: ((Shortcut?) -> Void)?
    private(set) var isRecording = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Shortcut")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 26) }

    private var clearRect: NSRect { NSRect(x: bounds.maxX - 24, y: 0, width: 24, height: bounds.height) }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if shortcut != nil, !isRecording, clearRect.contains(point) {
            onChange?(nil)
            return
        }
        if isRecording { stop() } else { window?.makeFirstResponder(self) }
    }

    override func becomeFirstResponder() -> Bool {
        isRecording = true
        ShortcutStore.shared.suspend()
        return true
    }

    override func resignFirstResponder() -> Bool {
        if isRecording {
            isRecording = false
            ShortcutStore.shared.resume()
        }
        return true
    }

    private func stop() { window?.makeFirstResponder(nil) }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }
        let plain = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
        if plain, event.keyCode == 53 { stop(); return }                       // Esc cancels
        if plain, event.keyCode == 51 || event.keyCode == 117 {                // Delete clears
            stop()
            onChange?(nil)
            return
        }
        let recorded = Shortcut(event: event)
        stop()
        onChange?(recorded)
    }

    /// Command combinations arrive here rather than in keyDown.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.18) : NSColor.textBackgroundColor).setFill()
        box.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        box.lineWidth = isRecording ? 2 : 1
        box.stroke()

        let text: String
        let colour: NSColor
        if isRecording { text = "Press keys…"; colour = .controlAccentColor }
        else if let shortcut { text = shortcut.display; colour = .labelColor }
        else { text = "None"; colour = .tertiaryLabelColor }
        let label = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: isRecording ? .regular : .medium), .foregroundColor: colour,
        ])
        let size = label.size()
        label.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))

        if shortcut != nil, !isRecording {
            let cross = NSAttributedString(string: "✕", attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor,
            ])
            let crossSize = cross.size()
            cross.draw(at: NSPoint(x: clearRect.midX - crossSize.width / 2, y: bounds.midY - crossSize.height / 2))
        }
    }
}
