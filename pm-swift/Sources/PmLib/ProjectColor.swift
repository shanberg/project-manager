import Foundation

/// A project's colour: one of the system's named colours, or any colour as hex.
///
/// In the notes file's frontmatter under `pm-color`, beside `pm-icon` and for the same reason — it has
/// to go wherever the folder goes (see `ProjectIcon`). Named colours are stored by name rather than as
/// the values they happen to have today, so they keep adapting to light and dark and to whatever the
/// system does to them next; a custom colour is the one case with nothing to adapt, and is hex.
///
/// PmLib only reads and writes the value. What a name looks like is the app's business.
public enum ProjectColor: Equatable, Hashable, Sendable {
    case named(Name)
    /// Six lowercase hex digits, no `#`.
    case custom(String)

    public enum Name: String, CaseIterable, Sendable {
        case red, orange, yellow, green, mint, teal, cyan, blue, indigo, purple, pink, brown
    }

    public static let frontmatterKey = "pm-color"

    /// Nil for empty or unrecognised. Names are matched without regard to case; hex takes `#rrggbb` or
    /// `rrggbb`. Surrounding quotes are dropped by the frontmatter reader.
    public init?(value: String) {
        let text = value.trimmingCharacters(in: .whitespaces).lowercased()
        if let name = Name(rawValue: text) {
            self = .named(name)
            return
        }
        let hex = text.hasPrefix("#") ? String(text.dropFirst()) : text
        guard hex.count == 6, hex.allSatisfy(\.isHexDigit) else { return nil }
        self = .custom(hex)
    }

    /// What's written after `pm-color:`. Hex is quoted, because an unquoted `#` starts a YAML comment
    /// and Obsidian would read the property as empty.
    public var value: String {
        switch self {
        case .named(let name): return name.rawValue
        case .custom(let hex): return "\"#\(hex)\""
        }
    }

    /// The custom colour's components, 0…1. Nil for a named colour.
    public var rgb: (red: Double, green: Double, blue: Double)? {
        guard case .custom(let hex) = self, let number = UInt32(hex, radix: 16) else { return nil }
        return (Double(number >> 16 & 0xff) / 255, Double(number >> 8 & 0xff) / 255, Double(number & 0xff) / 255)
    }

    /// A custom colour from components, 0…1, clamped.
    public static func custom(red: Double, green: Double, blue: Double) -> ProjectColor {
        func byte(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return .custom(String(format: "%02x%02x%02x", byte(red), byte(green), byte(blue)))
    }
}

/// The project's colour, read from a notes file's text.
public func projectColor(rawText: String) -> ProjectColor? {
    frontmatterValue(ProjectColor.frontmatterKey, in: rawText).flatMap(ProjectColor.init(value:))
}

/// Set or clear a project's colour, touching nothing in the file but the one frontmatter line.
public func setProjectColor(project: String, to color: ProjectColor?) throws {
    let handle = try resolveNotesHandle(project: project)
    let raw = try handle.io.readContent(path: handle.notesPath)
    let updated = settingFrontmatterValue(ProjectColor.frontmatterKey, to: color?.value, in: raw)
    guard updated != raw else { return }
    try handle.io.writeContent(path: handle.notesPath, content: updated)
}
