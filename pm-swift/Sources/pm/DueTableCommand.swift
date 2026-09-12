import Foundation
import PmLib

/// Emit the due-label conformance table as JSON, for the Raycast extension's fixture.
///
/// Not a contract action. `pm api describe` publishes what clients build against; this is a test
/// affordance for one client's copy of one rendering rule, and putting it in the manifest would
/// suggest it is part of the interface. See `RelativeDue.conformanceTable` for why that copy exists.
///
/// Written by hand rather than through `JSONSerialization.prettyPrinted`, which on Apple platforms
/// emits `"days" : -29` — a space before the colon that Prettier then reformats. The fixture lives in
/// a linted package, so a generator whose output fails that package's lint is a generator nobody can
/// run without a second step they will forget.
func runDueTable() {
    let rows = RelativeDue.conformanceTable().map { row in
        "  {\n    \"days\": \(row.days),\n    \"label\": \"\(row.label)\"\n  }"
    }
    print("[\n" + rows.joined(separator: ",\n") + "\n]")
}
