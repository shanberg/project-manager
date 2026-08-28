import AppKit
import PmLib
import SwiftUI

/// Today's session note, full screen, from wherever you happen to be.
///
/// The largest of the note surfaces and deliberately not a replacement for the others: the project
/// window's takeover still edits notes in place, several windows at a time, and the quick bar's note
/// mode is the same editor in a strip. What this adds is room — write down what just happened, paste
/// the screenshot, amend the paragraph from ten minutes ago, and go back to work.
///
/// **Edits are live**, and now that is true of every note surface rather than only this one. All three
/// drive a `LiveSessionNote`: the note opens holding today's whole prose with the caret at the end,
/// every keystroke is written through on a short debounce, and there is no save, no revert and no
/// cancel. Escape closes a window; it doesn't decide anything. ⌃⌘F between the bar and here is a
/// change of size, not a change of rules.
@MainActor
final class SessionNoteController: NSObject {
    static let shared = SessionNoteController()

    private let surface = SessionNoteSurfaceModel()
    private let note = LiveSessionNote()
    private(set) var isPresenting = false

    private override init() {
        super.init()
        surface.onTextChanged = { [weak self] text in self?.note.changed(text) }
        surface.onClose = { [weak self] in self?.dismiss() }
        // Following a reference means leaving: this surface fills the screen, and a window opened
        // behind it would be a window nobody can see. Dismissed only once the name is known to
        // resolve, so clicking `[[Dana]]` doesn't throw you out of the note for nothing.
        surface.onOpenProject = { [weak self] folder in
            guard WindowManager.shared.open(named: folder) else { return }
            self?.dismiss()
        }
        note.onProse = { [weak self] in self?.surface.applyExternalChange($0) }
        note.onSessionLabel = { [weak self] in self?.surface.sessionLabel = $0 }
        note.onNoteURL = { [weak self] in self?.surface.noteURL = $0 }
        note.onProjectName = { [weak self] in self?.surface.projectName = $0 }
    }

    /// The hotkey: up if it's down, down if it's up.
    func toggle() {
        isPresenting ? dismiss() : present()
    }

    // MARK: Presenting

    /// `appending` is prose from another surface to be carried into the note.
    ///
    /// Rarely needed now. It existed because the quick bar composed a paragraph this surface knew
    /// nothing about; both write the same note live today, so a handover normally has nothing to
    /// carry — the text is already on disk before this opens. It remains for the one case that isn't
    /// covered: a line typed into *capture* and promoted straight past the bar's note mode.
    func present(appending carried: String? = nil) {
        guard !isPresenting else { return }
        guard let key = PMFiles.focusedProjectKey() else {
            Log.write("session note: no focused project")
            NSSound.beep()
            return
        }
        isPresenting = true
        note.open(projectKey: key, appending: carried)

        ImmersivePresenter.shared.present(SessionNoteSurface(model: surface),
                                          onBackdropClick: { [weak self] in self?.dismiss() })
        Log.write("session note opened for \(note.store?.projectName ?? key)")
    }

    func dismiss() {
        guard isPresenting else { return }
        isPresenting = false
        note.close(surface.text)
        ImmersivePresenter.shared.dismiss { [weak self] in
            self?.surface.applyExternalChange("")
        }
    }
}
