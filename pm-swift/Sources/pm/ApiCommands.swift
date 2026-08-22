import Foundation
import PmLib

// MARK: - `pm api`
//
// The argv adapter over the dispatcher. It does transport and nothing else: decode JSON, call
// `performApi`, encode the envelope. Every rule about what an action takes, what it returns and
// whether it may be called headless lives in the registry, not here — which is what stops this
// adapter and the manifest it publishes from drifting apart.

private func emit(_ value: JSONValue, pretty: Bool) {
    var formatting: JSONEncoder.OutputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    if pretty { formatting.insert(.prettyPrinted) }
    let encoder = JSONEncoder()
    encoder.outputFormatting = formatting
    guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
        stderr("Failed to encode result as JSON.")
        exit(1)
    }
    print(text)
}

/// `pm api describe` — the manifest a client generates its tool list, flags, or typed client from.
private func runApiDescribe(pretty: Bool) {
    emit(apiManifest(), pretty: pretty)
}

/// `pm api call <action> [json]` — JSON on argv or, with no argument, on stdin.
private func runApiCall(args: [String], pretty: Bool, dryRun: Bool) {
    guard let action = args.first else {
        stderr("Usage: pm api call <action> [json]  (input may also arrive on stdin)")
        exit(1)
    }
    let raw: String
    if args.count > 1 {
        raw = args[1]
    } else if isatty(FileHandle.standardInput.fileDescriptor) == 0 {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        raw = String(data: data, encoding: .utf8) ?? "{}"
    } else {
        raw = "{}"
    }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let input: ApiInput
    do {
        input = trimmed.isEmpty
            ? ApiInput()
            : try JSONDecoder().decode(ApiInput.self, from: Data(trimmed.utf8))
    } catch {
        emit(.object(["error": .object([
            "code": .string("invalidField"),
            "message": .string("Input isn't valid JSON for this action: \(error.localizedDescription)"),
        ])]), pretty: pretty)
        exit(1)
    }
    do {
        let result = try performApi(action, input, options: ApiOptions(dryRun: dryRun))
        emit(try JSONValue.encoding(result), pretty: pretty)
    } catch {
        let apiError = ApiError.from(error)
        emit(.object(["error": (try? JSONValue.encoding(apiError)) ?? .string(apiError.message)]),
             pretty: pretty)
        exit(1)
    }
}

func runApi(args: [String]) {
    let pretty = args.contains("--pretty")
    let dryRun = args.contains("--dry-run")
    let rest = args.filter { $0 != "--pretty" && $0 != "--dry-run" }
    guard let sub = rest.first else {
        stderr("Usage: pm api <describe|call> [--pretty] [--dry-run]")
        exit(1)
    }
    switch sub {
    case "describe":
        runApiDescribe(pretty: pretty)
    case "call":
        runApiCall(args: Array(rest.dropFirst()), pretty: pretty, dryRun: dryRun)
    default:
        stderr("Usage: pm api <describe|call> [--pretty] [--dry-run]")
        exit(1)
    }
}
