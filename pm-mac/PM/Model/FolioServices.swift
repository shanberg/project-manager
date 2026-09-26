import AppKit
import PmLib

/// Services ▸ Send to Focused Project in Folio, and ▸ Send to Project in Folio…
///
/// What arrives decides where it goes, in this order:
/// - **Files** from the Finder are moved into the project's `resources` folder (`ProjectIntake`) and
///   put on its board as file cards, in the Inbox.
/// - **Addresses** become the project's links — cards in its Links frame (`ProjectLinksFrame`), by way
///   of the same `ProjectLinks.add` that Add Link uses, so they are named the same way.
/// - **Text** is written into the project's current session, as the QuickBar's note mode writes it.
///
/// Declared in the app's Info.plist (`NSServices`, via project.yml); this object answers them.
@MainActor
final class FolioServices: NSObject {
    static let shared = FolioServices()

    static func install() {
        NSApp.servicesProvider = shared
        NSUpdateDynamicServices()
    }

    /// What was sent, read off the pasteboard while the call is still running — a service's
    /// pasteboard is only good until it returns, and the chooser answers long after.
    struct Sent {
        var files: [URL] = []
        var addresses: [String] = []
        var text: String?

        init(_ pasteboard: NSPasteboard) {
            let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
            files = urls.filter(\.isFileURL)
            addresses = urls.filter { !$0.isFileURL }.map(\.absoluteString)
            if files.isEmpty, addresses.isEmpty, let string = pasteboard.string(forType: .string) {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if let address = canvasTypedAddress(trimmed) { addresses = [address] }
                else if !trimmed.isEmpty { text = trimmed }
            }
        }

        var isEmpty: Bool { files.isEmpty && addresses.isEmpty && text == nil }
    }

    @objc func sendToFocusedProject(_ pasteboard: NSPasteboard, userData: String?,
                                    error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let sent = Sent(pasteboard)
        guard !sent.isEmpty else { error.pointee = "There was nothing Folio could take."; return }
        guard let key = PMFiles.focusedProjectKey() else {
            error.pointee = "No project is focused in Folio."
            return
        }
        send(sent, to: key)
    }

    @objc func sendToProject(_ pasteboard: NSPasteboard, userData: String?,
                             error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let sent = Sent(pasteboard)
        guard !sent.isEmpty else { error.pointee = "There was nothing Folio could take."; return }
        QuickBarController.shared.pickProject { [weak self] key, _ in self?.send(sent, to: key) }
    }

    // MARK: Putting it there

    private func send(_ sent: Sent, to key: String) {
        guard let projectPath = PMFiles.projectPath(fromKey: key) else { return }
        let name = PMFiles.projectName(fromKey: key) ?? projectPath
        if !sent.files.isEmpty { takeIn(sent.files, projectPath: projectPath, name: name) }
        for address in sent.addresses {
            ProjectLinks.add(address, label: nil, toProject: key) { added in
                Log.write("services: \(added ? "linked" : "already linked") \(address) in \(name)")
            }
        }
        if let text = sent.text {
            let store = StoreRegistry.shared.acquire(key)
            Task { @MainActor in
                await ObservationRelay.wait { store.hasLoaded }
                store.appendSessionNote(text) { StoreRegistry.shared.release(key) }
                Log.write("services: noted \(text.count) characters in \(name)")
            }
        }
    }

    /// Move the files in, then put them on the board — a card each, in the Inbox, as one step ⌘Z can
    /// take back if the board is open. The move itself is not undone by that: the files are where
    /// they were filed.
    private func takeIn(_ files: [URL], projectPath: String, name: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () -> (landed: [URL], canvas: String) in
                let landed = try ProjectIntake.move(files, intoProject: projectPath)
                let canvas = try resolveProjectCanvasPath(projectPath: projectPath)
                    ?? createProjectCanvas(projectPath: projectPath,
                                           notesPath: try resolveNotesPath(projectPath: projectPath))
                return (landed, canvas)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch result {
                    case .failure(let error):
                        Log.write("services: couldn't take files into \(name): \(error)")
                        NSSound.beep()
                    case .success(let (landed, canvas)):
                        let url = URL(fileURLWithPath: canvas)
                        let paths = landed.compactMap { canvasFileCardPath(of: $0, onCanvasAt: url) }
                        ProjectLinksSync.edit(canvasAt: url, named: paths.count == 1 ? "Add File" : "Add Files") { document in
                            for path in paths {
                                CanvasItemPlacement.add(.file(path: path, subpath: nil), to: &document)
                            }
                        }
                        Log.write("services: moved \(landed.count) file(s) into \(name)/\(ProjectIntake.folder)")
                    }
                }
            }
        }
    }
}
