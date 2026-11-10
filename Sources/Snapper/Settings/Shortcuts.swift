import AppKit
import Carbon.HIToolbox

/// A key plus Carbon modifier flags.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let command = UInt32(cmdKey), shift = UInt32(shiftKey), option = UInt32(optionKey), control = UInt32(controlKey)

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(event: NSEvent) {
        var mods: UInt32 = 0
        let flags = event.modifierFlags
        if flags.contains(.command) { mods |= Self.command }
        if flags.contains(.shift) { mods |= Self.shift }
        if flags.contains(.option) { mods |= Self.option }
        if flags.contains(.control) { mods |= Self.control }
        self.init(keyCode: UInt32(event.keyCode), modifiers: mods)
    }

    var cocoaModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & Self.command != 0 { flags.insert(.command) }
        if modifiers & Self.shift != 0 { flags.insert(.shift) }
        if modifiers & Self.option != 0 { flags.insert(.option) }
        if modifiers & Self.control != 0 { flags.insert(.control) }
        return flags
    }

    /// For example "⌥⇧C" or "§".
    var display: String {
        var text = ""
        if modifiers & Self.control != 0 { text += "⌃" }
        if modifiers & Self.option != 0 { text += "⌥" }
        if modifiers & Self.shift != 0 { text += "⇧" }
        if modifiers & Self.command != 0 { text += "⌘" }
        return text + Self.keyName(keyCode)
    }

    /// The character to show as a menu key equivalent, if the key has one.
    var menuKey: String {
        if let index = Self.functionKeys.firstIndex(of: Int(keyCode)),
           let scalar = UnicodeScalar(NSF1FunctionKey + index) {
            return String(Character(scalar))
        }
        switch Int(keyCode) {
        case kVK_Return: return "\r"
        case kVK_Tab: return "\t"
        case kVK_Space: return " "
        case kVK_Delete: return "\u{8}"
        case kVK_Escape: return "\u{1B}"
        default: return Self.character(for: keyCode)?.lowercased() ?? ""
        }
    }

    // F1...F20, in order.
    static let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                               kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]

    /// Keys that do not type anything in normal use, so they are safe as a shortcut with nothing held.
    var isSafeAlone: Bool {
        Self.functionKeys.contains(Int(keyCode)) || Int(keyCode) == kVK_ISO_Section
    }

    static func keyName(_ keyCode: UInt32) -> String {
        if let index = functionKeys.firstIndex(of: Int(keyCode)) { return "F\(index + 1)" }
        switch Int(keyCode) {
        case kVK_ISO_Section: return "§"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Space: return "Space"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_Escape: return "⎋"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        default: return character(for: keyCode)?.uppercased() ?? "Key \(keyCode)"
        }
    }

    /// What the key types on the current keyboard layout with nothing held.
    static func character(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = unsafeBitCast(raw, to: CFData.self) as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        let text = String(utf16CodeUnits: chars, count: length).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

enum ShortcutAction: String, CaseIterable, Identifiable {
    case capture, captureAlt, fullScreen, scrolling, text, pin

    var id: String { rawValue }

    var title: String {
        switch self {
        case .capture: return "Capture Region or Window"
        case .captureAlt: return "Capture Region or Window (alternate)"
        case .fullScreen: return "Capture Full Screen"
        case .scrolling: return "Scrolling Capture"
        case .text: return "Grab Text"
        case .pin: return "Pin Region to Screen"
        }
    }

    var defaultShortcut: Shortcut? {
        let optionShift = Shortcut.option | Shortcut.shift
        switch self {
        case .capture: return Shortcut(keyCode: UInt32(kVK_ANSI_C), modifiers: optionShift)
        case .captureAlt: return nil
        case .fullScreen: return Shortcut(keyCode: UInt32(kVK_ANSI_F), modifiers: optionShift)
        case .scrolling: return Shortcut(keyCode: UInt32(kVK_ANSI_S), modifiers: optionShift)
        case .text: return Shortcut(keyCode: UInt32(kVK_ANSI_T), modifiers: optionShift)
        case .pin: return Shortcut(keyCode: UInt32(kVK_ANSI_P), modifiers: optionShift)
        }
    }

    fileprivate var hotKeyID: UInt32 { UInt32(20 + (Self.allCases.firstIndex(of: self) ?? 0)) }
}

/// Holds the user's shortcuts, saves them, and keeps the global hotkeys in step.
@MainActor
final class ShortcutStore: ObservableObject {
    static let shared = ShortcutStore()

    enum SetResult: Equatable {
        case ok
        case swapped(with: ShortcutAction)
        case rejected(String)
        case refused
    }

    @Published private(set) var shortcuts: [ShortcutAction: Shortcut] = [:]
    /// Actions whose shortcut macOS would not register.
    @Published private(set) var refused: Set<ShortcutAction> = []

    private var handlers: [ShortcutAction: () -> Void] = [:]
    private var suspended = false
    private let key = "shortcuts"

    private init() { load() }

    /// Stored as action name to shortcut; a cleared action is stored with keyCode UInt32.max.
    private func load() {
        var stored: [String: Shortcut] = [:]
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: Shortcut].self, from: data) { stored = decoded }
        var result: [ShortcutAction: Shortcut] = [:]
        for action in ShortcutAction.allCases {
            if let saved = stored[action.rawValue] {
                if saved.keyCode != UInt32.max { result[action] = saved }
            } else if let fallback = action.defaultShortcut {
                result[action] = fallback
            }
        }
        shortcuts = result
    }

    private func save() {
        var stored: [String: Shortcut] = [:]
        for action in ShortcutAction.allCases {
            stored[action.rawValue] = shortcuts[action] ?? Shortcut(keyCode: UInt32.max, modifiers: 0)
        }
        if let data = try? JSONEncoder().encode(stored) { UserDefaults.standard.set(data, forKey: key) }
        Log.write("shortcuts: " + ShortcutAction.allCases.map { "\($0.rawValue)=\(shortcuts[$0]?.display ?? "none")" }
            .joined(separator: ", "))
    }

    func setHandler(_ action: ShortcutAction, _ handler: @escaping () -> Void) { handlers[action] = handler }

    func registerAll() {
        guard !suspended else { return }
        var failed: Set<ShortcutAction> = []
        // Release every shortcut first. Registering one at a time fails when two actions trade keys,
        // because the second still holds the keys the first is asking for.
        for action in ShortcutAction.allCases { HotKeyCenter.shared.unregister(id: action.hotKeyID) }
        for action in ShortcutAction.allCases {
            guard let shortcut = shortcuts[action], let handler = handlers[action] else { continue }
            if !HotKeyCenter.shared.register(id: action.hotKeyID, keyCode: shortcut.keyCode,
                                             modifiers: shortcut.modifiers, handler: handler) {
                failed.insert(action)
            }
        }
        refused = failed
    }

    /// While a shortcut is being recorded the existing ones must not fire.
    func suspend() {
        suspended = true
        for action in ShortcutAction.allCases { HotKeyCenter.shared.unregister(id: action.hotKeyID) }
    }

    func resume() {
        suspended = false
        registerAll()
    }

    static func validate(_ shortcut: Shortcut) -> String? {
        let strong = Shortcut.command | Shortcut.option | Shortcut.control
        if shortcut.modifiers & strong == 0, !shortcut.isSafeAlone {
            return "Add Control, Option or Command. On its own this key would stop you typing it."
        }
        return nil
    }

    @discardableResult
    func set(_ action: ShortcutAction, to shortcut: Shortcut?) -> SetResult {
        guard let shortcut else {
            shortcuts[action] = nil
            save()
            registerAll()
            return .ok
        }
        if let problem = Self.validate(shortcut) { return .rejected(problem) }
        var result = SetResult.ok
        if let other = ShortcutAction.allCases.first(where: { $0 != action && shortcuts[$0] == shortcut }) {
            // Swap, so neither action is left without its keys.
            shortcuts[other] = shortcuts[action]
            result = .swapped(with: other)
        }
        shortcuts[action] = shortcut
        save()
        registerAll()
        if refused.contains(action) { return .refused }
        return result
    }

    func restoreDefaults() {
        UserDefaults.standard.removeObject(forKey: key)
        load()
        save()
        registerAll()
    }
}
