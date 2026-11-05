import AppKit
import SwiftUI

/// View Options (⌘J) for folder cards — the Finder's panel of that name, for one card at a time.
///
/// **One panel, following the card you are in**, as the Finder's follows the front window: it shows the
/// card it was opened for, and moves to whichever folder card takes the keyboard next while it is up.
/// Each change is written to that card at once, as its own undoable edit, so the panel has no OK button
/// and nothing to lose. **Use as Defaults** makes these the settings every card follows for whatever
/// it hasn't set itself — `CanvasFolderOptions.defaults`.
@MainActor
final class CanvasFolderViewOptions: NSObject, NSWindowDelegate {
    static let shared = CanvasFolderViewOptions()

    private var panel: NSPanel?
    private let state = CanvasFolderViewOptionsState()
    private weak var target: CanvasFolderBrowser?

    /// Whether the panel is up, and for which card — for tests and the menus.
    var isShowing: Bool { panel?.isVisible == true }
    var shownFor: CanvasFolderBrowser? { isShowing ? target : nil }

    override init() {
        super.init()
        state.commit = { [weak self] options, name in self?.target?.commit(options, actionName: name) }
        state.preview = { [weak self] options in self?.target?.preview(options) }
    }

    func show(for browser: CanvasFolderBrowser) {
        let first = panel == nil
        target = browser
        load(browser)
        let panel = self.panel ?? makePanel()
        if first || !panel.isVisible, let window = browser.window {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: window.frame.maxX - size.width - 24, y: window.frame.maxY - size.height - 80))
        }
        panel.orderFront(nil)
    }

    /// Another folder card took the keyboard: the panel, if it is up, is about that one now.
    func follow(_ browser: CanvasFolderBrowser) {
        guard isShowing, target !== browser else { return }
        target = browser
        load(browser)
    }

    /// The card's settings changed from somewhere else — an undo, a menu, another window.
    func refresh(_ browser: CanvasFolderBrowser) {
        guard isShowing, target === browser, state.options != browser.model.options else { return }
        load(browser)
    }

    /// The card is going away.
    func forget(_ browser: CanvasFolderBrowser) {
        guard target === browser else { return }
        target = nil
        panel?.orderOut(nil)
    }

    private func load(_ browser: CanvasFolderBrowser) {
        state.options = browser.model.options
        state.title = FileManager.default.displayName(atPath: browser.model.location.path)
        panel?.title = state.title
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 400),
                            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        let hosting = NSHostingController(rootView: CanvasFolderViewOptionsForm(state: state))
        hosting.sizingOptions = .preferredContentSize
        panel.contentViewController = hosting
        panel.title = state.title
        self.panel = panel
        return panel
    }
}

/// What the panel is showing, and where its changes go.
@MainActor
final class CanvasFolderViewOptionsState: ObservableObject {
    @Published var options = CanvasFolderOptions()
    @Published var title = ""
    var commit: (CanvasFolderOptions, String) -> Void = { _, _ in }
    var preview: (CanvasFolderOptions) -> Void = { _ in }

    func binding<Value: Equatable>(_ path: WritableKeyPath<CanvasFolderOptions, Value>,
                                   _ actionName: String) -> Binding<Value> {
        Binding(get: { self.options[keyPath: path] }, set: { value in
            guard self.options[keyPath: path] != value else { return }
            var next = self.options
            next[keyPath: path] = value
            self.options = next
            self.commit(next, actionName)
        })
    }

    func column(_ column: CanvasFolderColumn) -> Binding<Bool> {
        Binding(get: { self.options.columns.contains(column) }, set: { on in
            var next = self.options
            next.columns = on ? next.columns + [column] : next.columns.filter { $0 != column }
            next.columns = next.orderedColumns
            self.options = next
            self.commit(next, on ? "Show \(column.title)" : "Hide \(column.title)")
        })
    }

    func sort() -> Binding<CanvasFolderSort> {
        Binding(get: { self.options.sort }, set: { sort in
            var next = self.options
            next.sortBy(sort, flipping: false)
            self.options = next
            self.commit(next, "Sort by \(sort.title)")
        })
    }
}

/// The panel's controls, in the Finder's order.
struct CanvasFolderViewOptionsForm: View {
    @ObservedObject var state: CanvasFolderViewOptionsState
    @State private var iconSize: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: state.binding(\.view, "View Options")) {
                Text("List").tag(CanvasFolderView.list)
                Text("Icons").tag(CanvasFolderView.icons)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Text("Group By:").gridColumnAlignment(.trailing)
                    Picker("", selection: state.binding(\.group, "Group By")) {
                        ForEach(CanvasFolderGroup.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("Sort By:")
                    Picker("", selection: state.sort()) {
                        ForEach(CanvasFolderSort.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                }
            }

            if state.options.view == .list {
                Divider()
                Text("Show Columns:").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(CanvasFolderColumn.allCases, id: \.self) { column in
                        Toggle(column.title, isOn: state.column(column))
                    }
                }
                Toggle("Use relative dates", isOn: state.binding(\.relativeDates, "Use Relative Dates"))
            } else {
                Divider()
                HStack {
                    Text("Icon size:")
                    Slider(value: Binding(get: { iconSize ?? state.options.iconSize }, set: { value in
                        iconSize = value
                        var next = state.options
                        next.iconSize = value
                        state.preview(next)
                    }), in: 32...128, step: 4) { editing in
                        guard !editing, let value = iconSize else { return }
                        iconSize = nil
                        var next = state.options
                        next.iconSize = value
                        state.options = next
                        state.commit(next, "Icon Size")
                    }
                    Text("\(Int(iconSize ?? state.options.iconSize))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .trailing)
                }
            }
            Toggle("Show icon preview", isOn: state.binding(\.iconPreviews, "Show Icon Preview"))

            Divider()
            Toggle("Show path bar", isOn: state.binding(\.pathBar, "Path Bar"))
            Toggle("Show status bar", isOn: state.binding(\.statusBar, "Status Bar"))
            Toggle("Keep folders on top", isOn: state.binding(\.foldersOnTop, "Keep Folders on Top"))

            Divider()
            HStack {
                Spacer()
                Button("Use as Defaults") { CanvasFolderOptions.defaults = state.options }
                    .help("New folder cards, and anything a card hasn't set itself, follow these.")
                Spacer()
            }
        }
        .toggleStyle(.checkbox)
        .controlSize(.small)
        .font(.system(size: 12))
        .padding(14)
        .frame(width: 250)
        .fixedSize(horizontal: false, vertical: true)
    }
}
