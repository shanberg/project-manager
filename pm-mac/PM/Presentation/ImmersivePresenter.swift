import AppKit
import SwiftUI

/// A screen-filling surface that blacks out everything else and holds one thing at a time.
///
/// Deliberately not a feature of any one editor. What it does — dim every display, centre a piece of
/// content on the one you're looking at, bring it up out of focus and slightly oversized and let it
/// settle — is a *presentation*, and PM has more than one surface that might want it. So the presenter
/// takes an `AnyView` and knows nothing else about its tenant.
///
/// Why a full-screen window rather than growing the panel that summoned it: content that starts larger
/// than its resting size cannot animate inside a window sized to that content. The quick bar's panel is
/// measured to its own height every frame (`QuickBarController.fit`), so a 1.04× first frame would be
/// clipped by the window it lives in — and a blur samples *outside* the content's bounds, so it would
/// be cut off at the edges too. A window the size of the screen has slack in every direction, needs no
/// frame animation at all, and doesn't drag a stale `invalidateShadow` outline through the transition.
///
/// It also sidesteps the summon race the quick bar documents at `animationBehavior = .none`: the window
/// arrives at full size and full alpha with its *content* in the start state, so key focus is taken on
/// a window that is already finished being composed. Nothing about the animation touches the window.
@MainActor
final class ImmersivePresenter: NSObject, NSWindowDelegate {
    static let shared = ImmersivePresenter()

    private var panel: KeyablePanel?
    private var hosting: NSHostingController<ImmersiveStage>?
    private let model = ImmersiveStageModel()
    /// The scrim for every display *except* the one the content is on — that one is dimmed inside the
    /// stage, so its darkening and the content's settle share a transaction.
    private let dimmer = ScreenDimmer(level: ImmersivePresenter.dimLevel)
    /// A fade-out with a window still to order out. Held so a re-present can cancel it rather than
    /// have the old dismissal tear down the new surface a moment after it appears.
    private var pendingTeardown: DispatchWorkItem?

    private override init() { super.init() }

    private(set) var isPresenting = false

