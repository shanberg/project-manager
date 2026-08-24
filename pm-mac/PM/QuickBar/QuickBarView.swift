import PmLib
import SwiftUI

/// The quick bar: a field you type into, and the rows that answer.
///
/// One text field with the keyboard, always — the rows are never focusable. That's what lets ↑/↓ pick
/// a row while you keep typing, and it's why the selection is drawn here rather than left to a `List`,
/// which would want focus of its own to show one.
struct QuickBarView: View {
    @ObservedObject var model: QuickBarModel
    @AppStorage("PMPanelColorMode") private var colorMode: AppColorMode = .system
    @FocusState private var fieldFocused: Bool
    /// Measured content height, for the panel's auto-fit.
    var onContentHeight: (CGFloat) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            field
            if !model.rows.isEmpty {
                Divider()
                rowList
            }
            // Under the rows, never above them. The rows are what you aim at with ↑/↓ and press ⏎
            // on, and this box changes shape as that selection moves — putting it above would make
            // the list you're aiming at move every time you moved within it.
            if let preview = model.preview {
                Divider()
                previewBox(preview)
            }
            // The receipt takes the hint's place rather than the whole bar's.
            //
            // It used to be the whole bar, because the bar was on its way out and the receipt was the
            // last thing it had to say. Now the bar stays and the field keeps the keyboard, so the
            // receipt has to be something you read *while* typing the next line — which means it can
            // move nothing the eye is using. The footer is the one place that's true: it's below
            // everything you aim at, and it's already the line that says what the bar is doing.
            if let receipt = model.receipt {
                Divider()
                receiptLine(receipt)
            } else if let hint {
                Divider()
                hintLine(hint)
            }
        }
        .frame(width: QuickBarMetrics.width, alignment: .leading)
        // The one animation the bar has, and the only place it can live. The panel is sized to this
        // view, so animating here makes the layout, the `clipShape` mask and the glass behind it one
        // interpolation of one edge; the controller reads the height off the curve and moves the
        // window to wherever the content already is. Animating the window instead put a second curve
        // under the same corners, and the frames where the two disagreed showed square ones.
        .animation(model.animatesLayout ? .easeOut(duration: QuickBarMetrics.resizeDuration) : nil,
                   value: heightSignature)
        .background(GeometryReader { geo in
            Color.clear.preference(key: QuickBarHeightKey.self, value: geo.size.height)
        })
        .onPreferenceChange(QuickBarHeightKey.self) { onContentHeight($0) }
        .preferredColorScheme(colorMode.colorScheme)
        .background { GlassBackground() }
        .clipShape(RoundedRectangle(cornerRadius: ProjectWindow.cornerRadius, style: .continuous))
        .ignoresSafeArea(.container, edges: .top)
        // Pinned to the top of the window, which is the only thing keeping the field still.
        //
        // The hosting view fills the panel (`sizingOptions = []`), and SwiftUI centres content that's
        // shorter than the space it's offered. The panel's height is this view's height a frame later
        // — measured here, applied there — so during any change the two disagree, and centring splits
        // that disagreement in half and puts one half above the field. It used to last a single frame.
        // Animating the height stretched it over the whole curve, and the field and its insertion
        // point rode up and down on every `>`. Nothing above the field may move: it's the one thing on
        // screen you are aiming at while you type.
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear { afterCurrentUpdate { fieldFocused = true } }
        .onChange(of: model.selectedRow?.id) { _ in announceSelection() }
        .onChange(of: model.receipt) { announce($0?.spoken) }
    }

    /// Everything that changes how tall the bar is, in one value — so it animates when the rows or the
    /// receipt or the hint change, and stays perfectly still while you type into a list that isn't
    /// moving.
    private var heightSignature: some Equatable {
        [String(model.rows.count), String(model.overflow > 0), model.receipt?.spoken ?? "",
         String(model.preview?.lines.count ?? 0), hint.map(spoken) ?? ""]
    }

    /// What moves the ghost, and nothing else.
    ///
    /// Keyed on where the line lands rather than on the selection, so arrowing between two rows that
    /// put it in the same place moves nothing — and so typing, which changes the ghost's text but not
    /// its position, isn't animated at all.
    private var ghostSignature: some Equatable {
        [model.preview?.ghostIndex ?? -1, model.preview?.ghostDepth ?? -1]
    }

    // MARK: Field

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: model.mode.symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18)
                // Typing `>` changes what the whole bar is for, and this glyph is the only thing that
                // says so in place — the placeholder is gone the moment there's a character in the
                // field, and the rows below are a different list rather than a changed one. Swapping
                // rather than cutting is what makes it read as the same thing becoming something else.
                // It moves nothing around it, which is the condition the field's stillness puts on any
                // animation up here.
                .contentTransition(.symbolEffect(.replace))
                .animation(.easeOut(duration: 0.18), value: model.mode.symbol)
            TextField(model.mode.placeholder, text: $model.query)
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                // Return is taken here rather than through `onSubmit` because the modifiers are part
                // of the command — ⌘↩ means something different from ↩ — and a text field's submit
                // action reports the keystroke without them.
                .onKeyPress(keys: [.return]) { press in
                    model.runSelection(modifiers: press.modifiers)
                    return .handled
                }
                // Arrow keys have to be taken before the field's own caret movement gets them: with
                // one focusable view in the panel, moving the selection is what ↑/↓ are for here.
                .onKeyPress(.upArrow) { model.moveSelection(by: -1); return .handled }
                .onKeyPress(.downArrow) { model.moveSelection(by: 1); return .handled }
                // Only while there's something ghosted to take. Every other time this falls through to
                // the caret, which is what → is for in a text field — and since the completion
                // disappears the moment it's accepted, → is never taken twice running.
                .onKeyPress(.rightArrow) { model.acceptCompletion() ? .handled : .ignored }
                .onKeyPress(.tab) { model.switchMode(); return .handled }
                .onKeyPress(.escape) { model.clearOrDismiss(); return .handled }
                .accessibilityLabel(model.mode.placeholder)
                // The badges beside the field belong to the line rather than to any one row, so they
                // are read with the line rather than with the row that happens to be selected.
                .accessibilityValue(fieldDescription)
                .accessibilityHint("Up and down arrows choose what Return will do.")
                // The rest of the name the top row would give you, drawn where you'd type it.
                //
                // An overlay rather than a layer in a stack, because it must cost the layout nothing:
                // the field shares its line with the badges, and a ghost long enough to want room
                // would take it from them. An overlay is measured by what it's over.
                //
                // The typed half is drawn in `.clear` rather than measured and offset — one text run,
                // laid out by the same engine that laid out the field, so the ghost starts precisely
                // where the typed text stops however the glyphs kern. It draws over the field, and the
                // half it covers is transparent, so what you typed is still the field's own text: this
                // is a suggestion until → takes it, and until then `model.query` is exactly what you
                // typed.
                .overlay(alignment: .leading) {
                    if let completion = model.completion {
                        (Text(model.query).foregroundStyle(.clear)
                            + Text(completion).foregroundStyle(.tertiary))
                            .lineLimit(1)
                            .allowsHitTesting(false)
                            // Said by the field's own `accessibilityValue`, which reads it as a
                            // sentence rather than as a fragment beginning mid-word.
                            .accessibilityHidden(true)
                    }
                }
                // After the overlay, not before: a font set before it would style the field alone, and
                // a ghost in a different size is a ghost that starts in the wrong place.
                .font(.system(size: 18))
            // What the line picked up, beside the line it came out of. These belong to the text, not
            // to any one destination — repeated down a column of rows that all share them, they read
            // as a difference between the rows when they are the one thing the rows have in common.
            if let target = model.reading.target {
                badge(target.displayName, symbol: "folder", tint: .accentColor)
            }
            if let warning = model.unreadableDueLabel {
                badge(warning, symbol: "exclamationmark.triangle", tint: .orange)
            } else if let due = model.parsedDueLabel {
                badge(due, symbol: nil, tint: nil)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// One of the field's badges. Tinted ones are saying something happened to the line — it's going
    /// somewhere else, or it's carrying a date marker that won't become a date; the plain one is only
    /// reading a date back.
    private func badge(_ text: String, symbol: String?, tint: Color?) -> some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.caption) }
            Text(text)
        }
        .font(.callout)
        .lineLimit(1)
        .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(tint.map { AnyShapeStyle($0.opacity(0.14)) } ?? AnyShapeStyle(.quaternary)))
    }

    /// The badges as a sentence, for the reader who can't see them beside the field.
    private var fieldDescription: String {
        [model.completion.map { "completes to \(model.query)\($0)" },
         model.reading.target.map { "going to \($0.displayName)" },
         model.unreadableDueLabel,
         model.parsedDueLabel.map { "due \($0)" }]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    // MARK: Receipt

    /// What a row that has run left behind: one line saying what happened.
    ///
    /// Nothing is waiting on it. The field above still has the keyboard and has already emptied itself
    /// for the next line, so this is read out of the corner of the eye and goes on its own. It exists
    /// because the change it reports is usually somewhere you aren't looking — a project's file, or a
    /// focus two windows away — and a bar that says nothing is one you end up checking by hand.
    private func receiptLine(_ receipt: QuickBarReceipt) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: receipt.isFailure ? "exclamationmark.triangle.fill"
                                                : "checkmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(receipt.isFailure ? AnyShapeStyle(.orange) : AnyShapeStyle(.tint))
            VStack(alignment: .leading, spacing: 2) {
                Text(receipt.message)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                // Only a failure has one: what the store itself complained about, under the sentence
                // naming what you were trying to do. The two answer different questions — which of
                // your rows didn't happen, and why — and neither is much use without the other.
                if let detail = receipt.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 8)
            // The way out, named at the one moment it's news.
            //
            // The bar used to take itself off screen after saying this, so there was nothing to leave.
            // Now it stays — that's the point — and a panel that stays is a panel somebody has to be
            // told how to close. This is where they're already looking.
            Self.render([Self.hint([.escape], "done")])
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(receipt.spoken)
    }

    // MARK: Rows

    private var rowList: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                QuickBarRowView(row: row, isSelected: index == model.selection,
                                optionDown: model.optionDown)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.selection = index
                        model.runSelection(modifiers: NSEvent.modifierFlags.eventModifiers)
                    }
                    // Hovering moves the selection rather than drawing a second highlight: two
                    // different "this one" marks on one list is a question, not an answer.
                    .onHover { inside in if inside { model.selection = index } }
                    // Combined into one element: on screen these are a glyph, a title and a subtitle
                    // laid out in columns, but read aloud they are one thing you can do.
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(row.spokenDescription(optionDown: model.optionDown))
                    .accessibilityAddTraits(index == model.selection ? [.isButton, .isSelected]
                                                                     : .isButton)
            }
            // What the list isn't showing. A capped list that says nothing about being capped looks
            // exactly like a list of everything that matched — and the difference between those two is
            // whether the answer is "type more" or "it isn't there".
            if model.overflow > 0 {
                Text("\(model.overflow) more — keep typing")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 14)
                    .padding(.top, 4)
                    .padding(.bottom, 2)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Results")
    }

    /// Say what ⏎ would do now, for the reader who can't see which row is highlighted.
    ///
    /// Keyed on the selected row's identity rather than on the index, so it speaks when the row under
    /// the selection *changes* — which covers arrowing down a list and having the list rearrange under
    /// a stationary selection, and stays quiet while you type into a capture whose four destinations
    /// don't move.
    private func announceSelection() {
        guard model.receipt == nil, let row = model.selectedRow else { return }
        announce(row.spokenDescription(optionDown: model.optionDown))
    }

    private func announce(_ message: String?) {
        guard let message else { return }
        AccessibilityNotification.Announcement(message).post()
    }

    // MARK: Session preview

    /// The session with the line being typed already in it.
    ///
    /// The rows say where a line goes; this shows it. They are not the same answer — "Narrow under it"
    /// puts the new task *above* that task's existing children, which the rows can only state and this
    /// makes obvious at a glance.
    private func previewBox(_ preview: SessionPreview) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(preview.heading)
                if let detail = preview.detail {
                    Text("·")
                    // A heading can be the thing that changes: `>session standup` renames today's,
                    // and archiving takes the whole session somewhere else. Tinted for the same
                    // reason a changed line is — this is what you're about to do.
                    Text(detail)
                        .foregroundStyle(preview.detailIsChanging ? AnyShapeStyle(.tint)
                                                                  : AnyShapeStyle(.tertiary))
                }
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .padding(.bottom, 3)

            ForEach(preview.lines) { line in previewRow(line) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        // The one place in this bar where something is *meant* to move. The box is below everything
        // you aim at, so a line sliding between two positions costs nothing and is the whole point:
        // you see where ↑/↓ and ⌥ put the task rather than reading that they would.
        .animation(model.animatesLayout ? .easeOut(duration: 0.14) : nil, value: ghostSignature)
        // Read as one thing. Line by line it's a list of tasks the reader can't act on, and the rows
        // above have already said what ⏎ will do.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenPreview(preview))
    }

    private func previewRow(_ line: PreviewLine) -> some View {
        HStack(spacing: 7) {
            if line.kind != .blank {
                Image(systemName: glyph(line))
                    .font(.system(size: 10))
                    .foregroundStyle(line.change.isChange ? AnyShapeStyle(.tint)
                                                          : AnyShapeStyle(.tertiary))
                    .frame(width: 11)
            }
            Text(text(line))
                // Three levels, no chrome: the context is dim, the task the rows point at is not, and
                // the line you're adding is tinted. Anything more would be a second selection on
                // screen competing with the real one in the row list above.
                .foregroundStyle(style(line))
                .strikethrough(line.checked, color: .secondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            // Where the project's attention is — or where it's about to be, which is the whole
            // content of Dive In and half the content of Complete.
            if line.isFocused, !line.isAnchor || line.change == .focusing {
                Image(systemName: "scope")
                    .font(.system(size: 9))
                    .foregroundStyle(line.change == .focusing ? AnyShapeStyle(.tint)
                                                              : AnyShapeStyle(.tertiary))
            }
            if let due = line.due {
                Text(RelativeDue.short(due))
                    .font(.caption2)
                    .foregroundStyle(line.change.isChange ? AnyShapeStyle(.tint)
                                                          : AnyShapeStyle(.tertiary))
            }
        }
        .font(.system(size: 12))
        // Two spaces per level in the file; a little more than that on screen, where the indent has to
        // survive being read at caption size.
        .padding(.leading, CGFloat(line.depth) * 14)
        .frame(height: QuickBarMetrics.previewLineHeight)
    }

    /// The line's own glyph.
    ///
    /// Read off the line's *state*, not off what's changing about it — the preview draws the project
    /// as it will be, so a task being completed already arrives here checked and a task being wrapped
    /// already arrives at its new depth. The change decides the colour and nothing else, which is why
    /// one drawing serves every command.
    private func glyph(_ line: PreviewLine) -> String {
        switch line.kind {
        case .note: return "text.alignleft"
        case .blank: return ""
        case .elsewhere(let below): return below ? "chevron.down" : "chevron.up"
        case .task: return line.checked ? "checkmark.circle.fill" : "circle"
        }
    }

    /// A ghost with nothing typed into it yet is a hole the line will fill, so it says what goes there
    /// rather than sitting empty — the same words the field's placeholder uses, for the same reason.
    private func text(_ line: PreviewLine) -> String {
        guard line.kind != .blank else { return " " }
        guard !line.text.isEmpty else {
            return line.isGhost ? (line.kind == .note ? "Your note…" : model.mode.placeholder) : " "
        }
        return line.text
    }

    /// Three levels and one accent: context is dim, the task the rows point at is not, and anything
    /// the selected row changes is tinted. A command that lights nothing up is a command that doesn't
    /// touch your tasks, which is the most useful thing the box can say about two thirds of the list.
    private func style(_ line: PreviewLine) -> AnyShapeStyle {
        if line.isGhost, line.text.isEmpty { return AnyShapeStyle(.tertiary) }
        if line.change.isChange { return AnyShapeStyle(.tint) }
        return line.isAnchor ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
    }

    /// The preview as a sentence. A reader who can't see the tree still wants the one fact it adds
    /// that the row doesn't: which session, and what the line lands between.
    private func spokenPreview(_ preview: SessionPreview) -> String {
        let around = preview.lines.indices.contains(preview.ghostIndex - 1)
            ? preview.lines[preview.ghostIndex - 1] : nil
        let after = around.flatMap { $0.kind == .blank ? nil : $0.text }
        return [preview.heading, preview.detail, after.map { "after “\($0)”" }]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    // MARK: Hint

    /// Where a captured line is going, named — or nil when a badge beside the field is already saying
    /// so, which is what a `@…` redirect puts there.
    private var destination: String? {
        guard model.reading.target == nil else { return nil }
        return model.focusedProjectName.map { QuickBarModel.display($0) }
    }

    /// The line under the rows.
    ///
    /// In capture it names the project, because that's the one thing the rows can't show you and the
    /// one thing you most need to be sure of when you're typing from inside another app. The rows
    /// themselves say what ⏎ does, so the keys listed here are only the ones that aren't on screen.
    private var hint: [[HintPart]]? {
        switch model.mode {
        case .capture:
            // Nowhere to put a line, and two rows above offering to fix that. The sentence says which
            // problem they're for; the third way out is the one the rows can't be.
            guard model.reading.target != nil || model.focusedProjectName != nil else {
                return [[.text("No focused project — or end the line with @ and a project name.")],
                        Self.switchHint(model.mode)]
            }
            var parts = [destination.map { [HintPart.text("Adding to \($0)")] }].compactMap { $0 }
            // Before anything's been typed the rows are a preview of where a line would go, so the
            // keys that act on a line have nothing to act on yet. What's worth saying instead is the
            // two things you can put in the line that the rows can't show you the shape of. Both stay
            // as plain characters, because they are what you type — a key you hold is drawn, a
            // character you type is spelled.
            guard !model.reading.text.isEmpty else {
                parts.append([.text("due:friday sets a date")])
                parts.append([.text("@project sends it elsewhere")])
                return parts
            }
            parts.append(Self.revealHint)
            // There's room for it here whenever it applies: a completion in capture only ever comes
            // from a resolved `@…`, and a redirected line has no anchor — so the ⌥ hint below is
            // already absent on exactly the lines this one appears on.
            if model.completion != nil { parts.append(Self.acceptHint) }
            // Only while ⌥ is up: once it's held the row itself says "Add before", and a hint still
            // offering to do what's already been done reads as a second, different option.
            let hasSibling = model.rows.contains { if case .capture(.after, _, _, _, _) = $0 { return true } else { return false } }
            if hasSibling, !model.optionDown { parts.append(Self.hint([.option], "before")) }
            parts.append(Self.switchHint(model.mode))
            return parts

        case .goToProject:
            // Spelled out rather than left to the ⌘ rule, because this is the row where the two halves
            // are furthest apart: one switches PM in the background, the other puts a window in front.
            if model.isEmptyState { return Self.nothingMatched("project", model) }
            var parts = [Self.hint([.return], "focus"),
                         Self.hint([.command, .return], "and open it")]
            if model.completion != nil { parts.append(Self.acceptHint) }
            parts.append(Self.switchHint(model.mode))
            return parts

        case .findTask:
            if model.isEmptyState { return Self.nothingMatched("open task", model) }
            guard !model.rows.isEmpty else {
                return [[.text("Nothing open here yet — type to search every project.")],
                        Self.switchHint(model.mode)]
            }
            // The same two halves as a project row: one moves the focus and leaves you where you are,
            // the other puts the task in front of you.
            return [Self.hint([.return], "focus it"),
                    Self.revealHint,
                    Self.switchHint(model.mode)]

        case .command:
            guard let project = model.focusedProjectName else {
                return [[.text("No focused project — most commands have nothing to act on.")],
                        Self.switchHint(model.mode)]
            }
            if model.isEmptyState || model.rows.isEmpty { return Self.nothingMatched("command", model) }
            return [[.text(QuickBarModel.display(project))],
                    Self.revealHint,
                    Self.switchHint(model.mode)]
        }
    }

    /// The line for a search that found nothing. Names what was searched for and leaves ⇥ on the end,
    /// because a mode with no answers is exactly where you most need to be told there are other modes.
    private static func nothingMatched(_ noun: String, _ model: QuickBarModel) -> [[HintPart]] {
        [[.text("No \(noun) matches “\(QuickBarModel.truncate(model.argument, 30))”.")],
         switchHint(model.mode)]
    }

    /// A segment: the keys you press, then the words for what pressing them does.
    private static func hint(_ caps: [KeyCap], _ words: String) -> [HintPart] {
        caps.map(HintPart.key) + [.text(" \(words)")]
    }

    /// One sentence for the one thing ⌘ means, wherever it's offered.
    private static let revealHint = hint([.command, .return], "and show me")

    /// Only shown while there's something ghosted after the caret — a key that does nothing is worse
    /// than a key nobody mentioned.
    private static let acceptHint = hint([.rightArrow], "complete")

    /// What ⇥ switches to, named. "⇥ switch" never said there was anywhere to switch *to*, which is
    /// the only way the modes you didn't summon get found.
    private static func switchHint(_ mode: QuickBarMode) -> [HintPart] {
        hint([.tab], mode.next.shortTitle)
    }

    private func hintLine(_ segments: [[HintPart]]) -> some View {
        Self.render(segments)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            // The keys are drawn, so they have to be said. Left alone, a symbol inside a `Text` reads
            // as nothing at all, and the line becomes "and show me" — the half that means least on its
            // own.
            .accessibilityLabel(spoken(segments))
    }

    /// Draw the line. Keys within a segment butt together, so a chord reads as one press rather than
    /// as two keys that happen to be adjacent.
    private static func render(_ segments: [[HintPart]]) -> Text {
        var line: Text?
        for parts in segments {
            var segment = Text("")
            for part in parts {
                switch part {
                case .key(let cap): segment = segment + Text(Image(systemName: cap.symbol))
                case .text(let words): segment = segment + Text(words)
                }
            }
            line = line.map { $0 + Text("  ·  ") + segment } ?? segment
        }
        return line ?? Text("")
    }

    /// Say the line. Keys become their names, and the segments become separate sentences: the
    /// interpunct between them is a pause, not a word, and read out as one it's just noise.
    private func spoken(_ segments: [[HintPart]]) -> String {
        segments.map { parts in
            var out = ""
            for part in parts {
                switch part {
                case .key(let cap):
                    if !out.isEmpty { out += " " }
                    out += cap.spoken
                case .text(let words):
                    out += words
                }
            }
            return out
        }
        .joined(separator: ". ")
    }
}

/// A key named in the hint line, as something to draw and something to say.
///
/// Drawn as a symbol rather than as ⌘, ⌥ and ↩ themselves. The characters are what a menu uses and
/// they are not wrong, but a menu sets them in its own column at its own size; here they sit inside a
/// caption-sized sentence, where the font's own key glyphs come out light and sitting low against the
/// words beside them. A symbol is drawn to the text style it's in, so it takes the line's weight and
/// baseline and stops being something the eye has to resolve separately from the words.
private enum KeyCap {
    case command, option, control, shift, escape, tab, rightArrow
    case `return`

    var symbol: String {
        switch self {
        case .command: return "command"
        case .option: return "option"
        case .control: return "control"
        case .shift: return "shift"
        case .escape: return "escape"
        case .return: return "return"
        case .rightArrow: return "arrow.right"
        // The one key with no symbol of its own. `arrow.right.to.line` is the drawing the ⇥ character
        // is and the drawing on the key itself — an arrow stopped at a bar — so it's the closest thing
        // to the legend, and near enough that it doesn't read as the odd one out beside the rest.
        case .tab: return "arrow.right.to.line"
        }
    }

    /// What it's called out loud, for the reader who gets no glyphs at all.
    var spoken: String {
        switch self {
        case .command: return "Command"
        case .option: return "Option"
        case .control: return "Control"
        case .shift: return "Shift"
        case .escape: return "Escape"
        case .return: return "Return"
        case .tab: return "Tab"
        case .rightArrow: return "Right arrow"
        }
    }
}

/// A piece of a hint line: a key to press, or the words for what it does.
private enum HintPart {
    case key(KeyCap)
    case text(String)
}

/// One row: what it is on the left, what it costs you to know on the right. What it says is the row's
/// own business — see `QuickBarRow.title(optionDown:)` — because it has to say the same thing aloud.
private struct QuickBarRowView: View {
    let row: QuickBarRow
    let isSelected: Bool
    let optionDown: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: row.symbol(optionDown: optionDown))
                .font(.system(size: 13))
                .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title(optionDown: optionDown)).lineLimit(1)
                if let subtitle = row.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let trailing = row.trailing {
                Text(trailing)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // The key that runs this row, on the row it runs. The hint line lists the keys that aren't
            // on screen; this is the one that is, and putting it where the action is means it's read
            // in passing rather than looked up. Only on the selected row, because that's the only row
            // ⏎ would act on — on all of them it would be a claim that any of them is next.
            if isSelected, row.isRunnable {
                Image(systemName: KeyCap.return.symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        // A capture row with nothing typed yet is a preview of where a line would go, not something to
        // run. It reads a step back so the list looks like an answer waiting on a question.
        .opacity(row.isRunnable ? 1 : 0.55)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.selection)
                    .padding(.horizontal, 6)
            }
        }
    }
}

enum QuickBarMetrics {
    /// Wider than the focus panel: this one holds a sentence being typed, not a single task's title.
    static let width: CGFloat = 560

    /// One line of the session preview. Fixed, so a five-line box is exactly as tall whatever is in
    /// it — see `QuickBarModel.windowed`.
    static let previewLineHeight: CGFloat = 19

    /// How long the bar takes to grow or shrink a row. Long enough to read as movement, short enough
    /// that a row you were about to press ⏎ on has stopped moving before you get there.
    static let resizeDuration: TimeInterval = 0.12
}

private struct QuickBarHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
