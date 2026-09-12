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

// `isEnabled` is the real switch's shape and always off here: a test bundle is not a copy of PM
// somebody is chasing something in, and the one thing it gates — an inspectable web view —
// should not be opened by running the tests.
enum Log {
    static let isEnabled = false
    static func write(_ s: String) {}
}

/// Codes shown, which is the app's default.
enum ProjectCodes {
    static let didChange = Notification.Name("PMProjectCodesDidChange")
    static var areShown: Bool { true }
    static func display(_ full: String, short: String? = nil, showing: Bool = true) -> String {
        showing ? full : (short ?? full)
    }
}

/// The tab bar hangs one of these on a drag's item provider. The real one lives beside the task
/// column's drop code, which this bundle does not compile.
final class DragEndSentinel {
    init(onEnd: @escaping () -> Void) {}
}

func afterCurrentUpdate(_ work: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async { MainActor.assumeIsolated(work) }
}

/// A fixed vault: one project per shape a mention has to handle — two that share a first letter so
/// arrowing has somewhere to go, an archived one, and an area, which carries no code at all.
///
/// The folder-scan half of it is structural and empty, per the rule at the top of this file. `PMStore`
/// mirrors the index's three published streams and warms them on every load, so it cannot be compiled
/// without them — but nothing a store test asserts depends on what a scan of somebody's Documents
/// folder happens to return, and a stub that went looking would be a stub the tests were quietly
/// about. Warming is a no-op; the streams stay empty.
@MainActor
@Observable
final class ProjectIndex {
    static let shared = ProjectIndex()

    // MARK: The folder scan, structurally

    struct Recent: Identifiable, Equatable {
        let projectKey: String
        let name: String
        let done: Int
        let total: Int
        let nextDue: String?
        let summary: String?
        let focusedText: String?
        var id: String { projectKey }
        var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
    }

    struct ProjectEntry: Identifiable, Equatable {
        let name: String
        let projectKey: String
        let code: String
        let number: Int
        let shortName: String
        let domain: String
        let kind: ProjectKind
        let isArchived: Bool
        var id: String { projectKey }
    }

    struct WaitRoot: Equatable {
        let scope: ProjectScope
        let base: String
        let folders: [String]
    }

    private(set) var recents: [Recent] = []
    private(set) var allProjects: [ProjectEntry] = []
    private(set) var waitRoots: [WaitRoot] = []

    func warmRecents(force: Bool = false) {}
    func warmWaitRoots(force: Bool = false) {}
    func warmAllProjects(force: Bool = false) {}
    func retain() {}
    func release() {}

    // MARK: The mention fixture, which tests do depend on

    @ObservationIgnored
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
