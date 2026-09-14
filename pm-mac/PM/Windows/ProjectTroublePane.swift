import AppKit

/// What a project window says when it has nothing to show, and why.
///
/// Three situations arrive here and they used to be answered by three different things: no project at
/// all got a sentence wearing a task column's chrome, a project that would not load got the same
/// sentence, and a canvas that would not open got the entire old application — a working task list,
/// header and quick add — as a fallback. The asymmetry was not a decision anyone made; it is where the
/// code sat when the column *was* the window.
///
/// It is one pane now, because the three are one thing: the window cannot show you this project, and
/// the only useful thing it can do is say so in a sentence you can act on. The broken canvas is no
/// longer among them — a canvas that will not parse is replaced rather than furnished with a fallback
/// (see `PmLib.replaceUnreadableCanvas`), so what is left here is a vault that cannot be written to,
/// which really is a dead end.
enum ProjectTrouble {
    struct Message: Equatable {
        let title: String
        let detail: String?
    }

    /// - Parameters:
    ///   - hasProject: whether this window is pointed at a project at all.
    ///   - errorMessage: `PMStore.errorMessage` — the project is named but would not load.
    ///   - goToProjectKeys: the keys currently bound to the quick bar's go-to-project, if any.
    static func message(hasProject: Bool, errorMessage: String?,
                        goToProjectKeys: String?) -> Message {
        guard hasProject else {
            // The list beside this pane is already open with the keyboard in it — a window with no
            // project reveals it rather than describing how to reveal it — so this says where you are,
            // and names the key only as the other way there.
            return Message(title: "No project open",
                           detail: goToProjectKeys.map { "Choose one from the list, or press \($0)." }
                               ?? "Choose one from the list.")
        }
        if let errorMessage {
            return Message(title: "Folio couldn't open this project.", detail: errorMessage)
        }
        return Message(title: "Folio couldn't make a canvas for this project.",
                       detail: "Check that the vault is writable, then open the project again.")
    }
}

/// The pane that draws it: two lines, centred, no chrome.
///
/// No header and no tab bar, deliberately. Everything a header offers acts on a board, and there is no
/// board; a window that draws its full furniture around a failure is claiming to be working.
@MainActor
final class ProjectTroublePaneController: NSViewController {
    var message: ProjectTrouble.Message {
        didSet {
            guard message != oldValue, isViewLoaded else { return }
            apply()
        }
    }

    private let headline = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init(message: ProjectTrouble.Message) {
        self.message = message
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView()
        headline.font = .preferredFont(forTextStyle: .subheadline)
        headline.textColor = .secondaryLabelColor
        headline.alignment = .center
        detail.font = .preferredFont(forTextStyle: .caption1)
        detail.textColor = .tertiaryLabelColor
        detail.alignment = .center
        detail.lineBreakMode = .byWordWrapping
        detail.maximumNumberOfLines = 0
        detail.preferredMaxLayoutWidth = 320

        let stack = NSStackView(views: [headline, detail])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            // Above centre rather than on it, which is where a message in an otherwise empty pane
            // wants to sit — dead centre reads as low in a tall window.
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -40),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])
        apply()
    }

    private func apply() {
        headline.stringValue = message.title
        detail.stringValue = message.detail ?? ""
        detail.isHidden = message.detail == nil
    }
}
