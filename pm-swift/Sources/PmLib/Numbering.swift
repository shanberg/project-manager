import Foundation

/// Build the project-folder regex pattern for a domain code. Internal for testing invalid-pattern error.
internal func buildProjectNumberPattern(domainCode: String) -> String {
    let escaped = NSRegularExpression.escapedPattern(for: domainCode)
    return "^\(escaped)-(\\d+)\\s+.+$"
}

/// Extract project numbers and observed padding from folder names matching domain. Throws if the pattern for domainCode is invalid.
public func parseProjectNumbers(folderNames: [String], domainCode: String) throws -> (numbers: [Int], observedMinDigits: Int) {
    let pattern = buildProjectNumberPattern(domainCode: domainCode)
    return try parseProjectNumbersWithPattern(folderNames: folderNames, pattern: pattern)
}

/// Internal overload for testing: pass a raw pattern to trigger invalidProjectPattern when pattern is invalid.
internal func parseProjectNumbersWithPattern(folderNames: [String], pattern: String) throws -> (numbers: [Int], observedMinDigits: Int) {
    var numbers: [Int] = []
    var observedMinDigits = 0
    let re: NSRegularExpression
    do {
        re = try NSRegularExpression(pattern: pattern)
    } catch {
        throw PmError.invalidProjectPattern(pattern: pattern)
    }
    for name in folderNames {
        guard let match = re.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let numRange = Range(match.range(at: 1), in: name) else { continue }
        let numStr = String(name[numRange])
        if let num = Int(numStr) {
            numbers.append(num)
            observedMinDigits = max(observedMinDigits, numStr.count)
        }
    }
    return (numbers, observedMinDigits)
}

public func nextNumberAndPadding(existingNumbers: [Int], observedMinDigits: Int) -> (nextNumber: Int, formatted: String) {
    let nextNumber = existingNumbers.isEmpty ? 1 : (existingNumbers.max() ?? 0) + 1
    let requiredDigits = String(nextNumber).count
    let padTo = max(observedMinDigits, requiredDigits)
    let formatted = String(format: "%0\(padTo)d", nextNumber)
    return (nextNumber, formatted)
}

public func getNextFormattedNumber(activePath: String, archivePath: String, domainCode: String) throws -> String {
    var allNames: [String] = []
    let fm = FileManager.default
    for basePath in [activePath, archivePath] {
        let url = URL(fileURLWithPath: basePath)
        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        } catch {
            let message = (error as NSError).localizedDescription
            throw PmError.cannotListDirectory(path: basePath, message: message)
        }
        for e in entries {
            if (try? e.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                allNames.append(e.lastPathComponent)
            }
        }
    }
    let (numbers, observedMinDigits) = try parseProjectNumbers(folderNames: allNames, domainCode: domainCode)
    let (_, formatted) = nextNumberAndPadding(existingNumbers: numbers, observedMinDigits: observedMinDigits)
    return formatted
}
