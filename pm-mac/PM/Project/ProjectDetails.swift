import AppKit
import PmLib
import SwiftUI

/// The project's brief — summary, problem, goals, approach, links, learnings — read as a printed page
/// and edited in place.
///
/// **Not private, because a project card shows one too.** The board is a surface you work on, and the
/// brief is part of the notes rather than part of the window.
struct ProjectDetailsView: View {
    let notes: ProjectNotes?
    var store: PMStore
    @Binding var isEditing: Bool
    /// Whether an empty brief draws its six "Add summary…" prompts, or nothing at all.
    ///
    /// The window shows them: the details band is a section you deliberately revealed, so it owes you
    /// an answer to "what can go in here", and it needs a target for the double-click. A card is not
    /// revealed — it is the project, sitting on a board beside five others — and a project with no
    /// brief would otherwise lead with six lines of empty prompts above the work. There, an empty brief
    /// is simply not drawn, and Edit Details on the card's menu is the way in.
    var showsPlaceholders = true
    /// Where the brief's text starts and ends. A card sets it under the title's words, past the
    /// progress pie, so the title and its brief read as one block.
    var leadingInset: CGFloat = 12
    var trailingInset: CGFloat = 12

    var body: some View {
        // Nothing at all, rather than an empty band. Without placeholders there is no content, but the
        // padding and the double-click target below would still be there — an invisible strip across
        // the top of every project card, swallowing the clicks that land in it.
        if let n = notes, isEditing || showsPlaceholders || hasAnyDetail(n) {
            Group {
                if isEditing {
                    // One field at a time, onto freshly-parsed notes, leaving the title, the sessions
                    // and every *other* field untouched. Writing the whole block on every commit would
                    // make an edit to the summary overwrite a goal somebody had just changed in another
                    // window — which the old form could not do only because it wrote once, at the end.
                    DetailsEditor(notes: n, kind: store.kind) { edited, field in
                        store.saveDetails { fresh in
                            var out = fresh
                            switch field {
                            case .summary: out.summary = edited.summary
                            case .problem: out.problem = edited.problem
                            case .goals: out.goals = edited.goals
                            case .approach: out.approach = edited.approach
                            case .links: out.links = edited.links
                            case .learnings: out.learnings = edited.learnings
                            }
                            return out
                        }
                    }
                    .reportEditorFrame()
                } else {
                    Group {
                        if hasAnyDetail(n) {
                            readContent(n)
                        } else if showsPlaceholders {
                            placeholderContent
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, leadingInset)
            .padding(.trailing, trailingInset)
            .padding(.top, 2)
            .padding(.bottom, 12)
            // Double-click anywhere in the details band switches to edit mode — including the empty
            // placeholders, so a project with no details yet can gain them right here.
            //
            // The whole band, padding and all, rather than just the content it wraps: the window's
            // blank space carries a double-click of its own (add a task), so a target that stopped at
            // the text's edge would hand clicks in the details' own margins to the task list.
            .ifCondition(!isEditing) { view in
                view.contentShape(Rectangle())
                    .onTapGesture(count: 2) { isEditing = true }
            }
        }
    }

    /// True when any detail block would render. When false (and not editing), the section shows empty
    /// placeholders instead of nothing, so a project with no details can still be given them here.
    private func hasAnyDetail(_ n: ProjectNotes) -> Bool {
        !n.summary.isBlank || !n.problem.isBlank
            || n.goals.contains { !$0.isBlank }
            || !n.approach.isBlank
            || n.links.contains { ($0.label ?? "").isEmpty == false || ($0.url ?? "").isEmpty == false }
            || n.learnings.contains { !$0.isBlank }
    }

    /// The empty state: one quiet placeholder per editable section, so opening details on a project
    /// with none reveals what a brief can hold and gives the double-click-to-edit gesture a target.
    private var placeholderContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(["Summary", "Problem", "Goals", "Approach", "Links", "Learnings"], id: \.self) { title in
                VStack(alignment: .leading, spacing: 4) {
                    BriefLabel(title)
                    Text("Add \(title.lowercased())…")
                        .font(Self.bodyFont)
                        .foregroundStyle(.quaternary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // A typographic treatment: the details read like a printed project brief — a serif lead
    // paragraph for the summary, uppercase tracked "eyebrow" labels, and serif body copy — so the
    // persistent project content is visually a different medium from the sans-serif task UI below.

    /// Serif reading face for detail body copy, distinguishing document content from the task UI.
    private static let bodyFont = Font.system(size: 13, design: .serif)

    private func readContent(_ n: ProjectNotes) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // The summary is the lede: no label, it opens the brief. In the secondary colour and not
            // much larger than the copy under it — the title above is what is large now, and this is
            // the line of notes Things keeps under a project's name.
            if !n.summary.isBlank {
                Text(n.summary)
                    .font(.system(size: 14, design: .serif))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            proseBlock("Problem", n.problem)
            numberedBlock("Goals", n.goals)
            proseBlock("Approach", n.approach)
            LinksBlock(links: n.links) { from, to in
                // Onto the notes as they are on disk, like every other field here — the order is the
                // lines' order, so this is the one write a reorder is.
                store.saveDetails { fresh in
                    var out = fresh
                    out.links = fresh.links.movingLink(from: from, to: to)
                    return out
                }
            }
            bulletBlock("Learnings", n.learnings)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func proseBlock(_ title: String, _ body: String) -> some View {
        if !body.isBlank {
            VStack(alignment: .leading, spacing: 4) {
                BriefLabel(title)
                Text(body)
                    .font(Self.bodyFont)
                    .foregroundStyle(.secondary)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func numberedBlock(_ title: String, _ items: [String]) -> some View {
        let nonEmpty = items.enumerated().filter { !$0.element.isBlank }
        if !nonEmpty.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                BriefLabel(title)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(nonEmpty, id: \.offset) { idx, item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            // Hanging figure: numerals in a fixed-width gutter so the copy aligns.
                            Text("\(idx + 1)")
                                .font(.system(size: 12, weight: .semibold, design: .serif))
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                                .frame(width: 14, alignment: .trailing)
                            Text(item)
                                .font(Self.bodyFont)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func bulletBlock(_ title: String, _ items: [String]) -> some View {
        let nonEmpty = items.filter { !$0.isBlank }
        if !nonEmpty.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                BriefLabel(title)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(nonEmpty, id: \.self) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("—").font(Self.bodyFont).foregroundStyle(.tertiary)
                            Text(item)
                                .font(Self.bodyFont)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}

/// A section label in the brief — Goals, Links — and anywhere on a card that wants a sub-heading
/// quieter than a sitting's: Projects, Picked up, Still open.
///
/// Sentence case, a touch heavier than the text around it, in the secondary colour: Craft's quiet
/// heading. It used to be tracked capitals at ten points, a magazine's eyebrow, which read as louder
/// than it was meant to at the size it was drawn and as a different publication from the tasks below.
struct BriefLabel: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.secondary)
    }
}

/// The editable detail fields, gathered on Save. Title and sessions are intentionally left out — the
/// store re-merges these onto freshly-parsed notes so they're preserved untouched. Links are edited
/// here as a flat label/URL list; any nested link groups are preserved verbatim (see `DetailsEditor`).
private struct EditedDetails {
    var summary: String
    var problem: String
    var goals: [String]
    var approach: String
    var links: [LinkEntry]
    var learnings: [String]
}

/// Which part of the brief a commit is about.
///
/// A commit names its field so the write can touch that one and no other — see `ProjectDetailsView`.
enum DetailField { case summary, problem, goals, approach, links, learnings }

/// One editable link row (label + URL). Backed by a stable `id` so add/remove keep field focus and
/// SwiftUI diffs the list correctly; converted to/from `LinkEntry` at the editor's edges.
private struct EditableLink: Identifiable {
    let id = UUID()
    var label: String
    var url: String
}

/// Inline editing for the project-details section. Shows every editable section (Summary, Problem,
/// Goals×3, Approach, Links, Learnings) regardless of whether it currently has content.
///
/// **Live rows, and no Cancel.** This was a form: seeded into `@State`, written once by a Save button,
/// with a Cancel beside it that made the whole sitting a no-op — so an edit was lost if the pane closed
/// mid-sentence, which is not how the task rows behave, and that inconsistency is what made it read as
/// a bug. Now each field commits itself as you leave it, and the two buttons are gone.
///
/// Cancel had to go with them rather than survive as a convenience: a surface that both writes as you
/// type and offers to discard is lying about one of the two. What replaces it is what the rest of the
/// app already relies on — the notes file has undo behind it, and no other editing in this app is
/// modal. Escape and an outside click still leave; they just no longer throw anything away.
///
/// The card is what forced it. A brief can now sit on a board, in one pane of a tiled view you are
/// working across, and a modal form there is worse than a modal form in a window.
private struct DetailsEditor: View {
    /// Which header fields to offer. The read view already hides a blank section, so it needs no kind;
    /// the editor does, because offering a field is what puts content in it. An Area given a Problem
    /// box would get a Problem — the serializer keeps a section the kind omits precisely when it isn't
    /// empty, so the value would stick, and the one place it could have been refused is here.
    let kind: ProjectKind
    /// Called with the whole brief and the one field that changed, each time a field is left.
    let onCommit: (EditedDetails, DetailField) -> Void

    /// Which field the caret is in. Leaving one is what commits it, so this is the editor's clock.
    @FocusState private var focused: Focus?
    /// What was last written, so a field left untouched writes nothing at all. Without it, tabbing
    /// through the brief would put six identical entries on the undo stack.
    @State private var seed: EditedDetails

    /// A field the caret can be in. Finer-grained than `DetailField` because the three goals and each
    /// link's two halves are separate fields that commit as one part of the document.
    private enum Focus: Hashable {
        case summary, problem, approach, learnings
        case goal(Int)
        case linkLabel(UUID), linkURL(UUID)

        var part: DetailField {
            switch self {
            case .summary: return .summary
            case .problem: return .problem
            case .approach: return .approach
            case .learnings: return .learnings
            case .goal: return .goals
            case .linkLabel, .linkURL: return .links
            }
        }
    }

    @State private var summary: String
    @State private var problem: String
    @State private var goals: [String]        // exactly 3 slots
    @State private var approach: String
    @State private var links: [EditableLink]  // flat label/URL rows (grouped links preserved separately)
    @State private var learningsText: String  // one learning per line
    /// Nested link groups (a label with child URLs) aren't expressible in this compact flat form, so
    /// they're held aside verbatim and re-appended on save — the editor never destroys them.
    private let preservedGroups: [LinkEntry]

    init(notes: ProjectNotes, kind: ProjectKind,
         onCommit: @escaping (EditedDetails, DetailField) -> Void) {
        self.kind = kind
        self.onCommit = onCommit
        // Split the stored links: grouped entries are set aside; flat entries seed the editable rows
        // (dropping the empty placeholder entry the model carries when there are no real links).
        let groups = notes.links.filter { !($0.children ?? []).isEmpty }
        let seededLinks = notes.links
            .filter { ($0.children ?? []).isEmpty }
            .compactMap { entry -> EditableLink? in
                let label = (entry.label ?? "").trimmingCharacters(in: .whitespaces)
                let url = (entry.url ?? "").trimmingCharacters(in: .whitespaces)
                return (label.isEmpty && url.isEmpty) ? nil
                    : EditableLink(label: entry.label ?? "", url: entry.url ?? "")
            }
        self.preservedGroups = groups
        _links = State(initialValue: seededLinks)
        _summary = State(initialValue: notes.summary)
        _problem = State(initialValue: notes.problem)
        _goals = State(initialValue: Array((notes.goals + ["", "", ""]).prefix(3)))
        _approach = State(initialValue: notes.approach)
        let seededLearnings = notes.learnings
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: "\n")
        _learningsText = State(initialValue: seededLearnings)
        // The document as it stood when this opened, through the *same* normalisation a commit uses —
        // so the comparison is like for like. Built from `notes.links` rather than the raw list,
        // otherwise the first time a link field was left it would report a change that was only this
        // editor's own tidying, and write it.
        _seed = State(initialValue: Self.edited(
            summary: notes.summary,
            problem: notes.problem,
            goals: Array((notes.goals + ["", "", ""]).prefix(3)),
            approach: notes.approach,
            links: seededLinks, preserved: groups,
            learningsText: seededLearnings))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Walked rather than listed, so the form and the document agree by construction: what an
            // area is written with is exactly what it can be edited with.
            ForEach(kind.headerSections, id: \.self) { section in
                field(section.label) { headerField(section) }
            }
            field("Links") { linksEditor }
            field("Learnings") {
                TextField("One per line", text: $learningsText, axis: .vertical)
                    .lineLimit(2...8)
                    .focused($focused, equals: .learnings)
            }
        }
        .textFieldStyle(.roundedBorder)
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Leaving a field is what writes it — tab, click into the next one, click away entirely.
        .onChange(of: focused) { was, _ in if let was { commit(was.part) } }
        // And leaving the editor writes whichever field still had the caret. This is the case the form
        // lost outright: the pane closing, or the card being stepped out of, mid-sentence.
        .onDisappear { if let focused { commit(focused.part) } }
    }

    @ViewBuilder private func headerField(_ section: HeaderSection) -> some View {
        switch section {
        case .summary:
            TextField("", text: $summary, axis: .vertical).lineLimit(1...5)
                .focused($focused, equals: .summary)
        case .problem:
            TextField("", text: $problem, axis: .vertical).lineLimit(1...5)
                .focused($focused, equals: .problem)
        case .approach:
            TextField("", text: $approach, axis: .vertical).lineLimit(1...5)
                .focused($focused, equals: .approach)
        case .goals:
            VStack(alignment: .leading, spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    TextField("\(section.label.dropLast()) \(i + 1)", text: $goals[i])
                        .focused($focused, equals: .goal(i))
                }
            }
        }
    }

    /// The link rows plus an "Add link" affordance. A short Label field leads a wider URL field, with a
    /// trailing remove control per row — mirroring the Links read view's "label — url" shape.
    private var linksEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach($links) { $link in
                HStack(spacing: 4) {
                    TextField("Label", text: $link.label).frame(width: 90)
                        .focused($focused, equals: .linkLabel(link.id))
                    TextField("URL", text: $link.url)
                        .focused($focused, equals: .linkURL(link.id))
                    Button {
                        // Removing is a whole act rather than a field being left, so it writes itself.
                        // Nothing else would: the row it was about no longer exists to lose focus.
                        links.removeAll { $0.id == link.id }
                        commit(.links)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Remove link")
                }
            }
            Button {
                // No commit here: an empty row is not a link yet, and writing one would put a blank
                // entry in the document every time somebody clicked this and thought better of it.
                links.append(EditableLink(label: "", url: ""))
            } label: {
                Label("Add link", systemImage: "plus.circle").font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            BriefLabel(title)
            content()
        }
    }

    /// Write one field, if it actually changed.
    ///
    /// The guard is what makes leaving a field free: tabbing through the brief without typing puts
    /// nothing on the undo stack, and the same field left twice writes once.
    private func commit(_ part: DetailField) {
        let now = current()
        guard changed(part, from: seed, to: now) else { return }
        onCommit(now, part)
        seed = now
    }

    private func current() -> EditedDetails {
        Self.edited(summary: summary, problem: problem, goals: goals, approach: approach,
                    links: links, preserved: preservedGroups, learningsText: learningsText)
    }

    private func changed(_ part: DetailField, from was: EditedDetails, to now: EditedDetails) -> Bool {
        switch part {
        case .summary: return was.summary != now.summary
        case .problem: return was.problem != now.problem
        case .goals: return was.goals != now.goals
        case .approach: return was.approach != now.approach
        case .links: return was.links != now.links
        case .learnings: return was.learnings != now.learnings
        }
    }

    /// The editor's state as the document would hold it. Static and pure, so the seed taken at `init`
    /// and every later comparison come out of the same function rather than out of two that have to be
    /// kept agreeing.
    ///
    /// Blank link rows are dropped, each is normalised into a `LinkEntry`, and the preserved groups are
    /// re-appended. An empty result falls back to the model's single empty entry, which is what a
    /// linkless project holds.
    private static func edited(summary: String, problem: String, goals: [String], approach: String,
                               links: [EditableLink], preserved: [LinkEntry],
                               learningsText: String) -> EditedDetails {
        let learnings = learningsText
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let flatLinks: [LinkEntry] = links.compactMap { row in
            let label = row.label.trimmingCharacters(in: .whitespaces)
            let url = row.url.trimmingCharacters(in: .whitespaces)
            if label.isEmpty && url.isEmpty { return nil }
            return LinkEntry(label: label.isEmpty ? nil : label, url: url.isEmpty ? nil : url)
        }
        let merged = flatLinks + preserved
        return EditedDetails(summary: summary, problem: problem, goals: goals, approach: approach,
                             links: merged.isEmpty ? [LinkEntry()] : merged,
                             learnings: learnings.isEmpty ? [""] : learnings)
    }
}

private struct LinksBlock: View {
    let links: [LinkEntry]
    /// Move the `from`th link that can move to `to` — see `movableLinkSlots`. Drag-reordered on a board
    /// (canvas backlog 14), where the board reads each row's place through `reportsLinkRow`.
    var move: (Int, Int) -> Void = { _, _ in }
    @State private var listID = UUID()

    private var usable: [LinkEntry] { links.filter(isUsable) }

    private func isUsable(_ link: LinkEntry) -> Bool {
        (link.label ?? "").isEmpty == false || (link.url ?? "").isEmpty == false || !(link.children ?? []).isEmpty
    }

    var body: some View {
        if !usable.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                BriefLabel("Links")
                let slots = links.movableLinkSlots
                ForEach(Array(links.enumerated()).filter { isUsable($0.element) }, id: \.offset) { index, link in
                    if let children = link.children, !children.isEmpty {
                        linkGroup(link, children: children)
                    } else if let slot = slots.firstIndex(of: index) {
                        linkRow(link).reportsLinkRow(listID, slot: slot)
                    } else {
                        linkRow(link)
                    }
                }
            }
            .reordersLinks(listID, count: links.movableLinkSlots.count, move: move)
        }
    }

    /// A nested link group: its label as a quiet heading, then its child URLs as an indented list of
    /// clickable links. Editing groups is not supported in the app (they round-trip untouched).
    @ViewBuilder private func linkGroup(_ link: LinkEntry, children: [LinkEntry]) -> some View {
        let label = (link.label ?? "").trimmingCharacters(in: .whitespaces)
        VStack(alignment: .leading, spacing: 2) {
            if !label.isEmpty {
                Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            }
            ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                linkRow(child).padding(.leading, 10)
            }
        }
    }

    @ViewBuilder private func linkRow(_ link: LinkEntry) -> some View {
        let label = (link.label ?? "").trimmingCharacters(in: .whitespaces)
        let urlStr = (link.url ?? "").trimmingCharacters(in: .whitespaces)
        if isSafeURL(urlStr), let url = URL(string: urlStr) {
            // Show the label (or a tidied host if unlabeled) beside the site's favicon; the full URL
            // moves to the hover tooltip so the row stays compact.
            // The site's name trails the label, quietly, the way Craft's link blocks say where they go:
            // "Design file … figma.com". Only when there is a label — an unlabelled link *is* its host.
            let pretty = prettyURL(urlStr)
            let host = hostName(url)
            HStack(alignment: .center, spacing: 8) {
                FaviconView(host: url.host ?? pretty)
                // Plain, so the label is drawn in the text's own colour: a list of links in link blue
                // is a column of the one colour on the card, and the favicon already says "link".
                Link(destination: url) {
                    Text(label.isEmpty ? pretty : label)
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12.5))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
                Spacer(minLength: 6)
                if !label.isEmpty, let host {
                    Text(host)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 1)
            .help(urlStr)
            // The whole row, favicon included, is the link a board follows — see `CanvasLinkZones`.
            .reportsLinkZone(url)
        } else {
            let text = (!label.isEmpty && !urlStr.isEmpty) ? "\(label): \(urlStr)" : (label.isEmpty ? urlStr : label)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private func isSafeURL(_ s: String) -> Bool {
        let t = s.lowercased()
        return t.hasPrefix("http://") || t.hasPrefix("https://")
    }

    /// `www.figma.com` → `figma.com`: the name a site goes by.
    private func hostName(_ url: URL) -> String? {
        guard var host = url.host, !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    private func prettyURL(_ s: String) -> String {
        var out = s
        for scheme in ["https://", "http://"] where out.lowercased().hasPrefix(scheme) {
            out = String(out.dropFirst(scheme.count)); break
        }
        if out.hasSuffix("/") { out = String(out.dropLast()) }
        return out
    }
}

/// A site favicon for a link row: the fetched icon once it arrives, and a quiet globe glyph while it
/// loads or when the site has none. Sized to sit inline with the 12pt label.
private struct FaviconView: View {
    let host: String
    @State private var image: NSImage?

    var body: some View {
        // On a small tile, as Craft sets a link's icon: a favicon is drawn for a browser tab, and loose
        // on the page some are a white square and some are nothing at all. The tile gives every one of
        // them the same footprint and the globe somewhere to sit.
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
                    .frame(width: 13, height: 13)
            } else {
                Image(systemName: "globe").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .frame(width: 20, height: 20)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.06)))
        .task(id: host) { image = await FaviconLoader.shared.favicon(for: host) }
    }
}