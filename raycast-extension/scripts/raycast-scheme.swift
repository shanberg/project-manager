// Query or set the default handler for the `raycast://` URL scheme.
//   no args        -> prints the current handler's bundle id (or "none")
//   <bundle-id>    -> sets the handler to <bundle-id>, prints the new handler
//
// `ray develop` opens the extension via a `raycast://…` deep-link, which macOS
// routes to whichever app owns the scheme by default. Raycast Beta and release
// both register `raycast://`, so the target must be pinned explicitly.
import CoreServices
import Foundation

let scheme = "raycast" as CFString

func current() -> String {
    (LSCopyDefaultHandlerForURLScheme(scheme)?.takeRetainedValue() as String?) ?? "none"
}

if CommandLine.arguments.count > 1 {
    let target = CommandLine.arguments[1] as CFString
    let status = LSSetDefaultHandlerForURLScheme(scheme, target)
    if status != 0 {
        FileHandle.standardError.write("failed to set handler (status \(status))\n".data(using: .utf8)!)
        exit(1)
    }
}
print(current())
