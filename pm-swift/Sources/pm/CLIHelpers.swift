import Foundation
import PmLib

func stderr(_ msg: String) {
    fputs(msg + "\n", stderr)
}

func fail(_ err: Error) -> Never {
    if let pmErr = err as? PmError {
        stderr(pmErr.description)
    } else {
        stderr("\(err.localizedDescription) (\(String(describing: err)))")
    }
    exit(1)
}
