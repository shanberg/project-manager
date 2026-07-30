import AppKit

// Explicit entry point (no @main). PM is a regular app — Dock icon, menu bar, windows — that also
// keeps a menubar item; the delegate builds the status item, the windows, the hotkey and the watcher.
// Top-level code is nonisolated, so hop onto the main actor to build the main-actor-isolated delegate;
// `app.run()` blocks here for the app's lifetime, keeping `delegate` retained (NSApp.delegate is weak).
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
