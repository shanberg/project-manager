import Foundation

public func parseProjectNumbers(folderNames: [String], domainCode: String) throws -> (numbers: [Int], observedMinDigits: Int) {
    var numbers: [Int] = []
    var observedMinDigits = 0
    let escaped = NSRegularExpression.escapedPattern(for: domainCode)
    let pattern = "^\(escaped)-(\\d+)\\s+.+$"
    let re: NSRegularExpression
    do {
        re = try NSRegularExpression(pattern: pattern)
    } catch {
        throw PmError.invalidRegex(pattern: pattern)
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
        guard let entries = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
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
