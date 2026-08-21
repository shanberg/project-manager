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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: Rows

    private var rowList: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                QuickBarRowView(row: row, isSelected: index == model.selection)
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

    /// The line under the rows. Says what ⏎ will do *here*, which differs by mode, rather than listing
    /// every key the panel knows.
    private var hint: String? {
        switch model.mode {
        case .capture:
            guard model.focusedProjectName != nil else { return "No focused project — nowhere to add a task." }
            return model.rows.isEmpty
                ? "Type a task. End with due:tomorrow to set a date.  ⇥ go to project"
                : "↩ add  ·  ⇥ go to project"
        case .goToProject:
            return model.rows.isEmpty && !model.query.isEmpty
                ? "No project matches “\(model.query)”."
                : "↩ open  ·  ⌘↩ focus without opening  ·  ⇥ add a task"
        }
    }
}

/// One row: what it is on the left, what it costs you to know on the right.
private struct QuickBarRowView: View {
    let row: QuickBarRow
    let isSelected: Bool

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
        case .addTask: return "plus.circle.fill"
        case .project(_, _, _, _, let isArchived): return isArchived ? "archivebox" : "folder"
        }
    }

    private var title: String {
        switch row {
        case .addTask(let text, _, _): return text
        case .project(_, _, let shortName, _, _): return shortName
        }
    }

    private var subtitle: String? {
        switch row {
        case .addTask(_, _, let project): return "Add to \(project)"
        case .project(_, let name, _, let domain, _):
            let code = name.split(separator: " ").first.map(String.init) ?? name
            return domain.isEmpty ? code : "\(code)  ·  \(domain)"
        }
    }

    /// The right-hand column: a due date for a task, "Archived" for a project that is.
    ///
    /// The date is spelled out — "Fri, Aug 28" — where a task row's badge would say "in 1w". They're
    /// answering different questions: a badge on an existing task tells you how much time is left,
    /// while this is confirming that the "friday" you just typed landed on the day you meant.
    private var trailing: String? {
        switch row {
        case .addTask(_, let due, _):
            return due.flatMap { RelativeDue.parse($0) }.map { Self.dueFormatter.string(from: $0) }
        case .project(_, _, _, _, let isArchived): return isArchived ? "Archived" : nil
        }
    }

    private static let dueFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE MMM d")
        return formatter
    }()
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
