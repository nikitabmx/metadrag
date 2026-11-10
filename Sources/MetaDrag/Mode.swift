import AppKit

/// Which ring the menu shows. Picked by the modifier key you press while dragging.
enum Mode: Int, CaseIterable, Identifiable, Hashable, Sendable {
    case convert, tools, share

    var id: Int { rawValue }
    var title: String { ["Convert", "Tools", "Share"][rawValue] }
    var glyph: String { ["⇧", "⌥", "⌘"][rawValue] }
    var keyName: String { ["Shift", "Option", "Command"][rawValue] }
    var flag: NSEvent.ModifierFlags { [.shift, .option, .command][rawValue] }
    var symbol: String { ["arrow.triangle.2.circlepath", "slider.horizontal.3", "square.and.arrow.up"][rawValue] }

    /// Mode for keys that just went down. ⌘ beats ⌥ beats ⇧ if they land in the same instant.
    static func pressed(_ flags: NSEvent.ModifierFlags) -> Mode? {
        if flags.contains(.command) { return .share }
        if flags.contains(.option) { return .tools }
        if flags.contains(.shift) { return .convert }
        return nil
    }

    static let triggerFlags: NSEvent.ModifierFlags = [.shift, .option, .command]
}
