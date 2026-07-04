import AppKit

extension CGEventFlags {
    var toNSEventModifiers: NSEvent.ModifierFlags {
        var flags = NSEvent.ModifierFlags()
        if contains(.maskCommand)   { flags.insert(.command) }
        if contains(.maskShift)     { flags.insert(.shift) }
        if contains(.maskControl)   { flags.insert(.control) }
        if contains(.maskAlternate) { flags.insert(.option) }
        return flags
    }
}
