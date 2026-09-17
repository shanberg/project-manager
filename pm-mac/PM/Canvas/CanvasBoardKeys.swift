import AppKit

/// Which key means what on the board, in the two modes that take the keyboard for themselves.
///
/// Lifted out of `CanvasBoardView+Input` as decisions rather than actions. The board's `keyDown` still
/// does the doing — handing a key to a card's editor, making something first responder, calling into the
/// tiling — but *which* command a key press is had no way to be checked: nothing in the test bundle can
/// build a board. Both tables read two facts about the board and nothing else, which is what made them
/// worth separating. See `CanvasBoardKeysTests`.
enum CanvasBoardKeys {

    /// A key press, reduced to the four things these tables read. Built from an `NSEvent` in the app and
    /// written out directly in tests.
    struct Press: Equatable {
        var specialKey: NSEvent.SpecialKey?
        var characters: String?
        var flags: NSEvent.ModifierFlags
        var isRepeat: Bool
        /// The physical key, for the few keys that are named by where they sit rather than by what they
        /// type — ⇧1 reports "!" on one layout and "+" on another.
        var keyCode: UInt16?

        init(specialKey: NSEvent.SpecialKey? = nil, characters: String? = nil,
             flags: NSEvent.ModifierFlags = [], isRepeat: Bool = false, keyCode: UInt16? = nil) {
            self.specialKey = specialKey
            self.characters = characters
            self.flags = flags.intersection(.deviceIndependentFlagsMask)
            self.isRepeat = isRepeat
            self.keyCode = keyCode
        }

        init(_ event: NSEvent) {
            self.init(specialKey: event.specialKey, characters: event.charactersIgnoringModifiers,
                      flags: event.modifierFlags, isRepeat: event.isARepeat, keyCode: event.keyCode)
        }

        var direction: CanvasNavigation.Direction? {
            switch specialKey {
            case .leftArrow: return .left
            case .rightArrow: return .right
            case .upArrow: return .up
            case .downArrow: return .down
            default: return nil
            }
        }
    }

    // MARK: Picking cards on the board

    enum PickingCommand: Equatable {
        /// Taken and ignored. Picking takes the keyboard whole, so a key that means nothing here still
        /// must not reach the board: ⌫ would delete a card off the board you are only choosing from.
        case swallow
        case endPicking, beginPeek, endPeek, finishPeek, beep
    }

    /// Picking cards on the board. Space peeks at the card under the pointer; Escape, Return and ⌥B go
    /// back to the workspace — or, peeking, Space and Escape put the card back and Return adds it.
    static func picking(_ press: Press, peeking: Bool, hovering: Bool) -> PickingCommand {
        let key = press.characters?.lowercased()
        // A held Space would peek, un-peek and peek again at key-repeat rate.
        if key == " ", press.isRepeat { return .swallow }
        if press.flags.contains(.option), key == "b" { return .endPicking }
        if peeking {
            if key == " " || key == "\u{1b}" { return .endPeek }
            if key == "\r" { return .finishPeek }
            return .swallow
        }
        if key == " " { return hovering ? .beginPeek : .beep }
        if key == "\u{1b}" || key == "\r" { return .endPicking }
        return .swallow
    }

    // MARK: The board

    /// Whether this press holds the board for panning: Space, and nothing that would make it a
    /// shortcut. A held Space repeats, and every repeat is the same hold. See
    /// `CanvasBoardView.holdForPanning`.
    static func holdsToPan(_ press: Press) -> Bool {
        press.characters == " " && press.flags.subtracting([.capsLock, .function, .numericPad]).isEmpty
    }

    // MARK: Fitting the view

    enum FitCommand: Equatable { case all, selection }

    /// ⇧1 fits the whole board and ⇧2 fits what is selected — Figma's pair, and the grammar backlog 17
    /// settled on. ⌘+, ⌘− and ⌘0 stay the Mac's, so ⇧0 is not taken: it would be a second key for ⌘0.
    ///
    /// **By key position, and never as menu key equivalents.** A shifted digit is a character on every
    /// layout — ! and @ here, + and " on a Swiss one — so an equivalent would take it from every card you
    /// type in. A key only reaches the board when nothing that types wanted it, which is the same bargain
    /// the workspace's ⌥ keys make.
    static func fit(_ press: Press) -> FitCommand? {
        guard press.flags.subtracting([.capsLock, .function, .numericPad]) == .shift else { return nil }
        switch press.keyCode {
        case 18: return .all        // kVK_ANSI_1
        case 19: return .selection  // kVK_ANSI_2
        default: return nil
        }
    }

    // MARK: The workspace

    enum WorkspaceCommand: Equatable {
        case choosePlacement(CanvasTileSession.Side)
        case confirmPlacement
        case moveTile(CanvasNavigation.Direction)
        case moveFocus(CanvasNavigation.Direction)
        case removeTile
        case grow(vertically: Bool, by: Double)
        case balance, sizeToContent, beginPicking, focusPrevious
        case stepTab(Int)
        case pullTabOut
        case beginPlacing, cancelPlacement
        /// A key that means something here, asked for when it can't be done — ⌥T with no tile focused.
        case beep
    }

    /// The workspace's keys (docs/canvas-workspaces.md §7k): ⌥ with the arrows, =, −, 0, `, [, ], T, N,
    /// B and ⌫, and while ⌥N is choosing, the plain arrows, T and Return. Nil for a key the workspace
    /// doesn't take, which then goes on to the board's ordinary handling.
    ///
    /// **Never with ⌘ or ⌃**, so a menu's key equivalents stay the menu's. And these are keys rather than
    /// key equivalents on purpose: a key equivalent is taken before the view you are typing in sees it,
    /// and in a text card ⌥= is ≠ and ⌥N starts a tilde. A key only reaches the board when nothing that
    /// types wanted it, which is exactly when it can safely mean the workspace.
    static func workspace(_ press: Press, choosingPlacement: Bool, hasFocusedTile: Bool,
                          step: Double) -> WorkspaceCommand? {
        guard !press.flags.contains(.command), !press.flags.contains(.control) else { return nil }
        let option = press.flags.contains(.option), shift = press.flags.contains(.shift)

        if choosingPlacement, !option {
            if let direction = press.direction {
                switch direction {
                case .left: return .choosePlacement(.left)
                case .right: return .choosePlacement(.right)
                case .up: return .choosePlacement(.above)
                case .down: return .choosePlacement(.below)
                }
            }
            if press.characters == "\r" { return .confirmPlacement }
            // T: into the tile's tabs, rather than beside it.
            if press.characters?.lowercased() == "t" { return .choosePlacement(.tab) }
        }
        guard option else { return nil }

        if let direction = press.direction { return shift ? .moveTile(direction) : .moveFocus(direction) }
        if press.specialKey == .delete { return .removeTile }
        // Shift changes the character these report, not only the flags: ⌥⇧= arrives as "+".
        switch press.characters {
        case "=", "+": return .grow(vertically: shift, by: step)
        case "-", "_": return .grow(vertically: shift, by: -step)
        case "0": return .balance
        case ")": return .sizeToContent
        case "b", "B": return .beginPicking
        case "`": return .focusPrevious
        case "[": return .stepTab(-1)
        case "]": return .stepTab(1)
        case "t", "T": return hasFocusedTile ? .pullTabOut : .beep
        case "n", "N": return choosingPlacement ? .cancelPlacement : .beginPlacing
        default: return nil
        }
    }
}
