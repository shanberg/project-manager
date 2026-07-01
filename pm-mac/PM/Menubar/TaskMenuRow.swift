import AppKit
import SwiftUI
import PmLib

// MARK: - Highlight bridge

/// Bridges NSMenu selection state (mouse hover + keyboard navigation) into the SwiftUI row so a
/// custom `item.view` can draw the same highlight a standard menu item would.
final class MenuRowHighlight: ObservableObject {
    @Published var highlighted = false
}

// MARK: - AppKit host for a custom menu row

/// Hosts a SwiftUI view inside an `NSMenuItem.view`, reproducing the parts of native menu behavior
/// that custom views otherwise lose: it tracks the mouse to drive the highlight, mirrors the owning
/// item's keyboard highlight, and fires a selection closure on click (reading the ⌥ modifier) and on
/// Return. Kept off the main actor so it can override AppKit's non-isolated `NSView` hooks; every
/// path runs on the main thread at runtime.
final class MenuRowView: NSView {
    let highlight = MenuRowHighlight()
    private let onSelect: (_ optionHeld: Bool) -> Void

    init<Content: View>(width: CGFloat, fallbackHeight: CGFloat = 24,
                        onSelect: @escaping (_ optionHeld: Bool) -> Void,
                        @ViewBuilder content: () -> Content) {
        self.onSelect = onSelect
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: fallbackHeight))
        let hosting = NSHostingView(rootView: AnyView(content().environmentObject(highlight)))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        layoutSubtreeIfNeeded()
        let fitted = hosting.fittingSize.height
        frame.size.height = fitted > 1 ? fitted : fallbackHeight
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The initial `width` only sets the menu's minimum width. The menu can be wider than that when a
    /// standard item is longer, and it reserves a right-hand gutter for key equivalents and submenu
    /// arrows that `autoresizingMask` won't stretch a custom view into — leaving the row short of the
    /// full width. The item view's superview spans that full row width, so match it here on every
    /// layout pass to make the highlight bleed edge-to-edge.
    override func layout() {
        super.layout()
        if let full = superview?.bounds.width, full > 0, abs(full - frame.width) > 0.5 {
            frame.size.width = full
        }
    }

    /// The owning item's `isHighlighted` is the single source of truth for selection — AppKit
    /// manages it correctly for both mouse hover and keyboard, and redraws this view whenever it
    /// changes, so reading it here (rather than via mouse tracking, which a menu swallows) avoids the
    /// highlight sticking on. Pushed to the model async to stay clear of the AppKit draw pass.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let hl = enclosingMenuItem?.isHighlighted ?? false
        if hl != highlight.highlighted {
            DispatchQueue.main.async { [weak self] in self?.highlight.highlighted = hl }
        }
    }

    override func mouseUp(with event: NSEvent) {
        let option = event.modifierFlags.contains(.option)
        onSelect(option)
        enclosingMenuItem?.menu?.cancelTracking()
    }

    /// Invoked when the row is chosen via the keyboard (Return). No modifier is available there.
    @objc func fire() {
        onSelect(false)
        enclosingMenuItem?.menu?.cancelTracking()
    }
}

// MARK: - Non-interactive host (header)

/// Wraps a SwiftUI view in an `NSMenuItem.view` with no interaction — used for the header/progress
/// strip so it can show a real progress bar the menu chrome can't.
final class MenuStaticView: NSView {
    init<Content: View>(width: CGFloat, fallbackHeight: CGFloat, @ViewBuilder content: () -> Content) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: fallbackHeight))
        let hosting = NSHostingView(rootView: AnyView(content()))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        layoutSubtreeIfNeeded()
        let fitted = hosting.fittingSize.height
        frame.size.height = fitted > 1 ? fitted : fallbackHeight
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Match the menu's full row width so the header spans edge-to-edge — see `MenuRowView.layout()`.
    override func layout() {
        super.layout()
        if let full = superview?.bounds.width, full > 0, abs(full - frame.width) > 0.5 {
            frame.size.width = full
        }
    }
}

// MARK: - SwiftUI content

/// Coarse due state used to color the row's due pill.
enum DueState {
    case overdue, soon, later, inherited

    init(due: String, own: Bool) {
        if RelativeDue.isOverdue(due) { self = .overdue }
        else if let d = RelativeDue.dayDelta(due), d <= 1 { self = .soon }
        else if own { self = .later }
        else { self = .inherited }
    }
}

/// A single open task, styled to match the panel: leading state glyph, title (bold when focused),
/// and a trailing relative-due pill. Highlights via `MenuRowHighlight` for both mouse and keyboard.
struct TaskMenuRowContent: View {
    let todo: Todo
    @EnvironmentObject private var highlight: MenuRowHighlight

    private var dueValue: String? { todo.dueDate ?? todo.effectiveDueDate }
    private var symbol: String { todo.isFocused ? "arrow.right.circle.fill" : "circle" }

    var body: some View {
        let sel = highlight.highlighted
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(sel ? Color.white : (todo.isFocused ? Color.accentColor : Color.secondary))
                .frame(width: 16)
            Text(todo.text)
                .font(.system(size: 13, weight: todo.isFocused ? .semibold : .regular))
                .lineLimit(1)
                .foregroundStyle(sel ? Color.white : Color.primary)
            Spacer(minLength: 6)
            if let due = dueValue {
                DuePillView(text: RelativeDue.short(due),
                            state: DueState(due: due, own: todo.dueDate != nil),
                            selected: sel)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .padding(.leading, CGFloat(todo.depth) * 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(sel ? Color(nsColor: .selectedContentBackgroundColor)
                          : (todo.isFocused ? Color.accentColor.opacity(0.12) : Color.clear))
                .padding(.horizontal, 5)
        )
    }
}

/// The relative-due pill, colored by `DueState` and inverted to translucent-white when the row is
/// selected so it stays legible on the accent highlight.
struct DuePillView: View {
    let text: String
    let state: DueState
    let selected: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .monospacedDigit()
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(background))
            .foregroundStyle(foreground)
    }

    private var tint: Color {
        switch state {
        case .overdue: return Color(nsColor: .systemRed)
        case .soon: return Color(nsColor: .systemOrange)
        case .later, .inherited: return .secondary
        }
    }
    private var background: Color {
        if selected { return Color.white.opacity(0.22) }
        return tint.opacity(state == .inherited ? 0.10 : 0.15)
    }
    private var foreground: Color {
        selected ? .white : tint
    }
}

/// Header strip: a compact progress ring (echoing the status-bar glyph), the project title, and the
/// done/total count. A small ring reads as a status glyph in a menu where a full-width bar didn't.
struct MenuHeaderContent: View {
    let title: String
    let done: Int
    let total: Int

    private var fraction: CGFloat { total > 0 ? CGFloat(done) / CGFloat(total) : 0 }

    var body: some View {
        HStack(spacing: 7) {
            if total > 0 {
                ProgressRing(fraction: fraction).frame(width: 13, height: 13)
            }
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 6)
            if total > 0 {
                Text("\(done)/\(total)")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Thin circular progress indicator used in the menu header.
private struct ProgressRing: View {
    let fraction: CGFloat

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0.02, min(fraction, 1)))
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}
