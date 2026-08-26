import Foundation

// MARK: - The two kinds of thing PM tracks
//
// A project accumulates toward a finish line. An area accumulates forever — a standing
// responsibility, a relationship you keep, a meeting that recurs. That single difference is where
// every other one comes from: a project draws a number because it arrives in a sequence and ends,
// it frames itself with a Problem and an Approach because it's aimed at something, and it's
// archived when it gets there.
//
// Those differences are small in count and scattered in reach — naming, scaffolding, which header
// sections a document is written with, what the menu item is called. Left as `if kind == .area` at
// each site, the only way to know how the two kinds differ is to walk the code and collect the
// branches, and the answer goes stale the moment someone adds a sixth one.
//
// So they live here, as data, and everything downstream reads a property rather than deciding for
// itself. The invariant that keeps that true: **a comparison against a specific kind belongs in
// this file and nowhere else.** A difference that can't be phrased as a property of the kind is the
// signal to add a property, not to branch at the call site.
//
// One thing deliberately does *not* consult the kind: reading. `parseNotes` takes whatever sections
// a document actually contains and always has, so a hand-edited file is read the same way no matter
// what wrote it. Only writing and presenting need to know. See docs/areas.md.

/// A project or an area — what a folder under one of the PARA roots is.
public enum ProjectKind: String, Codable, Sendable, CaseIterable {
    case project
    case area
}

/// The shape of a numbered project folder name: a domain code, a hyphen, a number, a space.
///
/// Deliberately not built from the configured domain codes. It is consulted by `projectTitle`, which
/// has a path and nothing else — no config, and no way to get one without turning a string transform
/// into an I/O call. The grammar identifies the prefix, not the particular letters.
let numberedProjectPrefix = try? NSRegularExpression(pattern: #"^[A-Za-z]+-\d+\s+"#)

/// The range of the `CODE-NNN ` prefix in a folder name, or nil when it doesn't carry one.
func numberedPrefixRange(in folderName: String) -> Range<String.Index>? {
    guard let regex = numberedProjectPrefix,
          let match = regex.firstMatch(in: folderName, range: NSRange(folderName.startIndex..., in: folderName))
    else { return nil }
    return Range(match.range, in: folderName)
}

public extension ProjectKind {
    /// Which kind a folder is, read off its name.
    ///
    /// The kind is **derived, never stored.** A numbered name is a project and an unnumbered one is an
    /// area, wherever the folder happens to sit — which is what makes the archive work without a
    /// marker file: both kinds go into the same `archive/`, and an archived folder still says which it
    /// is, because `W-12 Website Refresh` and `Team 1:1s` are not the same shape.
    ///
    /// A stored field would have to survive being moved in Finder, renamed in Obsidian, and restored
    /// from a backup, and would be wrong — silently — the first time it didn't. Folder names are
    /// already how PM identifies a project; this asks them one more question.
    ///
    /// The cost is that renaming a project's folder to drop its prefix turns it into an area. That is
    /// the same bargain every other name-derived fact here makes, and it is at least visible.
    static func of(folderName: String) -> ProjectKind {
        numberedPrefixRange(in: folderName) == nil ? .area : .project
    }

    /// Where a folder of this kind lives when it isn't archived — the scope unarchiving returns it to.
    var homeScope: ProjectScope {
        switch self {
        case .project: return .active
        case .area: return .areas
        }
    }

    /// The root directory its folders live under, unarchived.
    func root(in paths: ResolvedPaths) -> String {
        homeScope.path(in: paths)
    }

    /// The scaffold a new one is created with.
    func subfolders(in config: PmConfig) -> [String] {
        switch self {
        case .project: return config.subfolders
        case .area: return config.areaSubfolders ?? defaultAreaSubfolders
        }
    }
}

public extension ProjectKind {
    /// The header sections a document of this kind is written with, in document order.
    ///
    /// An area's set is a *subset* of a project's rather than a separate vocabulary: Summary means
    /// the same thing for both, and Goals reads as standing rather than terminal — the state being
    /// held, not the thing being driven at. Problem and Approach have no ongoing reading at all, so
    /// they're left out rather than reworded.
    var headerSections: [HeaderSection] {
        switch self {
        case .project: return [.summary, .problem, .goals, .approach]
        case .area: return [.summary, .goals]
        }
    }

    /// Whether names carry a `CODE-NNN ` prefix and draw a number from the shared sequence.
    var isNumbered: Bool { self == .project }

    /// The singular noun, for labels and commands ("New Area").
    var displayName: String {
        switch self {
        case .project: return "Project"
        case .area: return "Area"
        }
    }

    /// The plural, for list section headings and filters.
    var pluralDisplayName: String {
        switch self {
        case .project: return "Projects"
        case .area: return "Areas"
        }
    }

    /// What putting one away is called.
    ///
    /// Display vocabulary in the domain library is deliberate. The alternative is the app choosing
    /// the word, which is a comparison against a kind outside this file — exactly the thing the
    /// type exists to prevent. A project is finished and filed; an area is handed on or let go.
    var retireVerb: String {
        switch self {
        case .project: return "Archive"
        case .area: return "Put Down"
        }
    }
}

// MARK: - Header sections

/// How a section's content is shaped, and therefore how it is written and edited.
public enum SectionShape: Sendable {
    /// Free text, one callout body.
    case prose
    /// The fixed three numbered slots Goals has always had.
    case numberedList
}

/// One of the framing callouts above `## Links` in a notes document.
///
/// Each case carries its own callout type and label because that is what lets serialization walk a
/// kind's `headerSections` instead of writing four hardcoded blocks. The two `[!info]` sections are
/// told apart by their label, which is how the parser has always distinguished them.
public enum HeaderSection: String, Codable, Sendable, CaseIterable {
    case summary
    case problem
    case goals
    case approach

    /// The Obsidian callout type: the `summary` in `> [!summary] Summary`.
    public var calloutType: String {
        switch self {
        case .summary: return "summary"
        case .problem: return "question"
        case .goals, .approach: return "info"
        }
    }

    /// The heading text after the callout type.
    public var label: String {
        switch self {
        case .summary: return "Summary"
        case .problem: return "Problem"
        case .goals: return "Goals"
        case .approach: return "Approach"
        }
    }

    public var shape: SectionShape {
        self == .goals ? .numberedList : .prose
    }
}

/// A section's content, in whichever of the two shapes it has.
///
/// The point of the wrapper is that a caller can walk `kind.headerSections` and get each one's
/// content without knowing which field of `ProjectNotes` it came from — which is what turns
/// serialization from four hardcoded blocks into a loop.
public enum SectionContent: Equatable, Sendable {
    case prose(String)
    case numbered([String])
}

public extension ProjectNotes {
    /// What this document holds for a section.
    func content(_ section: HeaderSection) -> SectionContent {
        switch section {
        case .summary: return .prose(summary)
        case .problem: return .prose(problem)
        case .approach: return .prose(approach)
        case .goals: return .numbered(goals)
        }
    }

    /// Whether a section has anything in it.
    ///
    /// The write-side rule for a kind that omits a section is "emit it if the kind includes it *or*
    /// it isn't empty" — the second clause being what keeps omission from destroying a Problem
    /// somebody typed into an area by hand in Obsidian. This is that clause.
    func isEmpty(_ section: HeaderSection) -> Bool {
        switch content(section) {
        case .prose(let text): return text.trimmed.isEmpty
        case .numbered(let items): return items.allSatisfy { $0.trimmed.isEmpty }
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
