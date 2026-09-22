import Foundation
import PmLib

/// `pm card` — a project's board, read and added to from the command line (docs/items.md D9).
///
/// **The simplest form of the whole ask.** Putting a link in a project should not mean opening a
/// window, finding empty space on a board and deciding how big the card is. Here it is a line:
///
/// ```
/// pm card add https://jsoncanvas.org --project Acme
/// pm card add "Ask legal about the DPA" --frame Reference
/// pm card list
/// ```
///
/// Both are adapters over the contract, as every `pm` command is — `pm api call card.list` is the same
/// answer as JSON, and a model over MCP reaches the same two actions.
func runCard(args: [String]) {
    let usage = """
    Usage: pm card list [--project NAME] [--frame LABEL] [--sort reading|file|name|kind]
           pm card add <address or text> [--project NAME] [--frame LABEL]
    """
    guard let sub = args.first else {
        stderr(usage)
        exit(1)
    }
    switch sub {
    case "list": runCardList(args: Array(args.dropFirst()), usage: usage)
    case "add": runCardAdd(args: Array(args.dropFirst()), usage: usage)
    default:
        stderr(usage)
        exit(1)
    }
}

private func runCardList(args: [String], usage: String) {
    var input = ApiInput()
    var ignored: [String]?
    guard parseCardOptions(args, into: &input, allowingSort: true, rest: &ignored) else {
        stderr(usage)
        exit(1)
    }
    do {
        let result = try performApi("card.list", input, options: ApiOptions(source: "cli"))
        guard case .object(let data)? = result.data,
              case .array(let sections)? = data["sections"] else { return }
        if sections.isEmpty { print("Nothing on this board yet.") }
        for section in sections {
            guard case .object(let group) = section, case .array(let items)? = group["items"] else { continue }
            if case .string(let label)? = group["frame"] { print("\n\(label)") }
            for item in items {
                guard case .object(let card) = item,
                      case .string(let title)? = card["title"],
                      case .string(let kind)? = card["kind"] else { continue }
                // The kind in a column of its own: a list of titles alone can't tell a note about a
                // page from the page.
                print("  \(kind.padding(toLength: 5, withPad: " ", startingAt: 0))  \(title)")
            }
        }
    } catch {
        stderr(String(describing: error))
        exit(1)
    }
}

private func runCardAdd(args: [String], usage: String) {
    var input = ApiInput()
    var text: [String]? = []
    guard parseCardOptions(args, into: &input, allowingSort: false, rest: &text),
          let text, !text.isEmpty else {
        stderr(usage)
        exit(1)
    }
    input.text = text.joined(separator: " ")
    do {
        let result = try performApi("card.add", input,
                                    options: ApiOptions(dryRun: args.contains("--dry-run"), source: "cli"))
        print(result.summary)
    } catch {
        stderr(String(describing: error))
        exit(1)
    }
}

/// `--project`, `--frame`, `--sort`, and whatever is left over as the card's text.
private func parseCardOptions(_ args: [String], into input: inout ApiInput,
                              allowingSort: Bool, rest: inout [String]?) -> Bool {
    var index = 0
    while index < args.count {
        let argument = args[index]
        func value() -> String? {
            index += 1
            return index < args.count ? args[index] : nil
        }
        switch argument {
        case "--project":
            guard let given = value() else { return false }
            input.project = given
        case "--frame":
            guard let given = value() else { return false }
            input.frame = given
        case "--sort" where allowingSort:
            guard let given = value(), CanvasItemSort(rawValue: given) != nil else { return false }
            input.sort = given
        case "--dry-run":
            break
        default:
            guard rest != nil, !argument.hasPrefix("--") else { return false }
            rest?.append(argument)
        }
        index += 1
    }
    return true
}
