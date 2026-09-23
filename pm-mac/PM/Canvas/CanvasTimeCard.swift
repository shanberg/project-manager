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
    /// The period's aways nobody has answered (docs/away-time.md), oldest first.
    private(set) var aways: [AttentionAway] = []
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
    init(spec: CanvasViewSpec, showing report: TimeSpentReport, aways: [AttentionAway] = [],
         for range: DoneRange) {
        self.spec = spec
        self.report = report
        self.aways = aways
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
            let result = Result { () throws -> (DoneRange, TimeSpentReport, [AttentionAway]) in
                let range = try spec.period.range()
                // An empty board asks about no projects, and the answer to that is nothing.
                if projects?.isEmpty == true { return (range, TimeSpentReport(), []) }
                return (range, try timeSpent(in: range, projects: projects),
                        try attentionAways(in: range, projects: projects))
            }
            Task { @MainActor in
                guard let self, mine == self.generation else { return }
                switch result {
                case .success(let (range, report, aways)):
                    self.failure = nil
                    if range != self.range { self.range = range }
                    if report != self.report { self.report = report }
                    if aways != self.aways { self.aways = aways }
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
    /// Answer for some stretches: they were this project's (a folder), or weren't work (nil).
    var onAnswer: ([CanvasTimeStretch], String?) -> Void = { _, _ in }

    /// The stretches picked, by `CanvasTimeStretch.key` — the aways, and the spans of any project
    /// that's open. Answers act on all of them at once (docs/away-time.md).
    @State private var selection = RowSelection()
    /// The projects showing the spans their time is made of.
    @State private var expanded: Set<String> = []

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
            if tracked.isEmpty, untracked.isEmpty, model.aways.isEmpty {
                quiet(model.spec.projects == .board && model.boardProjects.isEmpty
                      ? "No project cards on this board." : "No time on record.")
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(tracked, id: \.projectFolder) { project in
                            row(project, among: tracked)
                            if expanded.contains(project.projectFolder) {
                                ForEach(project.spans.map(CanvasTimeStretch.span), id: \.key) { span in
                                    stretchRow(span).padding(.leading, 18 * zoom)
                                }
                            }
                        }
                        if !model.aways.isEmpty { awaySection }
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
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            disclosure(project)
            projectButton(project, among: all)
        }
    }

    /// Opens a project row onto the spans its time is made of, which are what can be moved.
    @ViewBuilder private func disclosure(_ project: TimeSpentItem) -> some View {
        let open = expanded.contains(project.projectFolder)
        if project.spans.isEmpty {
            Color.clear.frame(width: 12 * zoom, height: 1)
        } else {
            Button {
                if open { expanded.remove(project.projectFolder) } else { expanded.insert(project.projectFolder) }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9 * zoom, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: 12 * zoom)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(open ? "Hide spans" : "Show spans")
        }
    }

    private func projectButton(_ project: TimeSpentItem, among all: [TimeSpentItem]) -> some View {
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
                if !came.isEmpty || project.inferred || project.counted {
                    HStack(spacing: 5) {
                        if !came.isEmpty {
                            Text(came)
                                .font(.system(size: 10.5 * zoom))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        // Beside the number it qualifies, never in a legend at the foot of the card
                        // (docs/time-tracking.md D4).
                        if project.inferred { mark("estimated") }
                        if project.counted { mark("counted") }
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

    /// How a number was arrived at, beside the number (docs/time-tracking.md D4).
    private func mark(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5 * zoom))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 4)
            .padding(.vertical, 0.5)
            .background(Capsule().fill(.quaternary))
    }

    // MARK: Stretches — aways and spans, answered for (docs/away-time.md)

    private var awaySection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Away")
                .font(.system(size: 11 * zoom, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 8)
                .padding(.bottom, 2)
            ForEach(model.aways.map(CanvasTimeStretch.away), id: \.key) { stretchRow($0) }
        }
    }

    /// Every stretch row in the order the card draws them — what a ⇧-click ranges over.
    private var stretches: [CanvasTimeStretch] {
        guard let report = model.report else { return [] }
        let spans = CanvasTimeRows.split(report).tracked
            .filter { expanded.contains($0.projectFolder) }
            .flatMap { $0.spans.map(CanvasTimeStretch.span) }
        return spans + model.aways.map(CanvasTimeStretch.away)
    }

    /// One stretch: when, and how long. An away also says what it interrupted; a span, how sure it is.
    private func stretchRow(_ stretch: CanvasTimeStretch) -> some View {
        let picked = selection.contains(stretch.key)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(timeLabel(stretch))
                .font(.system(size: 11.5 * zoom).monospacedDigit())
                .lineLimit(1)
            if case .away(let away) = stretch {
                Text(title(of: away.project))
                    .font(.system(size: 11 * zoom))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if case .span(let span) = stretch {
                if span.basis == .inferred { mark("estimated") }
                if span.basis == .counted { mark("counted") }
            }
            Text(durationLabel(stretch.seconds))
                .font(.system(size: 11 * zoom).monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 5).fill(picked ? Color.accentColor.opacity(0.18) : .clear))
        // The whole padded row takes the click, so it lands where the highlight is drawn.
        .contentShape(Rectangle())
        .onTapGesture {
            selection.click(stretch.key, modifiers: NSEvent.modifierFlags, in: stretches.map(\.key))
        }
        .contextMenu { answers(for: targets(of: stretch)) }
    }

    /// What a right-click acts on: the selection when the row is in it, the row alone when it isn't —
    /// the Finder's rule.
    private func targets(of stretch: CanvasTimeStretch) -> [CanvasTimeStretch] {
        guard selection.contains(stretch.key) else { return [stretch] }
        return stretches.filter { selection.contains($0.key) }
    }

    @ViewBuilder private func answers(for picked: [CanvasTimeStretch]) -> some View {
        let offered = CanvasTimeAnswers.offered(for: picked,
                                                candidates: model.report?.projects.map(\.projectFolder) ?? [])
        if let suggested = offered.suggested {
            Button(offered.countTitle(for: title(of: suggested))) { answer(picked, suggested) }
        }
        if !offered.projects.isEmpty {
            Menu(offered.countSubmenuTitle) {
                ForEach(offered.projects, id: \.self) { folder in
                    Button(title(of: folder)) { answer(picked, folder) }
                }
            }
        }
        Divider()
        Button(offered.notWorkTitle) { answer(picked, nil) }
    }

    private func answer(_ picked: [CanvasTimeStretch], _ project: String?) {
        selection = RowSelection()
        onAnswer(picked, project)
    }

    /// A project by title, never code — the one the report prints when it has it.
    private func title(of folder: String) -> String {
        model.report?.projects.first { $0.projectFolder == folder }?.projectName
            ?? projectTitle(fromFolderName: folder)
    }

    /// "12:05 – 12:35 PM", with the day as well on a card covering more than one.
    private func timeLabel(_ stretch: CanvasTimeStretch) -> String {
        guard let from = DoneLog.date(stretch.from), let to = DoneLog.date(stretch.to) else { return "" }
        let formatter = DateIntervalFormatter()
        formatter.timeStyle = .short
        let oneDay = model.range.map { $0.end.timeIntervalSince($0.start) <= 86_400 } ?? true
        formatter.dateStyle = oneDay ? .none : .short
        return formatter.string(from: from, to: to)
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
