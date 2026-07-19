import AppKit
import Carbon

struct KeyboardShortcut: Equatable, Hashable, Codable {
    var keyCode: UInt16
    var modifierFlags: UInt

    var modifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierFlags)
    }

    /// 移动窗口通过鼠标事件 flags 匹配，只支持“纯修饰键”组合。
    var isModifierOnlyShortcut: Bool {
        let allowed: NSEvent.ModifierFlags = [.command, .option, .shift, .control]
        return keyCode == .max && !modifiers.intersection(allowed).isEmpty
    }

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifierFlags = modifiers.rawValue
    }

    var displayString: String {
        var parts: [String] = []
        let mods = modifiers
        if mods.contains(.command) { parts.append("⌘") }
        if mods.contains(.option)  { parts.append("⌥") }
        if mods.contains(.shift)   { parts.append("⇧") }
        if mods.contains(.control) { parts.append("⌃") }

        // UInt16.max = 修饰键组合哨兵，不追加字母
        if keyCode != .max {
            if let special = specialKeyName {
                parts.append(special)
            } else if let char = safeKeyCharacter {
                parts.append(char.uppercased())
            }
        }
        return parts.joined()
    }

    private var specialKeyName: String? {
        switch Int(keyCode) {
        case 36:  return "↩"
        case 48:  return "⇥"
        case 49:  return "Space"
        case 51:  return "⌫"
        case 53:  return "⎋"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 122: return "F1"; case 120: return "F2"; case 99:  return "F3"
        case 118: return "F4"; case 96:  return "F5"; case 97:  return "F6"
        case 98:  return "F7"; case 100: return "F8"; case 101: return "F9"
        case 109: return "F10"; case 103: return "F11"; case 111: return "F12"
        default:  return nil
        }
    }

    private var safeKeyCharacter: String? {
        let mods = modifiers
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
        guard let layoutDataPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }

        let cfData = Unmanaged<CFData>.fromOpaque(layoutDataPtr).takeUnretainedValue()
        let data = cfData as Data
        guard data.count >= MemoryLayout<UCKeyboardLayout>.size else { return nil }

        return data.withUnsafeBytes { rawBuf -> String? in
            guard let layout = rawBuf.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var actualLen = 0
            let modifierState = mods.contains(.shift) ? UInt32(shiftKey) : 0

            let status = UCKeyTranslate(
                layout, keyCode, UInt16(kUCKeyActionDisplay),
                modifierState, UInt32(LMGetKbdType()),
                UInt32(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState, 4, &actualLen, &chars
            )
            guard status == noErr, actualLen > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: actualLen)
        }
    }

    static let empty = KeyboardShortcut(keyCode: 0, modifiers: [])
}
