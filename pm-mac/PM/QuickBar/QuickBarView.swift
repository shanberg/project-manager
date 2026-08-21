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
            if let hint {
                Divider()
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
        }
        .frame(width: QuickBarMetrics.width, alignment: .leading)
        .background(GeometryReader { geo in
            Color.clear.preference(key: QuickBarHeightKey.self, value: geo.size.height)
        })
        .onPreferenceChange(QuickBarHeightKey.self) { onContentHeight($0) }
        .preferredColorScheme(colorMode.colorScheme)
        .background { GlassBackground() }
        .clipShape(RoundedRectangle(cornerRadius: ProjectWindow.cornerRadius, style: .continuous))
        .ignoresSafeArea(.container, edges: .top)
        .onAppear { afterCurrentUpdate { fieldFocused = true } }
    }

    // MARK: Field

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: model.mode.symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            TextField(model.mode.placeholder, text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 18))
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
                .onKeyPress(.tab) { model.switchMode(); return .handled }
                .onKeyPress(.escape) { model.onDismiss(); return .handled }
            // The date the line parsed to, beside the line it came out of. It belongs to the text,
            // not to any one destination — repeated down a column of rows that all share it, it reads
            // as a difference between them when it's the one thing they have in common.
            if let due = model.parsedDueLabel {
                Text(due)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(.quaternary))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
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
            }
        }
        .padding(.vertical, 4)
    }

    /// The line under the rows.
    ///
    /// In capture it names the project, because that's the one thing the rows can't show you and the
    /// one thing you most need to be sure of when you're typing from inside another app. The rows
    /// themselves say what ⏎ does, so the keys listed here are only the ones that aren't on screen.
    private var hint: String? {
        switch model.mode {
        case .capture:
            guard let project = model.focusedProjectName else {
                return "No focused project — nowhere to add a task."
            }
            guard !model.rows.isEmpty else {
                return "Type a task. End with due:tomorrow to set a date.  ⇥ switch"
            }
            var parts = ["Adding to \(project)", Self.revealHint]
            // Only while ⌥ is up: once it's held the row itself says "Add before", and a hint still
            // offering to do what's already been done reads as a second, different option.
            let hasSibling = model.rows.contains { if case .capture(.after, _, _, _) = $0 { return true } else { return false } }
            if hasSibling, !model.optionDown { parts.append("⌥ before") }
            parts.append("⇥ switch")
            return parts.joined(separator: "  ·  ")

        case .goToProject:
            // Spelled out rather than left to the ⌘ rule, because this is the row where the two halves
            // are furthest apart: one switches PM in the background, the other puts a window in front.
            return model.rows.isEmpty && !model.argument.isEmpty
                ? "No project matches “\(model.argument)”."
                : "↩ focus  ·  ⌘↩ and open it  ·  ⇥ switch"

        case .command:
            guard let project = model.focusedProjectName else {
                return "No focused project — most commands have nothing to act on."
            }
            if model.rows.isEmpty { return "No command matches “\(model.argument)”." }
            return "\(project)  ·  \(Self.revealHint)  ·  ⇥ switch"
        }
    }

    /// One sentence for the one thing ⌘ means, wherever it's offered.
    private static let revealHint = "⌘↩ and show me"
}

/// One row: what it is on the left, what it costs you to know on the right.
private struct QuickBarRowView: View {
    let row: QuickBarRow
    let isSelected: Bool
    let optionDown: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
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

    private var symbol: String {
        switch row {
        case .capture(let placement, _, _, _): return placement.symbol(optionDown: optionDown)
        case .project(_, _, _, _, let isArchived): return isArchived ? "archivebox" : "folder"
        case .command(let command, _): return command.symbol
        }
    }

    /// A capture row is titled by what it *does*, not by what you typed — the typed line is in the
    /// field directly above, and four rows repeating it back is noise where the difference between
    /// them is the whole point.
    private var title: String {
        switch row {
        case .capture(let placement, _, _, let anchor):
            return placement.title(anchor: anchor, optionDown: optionDown)
        case .project(_, _, let shortName, _, _): return shortName
        case .command(let command, _): return command.title
        }
    }

    private var subtitle: String? {
        switch row {
        case .capture: return nil
        case .project(_, let name, _, let domain, _):
            let code = name.split(separator: " ").first.map(String.init) ?? name
            return domain.isEmpty ? code : "\(code)  ·  \(domain)"
        // The text a verb was given, echoed back — or, for a command sitting in the list with none
        // yet, the text it would take and the word that introduces it.
        case .command(let command, let argument):
            if !argument.isEmpty { return argument }
            guard let verb = command.verb, let label = command.argumentLabel else { return nil }
            // Written the way you'd type it, sigil and all, rather than described. The sigil is
            // redundant once you're already in this mode, but it's the form that works from anywhere.
            return ">\(verb) \(label)"
        }
    }

    /// The right-hand column. Only a project row has anything to say here — a capture row's due date
    /// is shown once, up in the field, since every row shares it.
    private var trailing: String? {
        switch row {
        case .capture, .command: return nil
        case .project(_, _, _, _, let isArchived): return isArchived ? "Archived" : nil
        }
    }
}

enum QuickBarMetrics {
    /// Wider than the focus panel: this one holds a sentence being typed, not a single task's title.
    static let width: CGFloat = 560
}

private struct QuickBarHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
