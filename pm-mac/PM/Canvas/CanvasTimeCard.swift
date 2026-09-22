import AppKit
import PmLib
import SwiftUI

// MARK: - The model

/// The report a Time card draws (docs/time-tracking.md D7, docs/views.md D1): how long each project had
/// your attention over a period, and what came of it.
///
/// **Its own query**, `time.spent`, as every view reads the contract's answer rather than the app's
/// own arithmetic. Polled on the same cadence as the Day card, since it is answering about the same
/// stretch of the same day — and the open span grows while you sit there.
@MainActor
@Observable
final class CanvasTimeModel {
    private(set) var report: TimeSpentReport?
    private(set) var range: DoneRange?
    private(set) var failure: String?
    /// The same answer as markdown, for Copy as Text (views.md D10).
    private(set) var text: String?

    var spec: CanvasViewSpec { didSet { if spec != oldValue { reload() } } }
    var boardProjects: [String] = [] {
        didSet { if boardProjects != oldValue, spec.projects == .board { reload() } }
    }
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let queue = DispatchQueue(label: "com.stuarthanberg.pm.timeview", qos: .utility)
    @ObservationIgnored private var generation = 0

    /// How often the card looks again. The Day card's, for the same reason: the span you are in now is
    /// still running, and a card that said 40m an hour ago is wrong rather than stale.
    static let interval: TimeInterval = 20

    init(spec: CanvasViewSpec) {
        self.spec = spec
    }

    /// A model holding an answer already in hand, which never looks: for drawing the card in a test.
    init(spec: CanvasViewSpec, showing report: TimeSpentReport, for range: DoneRange) {
        self.spec = spec
        self.report = report
        self.range = range
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

    var summary: String { report.map(CanvasTimeRows.summary) ?? "" }

    func reload() {
        generation += 1
        let mine = generation
        let spec = self.spec
        let projects: [String]?
        switch spec.projects {
        case .everything: projects = nil
        case .board: projects = boardProjects
        case .named(let names): projects = names
        }
        queue.async { [weak self] in
            let result = Result { () throws -> (DoneRange, TimeSpentReport) in
                let range = try spec.period.range()
                // An empty board asks about no projects, and the answer to that is nothing.
                if projects?.isEmpty == true { return (range, TimeSpentReport()) }
                return (range, try timeSpent(in: range, projects: projects))
            }
            Task { @MainActor in
                guard let self, mine == self.generation else { return }
                switch result {
                case .success(let (range, report)):
                    self.failure = nil
                    if range != self.range { self.range = range }
                    if report != self.report { self.report = report }
                    self.text = ViewMarkdown.time(report)
                case .failure(let error):
                    self.failure = String(describing: error)
                }
                self.onChange?()
            }
        }
    }
}

// MARK: - The card

/// A Time card: where the day (or the week) went, longest first, each project with how long it had your
/// attention and what came of it.
///
/// Its rows are projects, as the Projects card's are — a click goes there, a drag makes the project's
/// card. What it adds is the one thing no other card says: the cost.
///
/// **A bar, not a chart.** The rows are already sorted by length, so the bar is saying what the order
/// says, more quickly. Anything more — a pie, a stacked day, a rail scaled by duration — is the
/// timesheet views.md D5 refused, and it is refused here too.
struct CanvasTimeCard: View {
    let model: CanvasTimeModel
    var zoom: Double = 1
    var onOpenProject: (String) -> Void = { _ in }
    /// The card a row dragged off this one makes. Nil: rows don't drag.
    var projectCard: ((TimeSpentItem) -> NSItemProvider?)?

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
                // The card's name, not the period — the caption below already says which span, and
                // "Today" over "Today · Tue, Sep 22" was saying it twice.
                Text("Time")
                    .font(.system(size: 13 * zoom, weight: .semibold))
                Spacer(minLength: 4)
                Text(model.report == nil ? "" : model.summary)
                    .font(.system(size: 11 * zoom))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let range = model.range {
                Text(model.spec.caption(for: range))
                    .font(.system(size: 11 * zoom))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    @ViewBuilder private var content: some View {
        if let failure = model.failure, model.report == nil {
            quiet(failure)
        } else if let report = model.report {
            let (tracked, untracked) = CanvasTimeRows.split(report)
            if tracked.isEmpty, untracked.isEmpty {
                quiet(model.spec.projects == .board && model.boardProjects.isEmpty
                      ? "No project cards on this board." : "No time on record.")
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(tracked, id: \.projectFolder) { row($0, among: tracked) }
                        if !untracked.isEmpty { section(untracked) }
                    }
                    .padding(.horizontal, 12)
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

    /// The projects that were worked in without PM being told you were there.
    private func section(_ projects: [TimeSpentItem]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("No time on record")
                .font(.system(size: 11 * zoom, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 8)
                .padding(.bottom, 2)
            ForEach(projects, id: \.projectFolder) { row($0, among: []) }
        }
    }

    private func row(_ project: TimeSpentItem, among all: [TimeSpentItem]) -> some View {
        let share = CanvasTimeRows.share(project, of: all)
        return Button { onOpenProject(project.projectFolder) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    CanvasProjectMark(color: project.projectColor, icon: project.projectIcon, zoom: zoom)
                    Text(project.projectName)
                        .font(.system(size: 12.5 * zoom))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if project.seconds > 0 {
                        Text(durationLabel(project.seconds))
                            .font(.system(size: 12 * zoom, weight: .medium).monospacedDigit())
                            .fixedSize()
                    }
                }
                if share > 0 {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary)
                            Capsule()
                                .fill(CanvasCalendarCells.tint(project.projectColor))
                                .frame(width: max(2, geometry.size.width * share))
                        }
                    }
                    .frame(height: 3 * zoom)
                }
                let came = ViewMarkdown.changes(project)
                if !came.isEmpty || project.inferred {
                    HStack(spacing: 5) {
                        if !came.isEmpty {
                            Text(came)
                                .font(.system(size: 10.5 * zoom))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        // Beside the number it qualifies, never in a legend at the foot of the card
                        // (docs/time-tracking.md D4).
                        if project.inferred {
                            Text("inferred")
                                .font(.system(size: 9.5 * zoom))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 0.5)
                                .background(Capsule().fill(.quaternary))
                        }
                    }
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText(project))
        .ifCondition(projectCard != nil) { view in view.onDrag { projectCard?(project) ?? NSItemProvider() } }
        .contextMenu {
            Button { onOpenProject(project.projectFolder) } label: {
                Label("Go to \(project.projectName)", systemImage: "arrow.turn.down.right")
            }
            Button { TaskPasteboard.copy(markdown: "[[\(project.projectFolder)]]") } label: {
                Label("Copy Link", systemImage: "link")
            }
        }
    }

    /// What the row can say that it hasn't room for: how the time was made up, and how sure it is.
    private func helpText(_ project: TimeSpentItem) -> String {
        guard project.seconds > 0 else { return "Go to \(project.projectName)" }
        let spans = project.spans.count
        var text = "\(durationLabel(project.seconds)) over \(spans) span\(spans == 1 ? "" : "s")"
        if project.inferred {
            text += " — some of it worked out from what was written rather than recorded, so it may be over."
        }
        return text
    }
}
