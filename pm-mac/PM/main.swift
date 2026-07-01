import AppKit

// Explicit entry point (no @main) so the AppKit agent app starts as an accessory: menubar only,
// no Dock icon, no default window. The delegate builds the status item, panel, hotkey, and watcher.
// Top-level code is nonisolated, so hop onto the main actor to build the main-actor-isolated delegate;
// `app.run()` blocks here for the app's lifetime, keeping `delegate` retained (NSApp.delegate is weak).
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
