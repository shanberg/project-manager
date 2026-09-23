import Foundation

/// A project's texture: a 1-bit pattern feathered into the top-left of its window, drawn in its colour.
///
/// A second thing to tell projects apart by, beside `ProjectColor` and independent of it — the colour is
/// what a glance catches, the texture is what's still there with the colour taken away. One of the
/// built-in patterns, or an image the app dithers down to one bit and tiles.
///
/// In the notes file's frontmatter under `pm-texture`, for the same reason as `pm-icon` and `pm-color`:
/// it has to go wherever the folder goes. An image is named by a path relative to the notes file, and
/// the app copies a chosen image into the `attachments/` folder beside it, so the reference survives a
/// rename and opens in Obsidian too.
///
/// PmLib only reads and writes the value. What a pattern looks like is the app's business.
public enum ProjectTexture: Equatable, Hashable, Sendable {
    case named(Name)
    /// Relative to the folder the notes file is in, e.g. `attachments/Linen.png`.
    case image(String)

    public enum Name: String, CaseIterable, Sendable {
        case dither, checker, stipple, dots, hatch, cross, grid, bricks, weave, scales, waves, shingle
    }

    public static let frontmatterKey = "pm-texture"

    /// Nil for empty or unrecognised. Names are matched without regard to case; anything else counts as
    /// an image when it's a relative path to an image file. Surrounding quotes are dropped by the
    /// frontmatter reader.
    public init?(value: String) {
        let text = value.trimmingCharacters(in: .whitespaces)
        if let name = Name(rawValue: text.lowercased()) {
            self = .named(name)
            return
        }
        // Relative only: an absolute path is true on one Mac, and the point of the notes file is that it
        // travels. A quote can't be written back out inside the quoted value, so it isn't read either.
        guard !text.isEmpty, !text.hasPrefix("/"), !text.hasPrefix("~"), !text.contains("\""),
              isMarkdownImagePath(text) else { return nil }
        self = .image(text)
    }

    /// What's written after `pm-texture:`. A path is quoted, since a file name can hold anything YAML
    /// would read as something else — a `#`, a `: `.
    public var value: String {
        switch self {
        case .named(let name): return name.rawValue
        case .image(let path): return "\"\(path)\""
        }
    }

    /// Where an image texture is on disk, for a notes file at `notesPath`. Nil for a named one.
    public func imageURL(notesPath: String) -> URL? {
        guard case .image(let path) = self else { return nil }
        return URL(fileURLWithPath: notesPath).deletingLastPathComponent()
            .appendingPathComponent(path).standardizedFileURL
    }
}

/// How a texture is laid on: how far it reaches, how strong it is, how big its pixels are, and — for an
/// image — how big its tile is.
///
/// Each in a frontmatter line of its own beside `pm-texture`, written only when it differs from the
/// default — so a project that took the defaults carries one line, and a later change to a default
/// reaches it. A number out of range is clamped; a value that can't be read is the default.
public struct ProjectTextureStyle: Equatable, Hashable, Sendable {
    /// How far the fall-off reaches from the corner — a length the app sizes to the window, not a
    /// measurement, so a texture set on a wide screen is still there in a small panel.
    public enum Reach: String, CaseIterable, Sendable {
        case short, medium, long
    }

    public var reach: Reach
    /// The ink's strength at the corner, as a percentage.
    public var strength: Int
    /// A pattern cell, in points.
    public var pixel: Int
    /// An image texture's tile: how many cells its long side is brought down to before it's dithered.
    /// Ignored for a built-in pattern, which is always 8.
    public var tile: Int

    public static let strengthRange = 2...40
    public static let pixelRange = 1...3
    public static let tileRange = 16...192
    public static let standard = ProjectTextureStyle(reach: .medium, strength: 15, pixel: 2, tile: 96)

