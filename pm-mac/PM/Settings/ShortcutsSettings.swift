import SwiftUI

/// Shortcuts: the key combinations that reach PM from whatever app you're in.
///
/// Only the focus panel ships bound. The rest start empty because a global shortcut is taken from
/// every app on the machine at once, and which combinations are free is not something PM can guess.
struct ShortcutsSettingsView: View {
    @ObservedObject private var hotKeys = HotKeyManager.shared
    /// The last thing worth saying about an attempted binding — a refusal, or what a new one displaced.
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                ForEach(HotKeyAction.allCases) { action in
                    row(action)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let message {
                        Text(message).foregroundStyle(.secondary)
                    }
                    Text("These work in any app. PM's own menu shortcuts — ⇧⌘⏎, ⇧⌘D — keep working while PM is in front, whether or not the same command has a global shortcut here.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scenePadding()
    }

    @ViewBuilder
    private func row(_ action: HotKeyAction) -> some View {
        LabeledContent {
            HStack(spacing: 4) {
                HotKeyRecorder(
                    combo: hotKeys.binding(for: action),
                    onChange: { combo in record(combo, for: action) },
                    onRejected: { message = $0 })
                    .frame(width: 150, height: 22)
                // Reserve the clear button's space whether or not it's live, so the recorders stay in
                // one column down the pane.
                Button {
                    hotKeys.setBinding(nil, for: action)
                    message = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove shortcut")
                .opacity(hotKeys.binding(for: action) == nil ? 0 : 1)
                .disabled(hotKeys.binding(for: action) == nil)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title)
                if let failure = hotKeys.failures[action] {
                    // A shortcut that didn't register looks identical to one that did until you press
                    // it and nothing happens, so say so here.
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func record(_ combo: KeyCombo?, for action: HotKeyAction) {
        if let combo, let displaced = hotKeys.action(using: combo, excluding: action) {
            message = "\(combo.displayString) was \(displaced.title); it's now \(action.title)."
        } else {
            message = nil
        }
        hotKeys.setBinding(combo, for: action)
    }
}

/// How to describe the focus panel's summon shortcut in prose, given it can be rebound (or cleared)
/// in the Shortcuts pane. Two phrasings because the sentences around them differ.
@MainActor
enum FocusPanelShortcut {
    private static var combo: KeyCombo? { HotKeyManager.shared.binding(for: .toggleFocusPanel) }

    /// "the ⌃⌥P shortcut" / "the focus panel shortcut"
    static var phrase: String {
        combo.map { "the \($0.displayString) shortcut" } ?? "the focus panel shortcut"
    }

    /// "⌃⌥P shows and hides" / "the menu bar item shows and hides"
    static var showsAndHides: String {
        combo.map { "\($0.displayString) shows and hides" } ?? "the menu bar item shows and hides"
    }
}