    /// Above the menu bar and the Dock, below a contextual menu.
    ///
    /// `.floating` — where the quick bar and the focus panel live — is below the menu bar, and a
    /// full-screen writing surface with the clock and the menu titles still showing across the top has
    /// blacked out everything except the part of the screen you look at most. So: one above `.mainMenu`
    /// for the scrim and two for the content. Not `.screenSaver`, which is above notification banners
    /// and everything else the system puts up — this mode wants the screen, not the machine.
    ///
    /// Staying below `.popUpMenu` is what keeps our own right-click menus and completion lists visible
    /// over the surface.
    private static let dimLevel = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
    private static let contentLevel = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)

    // MARK: Presenting

    /// Put `content` on screen. Called again while presenting, it swaps the content without replaying
    /// the transition — the surface is already here.
    ///
    /// `onBackdropClick` is what a click outside the content means. The presenter has no opinion: for
    /// the note surface it means "back to the small bar", which loses nothing, but a tenant that wanted
    /// a click outside to commit or to do nothing is equally entitled.
    func present<Content: View>(_ content: Content,
                                tuning: ImmersiveTuning = .standard,
                                onBackdropClick: @escaping () -> Void = {}) {
        pendingTeardown?.cancel()
        pendingTeardown = nil
        model.content = AnyView(content)
        model.tuning = tuning
        model.onBackdropClick = onBackdropClick

        guard !isPresenting else { return }
        isPresenting = true

        let screen = activeScreen()
        let panel = ensurePanel()
        place(panel, on: screen)

        // The start state is set outside any animation, so the first frame drawn is genuinely the
        // blurred, oversized one. Setting it inside the same transaction as the target would animate
        // from wherever the last presentation left it — which is "settled", i.e. no transition at all.
        model.presented = false
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        panel.takeKey()

        // Every other display, on the scrim's curve — these are scrim, so they take the scrim's
        // deadline rather than the content's. Not the same transaction as the stage's own dim (they're
        // windows, not views), but the same curve and the same start, and a few milliseconds of
        // disagreement on a monitor you aren't looking at is not a thing anyone can see.
        dimmer.show(strength: tuning.dim, duration: tuning.scrimIn, excluding: screen)

        // After the start state has been drawn. Inside the same turn of the run loop SwiftUI coalesces
        // the two assignments and there is nothing to animate *from*. The curves live on the stage's
        // own views — scrim and content take different ones — so this only flips the flag.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isPresenting else { return }
            self.model.presented = true
        }
        Log.write("immersive surface presented on \(screen?.localizedName ?? "the main screen") dim=\(tuning.dim) blur=\(tuning.backdropBlur.rawValue)")
    }

    /// Animate out, then put the window away. `completion` runs when the surface is gone — which is
    /// when whatever summoned it should be showing itself again, so that the two don't overlap.
    func dismiss(completion: (() -> Void)? = nil) {
        guard isPresenting else {
            completion?()
            return
        }
        isPresenting = false
        model.presented = false
        dimmer.hide(duration: model.tuning.scrimOut)

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingTeardown = nil
            // Only if nothing has re-presented in the meantime.
            guard !self.isPresenting else { return }
            self.panel?.acceptsKey = false
            self.panel?.orderOut(nil)
            // Dropped so a surface that is gone isn't holding its tenant's view — and its model — alive.
            self.model.content = AnyView(EmptyView())
            self.model.onBackdropClick = {}
            Log.write("immersive surface dismissed")
            completion?()
        }
        pendingTeardown = work
        DispatchQueue.main.asyncAfter(deadline: .now() + model.tuning.outDuration, execute: work)
    }

    // MARK: Window

    private func ensurePanel() -> KeyablePanel {
        if let panel { return panel }
        let panel = KeyablePanel(contentRect: NSScreen.main?.frame ?? .zero,
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.tabbingMode = .disallowed
        panel.level = Self.contentLevel
        // The quick bar's own set, exactly. This window takes the keyboard and hosts an editor, so it
        // wants to behave like the app's other floating surfaces rather than like a backdrop — the
        // scrim windows are the ones that get `.stationary`.
        panel.collectionBehavior = [.ignoresCycle, .canJoinAllSpaces, .fullScreenAuxiliary]
        // The same reason the quick bar gives: an implicit window fade completes *after* the `takeKey`
        // that follows it and can drop the key status it was just granted. Everything this surface
        // animates is in the content anyway.
        panel.animationBehavior = .none
        // Stated on the window as well as in the stage. SwiftUI's `preferredColorScheme` is what the
        // views read; an AppKit view hosted inside them — the note's `NSTextView` — resolves its
        // `labelColor` against the window's `effectiveAppearance`, so the two have to agree or the
        // prose comes out in the system's colour on the scrim's ground.
        panel.appearance = NSAppearance(named: .darkAqua)

        let hosting = NSHostingController(rootView: ImmersiveStage(model: model))
        hosting.sizingOptions = []
        panel.contentViewController = hosting
        self.hosting = hosting
        self.panel = panel
        return panel
    }

    /// Fill the screen — `frame`, not `visibleFrame`. The menu bar and the Dock are exactly what this
    /// mode exists to cover; stopping short of them would leave the two brightest strips on the display
    /// undimmed.
    private func place(_ panel: NSPanel, on screen: NSScreen?) {
        guard let screen else { return }
        panel.setFrame(screen.frame, display: false)
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    /// Whichever screen the pointer is on — the one being looked at, and the same answer the quick bar
    /// gives for where to put itself.
    private func activeScreen() -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    }

    // MARK: NSWindowDelegate

    /// Losing the keyboard does *not* take this surface down.
    ///
    /// The same rule the quick bar keeps for a note in progress, and for the same reason: what's on
    /// screen is prose nobody has written down anywhere else yet, and a click that might have been a
    /// scroll must not be able to throw half a page away. `acceptsKey` stays set so clicking back into
    /// the surface picks the keyboard up again rather than finding a window that refuses to be typed
    /// into. The tenant's own draft-saving is what makes this safe rather than merely convenient.
    func windowDidResignKey(_ notification: Notification) {}
}