    public static let reachKey = "pm-texture-reach"
    public static let strengthKey = "pm-texture-strength"
    public static let pixelKey = "pm-texture-pixel"
    public static let tileKey = "pm-texture-tile"

    public init(reach: Reach, strength: Int, pixel: Int, tile: Int = 96) {
        self.reach = reach
        self.strength = min(max(strength, Self.strengthRange.lowerBound), Self.strengthRange.upperBound)
        self.pixel = min(max(pixel, Self.pixelRange.lowerBound), Self.pixelRange.upperBound)
        self.tile = min(max(tile, Self.tileRange.lowerBound), Self.tileRange.upperBound)
    }
}

extension ProjectTextureStyle.Reach {
    /// A name, or — as reach was first written — a percentage of the window, read as the nearest name.
    public init?(value: String) {
        let text = value.trimmingCharacters(in: .whitespaces).lowercased()
        if let reach = Self(rawValue: text) {
            self = reach
        } else if let percent = Int(text) {
            self = percent < 40 ? .short : percent < 70 ? .medium : .long
        } else {
            return nil
        }
    }
}

/// The project's texture, read from a notes file's text.
public func projectTexture(rawText: String) -> ProjectTexture? {
    frontmatterValue(ProjectTexture.frontmatterKey, in: rawText).flatMap(ProjectTexture.init(value:))
}

/// How the project's texture is laid on, read from a notes file's text: the defaults for anything unset.
public func projectTextureStyle(rawText: String) -> ProjectTextureStyle {
    let standard = ProjectTextureStyle.standard
    func number(_ key: String, _ fallback: Int) -> Int {
        frontmatterValue(key, in: rawText).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? fallback
    }
    return ProjectTextureStyle(
        reach: frontmatterValue(ProjectTextureStyle.reachKey, in: rawText)
            .flatMap(ProjectTextureStyle.Reach.init(value:)) ?? standard.reach,
        strength: number(ProjectTextureStyle.strengthKey, standard.strength),
        pixel: number(ProjectTextureStyle.pixelKey, standard.pixel),
        tile: number(ProjectTextureStyle.tileKey, standard.tile))
}

/// A notes file's text with its texture set or cleared. Clearing the texture clears its style too, a
/// style value equal to the default is left out, and the tile size is only written for an image.
public func settingProjectTexture(_ texture: ProjectTexture?, style: ProjectTextureStyle = .standard,
                                  in rawText: String) -> String {
    let standard = ProjectTextureStyle.standard
    func line<Value: Equatable>(_ value: Value, _ fallback: Value, _ text: String) -> String? {
        texture == nil || value == fallback ? nil : text
    }
    var isImage = false
    if case .image = texture { isImage = true }
    var text = settingFrontmatterValue(ProjectTexture.frontmatterKey, to: texture?.value, in: rawText)
    text = settingFrontmatterValue(ProjectTextureStyle.reachKey,
                                   to: line(style.reach, standard.reach, style.reach.rawValue), in: text)
    text = settingFrontmatterValue(ProjectTextureStyle.strengthKey,
                                   to: line(style.strength, standard.strength, String(style.strength)), in: text)
    text = settingFrontmatterValue(ProjectTextureStyle.pixelKey,
                                   to: line(style.pixel, standard.pixel, String(style.pixel)), in: text)
    text = settingFrontmatterValue(ProjectTextureStyle.tileKey,
                                   to: isImage ? line(style.tile, standard.tile, String(style.tile)) : nil, in: text)
    return text
}

/// Set or clear a project's texture and its style, touching nothing in the file but those lines.
public func setProjectTexture(project: String, to texture: ProjectTexture?,
                              style: ProjectTextureStyle = .standard) throws {
    let handle = try resolveNotesHandle(project: project)
    let raw = try handle.io.readContent(path: handle.notesPath)
    let updated = settingProjectTexture(texture, style: style, in: raw)
    guard updated != raw else { return }
    try handle.io.writeContent(path: handle.notesPath, content: updated)
}
