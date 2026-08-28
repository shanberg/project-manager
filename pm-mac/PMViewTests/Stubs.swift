import AppKit
import PmLib

// The app-only names the views under test reach for, stubbed so those views can be compiled and
// driven on their own.
//
// Structural, not behavioural. Everything being tested here is the view's — which keys it swallows,
// where it puts the caret, what the layout manager does to a bracket — and none of it depends on what
// these do. A stub that grew an opinion would be a stub the tests were quietly about.
//
// The alternative was a test target hosted by PM.app itself, which would need no stubs and would also
// launch the real app: `applicationDidFinishLaunching` opens windows, reads the projects folder, and
// can trip a TCC prompt. A view test should not be able to touch somebody's notes.

enum Log { static func write(_ s: String) {} }

/// Codes shown, which is the app's default.
enum ProjectCodes {
    static var areShown: Bool { true }
    static func display(_ full: String, short: String? = nil, showing: Bool = true) -> String {
        showing ? full : (short ?? full)
    }
}

func afterCurrentUpdate(_ work: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async { MainActor.assumeIsolated(work) }
}

enum NoteImagePasteboard {
    static let imageTypes: [NSPasteboard.PasteboardType] = []
    static func imageFiles(on: NSPasteboard) -> [URL]? { nil }
    static func imageData(on: NSPasteboard) -> (data: Data, ext: String)? { nil }
}

/// A fixed vault: one project per shape a mention has to handle — two that share a first letter so
/// arrowing has somewhere to go, an archived one, and an area, which carries no code at all.
@MainActor
final class ProjectIndex {
    static let shared = ProjectIndex()
    var mentionCandidates: [MentionCandidate] = [
        MentionCandidate(name: "W-1 Website Refresh", shortName: "Website Refresh",
                         code: "W-1", kind: .project, isArchived: false),
        MentionCandidate(name: "W-3 Vendor Contract", shortName: "Vendor Contract",
                         code: "W-3", kind: .project, isArchived: false),
        MentionCandidate(name: "H-2 Kitchen", shortName: "Kitchen", code: "H-2",
                         kind: .project, isArchived: true),
        MentionCandidate(name: "Team 1:1s", shortName: "Team 1:1s", code: "",
                         kind: .area, isArchived: false),
    ]
}
