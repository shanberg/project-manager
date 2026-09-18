import AppKit
import PmLib
import SwiftUI

// MARK: - The model

/// The portfolio a Projects card draws, kept current while the card is up (docs/views.md D1, step 7).
///
/// **Its own scan**, `project.list` with its activity, as every view reads the contract's answer rather
/// than the app's index. Polled once a minute: a project goes quiet over weeks, not seconds.
@MainActor
@Observable
final class CanvasProjectsModel {
    private(set) var projects: [ProjectSummary]?
    private(set) var failure: String?
    /// The same answer as markdown, for Copy as Text (D10).
    private(set) var text: String?

    var spec: CanvasViewSpec { didSet { if spec != oldValue { reload() } } }
    var boardProjects: [String] = [] {
        didSet { if boardProjects != oldValue, spec.projects == .board { reload() } }
    }
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let queue = DispatchQueue(label: "com.stuarthanberg.pm.projectsview", qos: .utility)
    @ObservationIgnored private var generation = 0

    static let interval: TimeInterval = 60

    init(spec: CanvasViewSpec) {
        self.spec = spec
    }

    /// A model holding an answer already in hand, which never looks: for drawing the card in a test.
    init(spec: CanvasViewSpec, showing projects: [ProjectSummary]) {
        self.spec = spec
        self.projects = projects
    }

    func start() {
        reload()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        timer.tolerance = Self.interval / 4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    var summary: String { projects.map { CanvasProjectRows.summary($0) } ?? "" }

    func reload() {
        generation += 1
        let mine = generation
        let projects: [String]?
        switch spec.projects {
        case .everything: projects = nil
        case .board: projects = boardProjects
        case .named(let names): projects = names
        }
        queue.async { [weak self] in
            let result = Result { () throws -> [ProjectSummary] in
                if projects?.isEmpty == true { return [] }
                // Everything is what's in hand, projects and areas; one named is read wherever it is.
                return try projectSummaries(scopes: projects == nil ? [.active, .areas] : ProjectScope.allCases,
                                            projects: projects)
            }
            Task { @MainActor in
                guard let self, mine == self.generation else { return }
                switch result {
                case .success(let summaries):
                    self.failure = nil
                    if summaries != self.projects { self.projects = summaries }
                    self.text = ViewMarkdown.projects(summaries)
                case .failure(let error):
                    self.failure = String(describing: error)
                }
                self.onChange?()
            }
        }
    }
}

// MARK: - The card

/// A Projects card: every project, those worked on in the last two weeks first and the ones gone quiet
/// after, each with when it was last touched, what's open and what's next due. Its rows are projects, not
/// tasks — a click goes there, and a drag makes the project's card.
struct CanvasProjectsCard: View {
    let model: CanvasProjectsModel
    var zoom: Double = 1
    var onOpenProject: (String) -> Void = { _ in }
    /// The card a row dragged off this one makes. Nil: rows don't drag.
    var projectCard: ((ProjectSummary) -> NSItemProvider?)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Projects")
                    .font(.system(size: 13 * zoom, weight: .semibold))
                Spacer(minLength: 4)
                Text(model.projects?.isEmpty == false ? model.summary : "")
                    .font(.system(size: 11 * zoom))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if model.spec.projects != .everything {
                Text(model.spec.projects.title)
                    .font(.system(size: 11 * zoom))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    @ViewBuilder private var content: some View {
        if let failure = model.failure, model.projects == nil {
            quiet(failure)
        } else if let projects = model.projects {
            if projects.isEmpty {
                quiet(model.spec.projects == .board && model.boardProjects.isEmpty
                      ? "No project cards on this board." : "No projects.")
            } else {
                let (moving, quiet) = ViewMarkdown.split(projects)
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !moving.isEmpty { section("Moving", moving, isQuiet: false) }
                        if !quiet.isEmpty { section("Quiet", quiet, isQuiet: true) }
                    }
                    .padding(.vertical, 6)
                }
            }
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func quiet(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12 * zoom))
            .foregroundStyle(.tertiary)
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func section(_ title: String, _ projects: [ProjectSummary], isQuiet: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11 * zoom, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            ForEach(projects, id: \.path) { project in row(project, isQuiet: isQuiet) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func row(_ project: ProjectSummary, isQuiet: Bool) -> some View {
        Button { onOpenProject(project.folder) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                CanvasProjectMark(color: project.projectColor, icon: project.projectIcon, zoom: zoom)
                VStack(alignment: .leading, spacing: 1) {
                    Text(project.name)
                        .font(.system(size: 12.5 * zoom))
                        .foregroundStyle(isQuiet ? .secondary : .primary)
                        .lineLimit(1)
                    Text(CanvasProjectRows.detail(project))
                        .font(.system(size: 10.5 * zoom))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(CanvasProjectRows.lastWorked(project))
                    .font(.system(size: 10.5 * zoom))
                    .foregroundStyle(isQuiet ? .tertiary : .secondary)
                    .fixedSize()
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(project.lastSittingLede.map { "Last sitting: \($0)" } ?? "Go to \(project.name)")
        .ifCondition(projectCard != nil) { view in view.onDrag { projectCard?(project) ?? NSItemProvider() } }
        .contextMenu {
            Button { onOpenProject(project.folder) } label: {
                Label("Go to \(project.name)", systemImage: "arrow.turn.down.right")
            }
            Button { TaskPasteboard.copy(markdown: "[[\(project.folder)]]") } label: {
                Label("Copy Link", systemImage: "link")
            }
        }
    }
}
