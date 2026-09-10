import WebKit
import PmLib

/// Whether a web card's page is allowed to start playing, and whether it is allowed to make a sound.
///
/// **Nothing plays because you looked at it.** A board of embeds is a board of videos, and the page
/// budget starts a card's page when the zoom brings it close enough to read
/// (`CanvasPageBudget`) — so zooming in on a corner of a board started six soundtracks at once, from a
/// gesture that meant "look closer". A tab you opened asked for its page; a card you scrolled past did
/// not, which is the whole difference between a browser and a board.
///
/// So autoplay is **off for every card unless the card says otherwise**, and saying otherwise is the
/// point of this file: a live stream, a match, a dashboard that animates are all real reasons to want
/// a card playing on sight, and the card is where that belongs. Mute is the companion — a card you
/// *do* want playing is usually one you want quiet — and the two are independent because "playing,
/// silently" and "waiting, with sound" are both things people mean.
///
/// **Neither one restarts the card.** You reach for these while something is playing — that is the
/// moment you find out you wanted them — so a toggle that tore the page down and loaded it again
/// would take away the thing you were watching in order to change how you were watching it. Mute is
/// live, through a switch that is injected into every page and can be thrown from here at any time.
/// Autoplay is not live and does not need to be: it decides whether a page may start *by itself*, a
/// question that is only ever asked as a page loads, so it takes effect the next time this card's page
/// does — and in the meantime nothing is snatched away from you.
///
/// **Kept on the node, in the file**, following `CanvasCardSession` and `CanvasCardZoom`: this is
/// something you set on a card, and a card that forgot it every time the window closed would be worse
/// than not offering it. Written only when true, so a board nobody has touched carries nothing.
enum CanvasCardMedia {
    /// The keys PM writes. Prefixed, because a `.canvas` is a shared document.
    static let autoplayKey = "pmAutoplay"
    static let mutedKey = "pmMuted"

    /// Whether this card may start playing on its own.
    static func autoplays(_ node: CanvasNode) -> Bool { flag(autoplayKey, on: node) }

    /// Whether this card is held silent.
    static func isMuted(_ node: CanvasNode) -> Bool { flag(mutedKey, on: node) }

    static func setAutoplay(_ on: Bool, on node: inout CanvasNode) { set(autoplayKey, on, on: &node) }
    static func setMuted(_ on: Bool, on node: inout CanvasNode) { set(mutedKey, on, on: &node) }

    /// Put the mute switch into every page this configuration will show, set to `muted`.
    ///
    /// The switch's opening position has to be baked in here rather than pushed afterwards, or a muted
    /// card would be briefly audible while its page came up. `tell(_:muted:)` moves it after that.
    ///
    /// **Injected whether or not the card is muted**, which is the difference between a switch and a
    /// gag. A script added only to muted cards could never be reached on the card you are watching,
    /// which is the only card anybody mutes — the page would have to be rebuilt to receive it, and
    /// rebuilding is exactly what this is here to avoid. Unmuted it costs a few lines per frame and
    /// observes nothing.
    ///
    /// Called again, after `removeAllUserScripts`, when the setting changes: a user script is fixed
    /// once the page has it, so the live page is told through `tell(_:muted:)` and *the next* page is
    /// told by reinstalling this. See `CanvasLinkNodeView.reinstallScripts`.
    static func installScript(muted: Bool, to configuration: WKWebViewConfiguration) {
        configuration.userContentController.addUserScript(script(muted: muted))
    }

    /// Throw the switch on a page that is already running.
    ///
    /// Only the main frame is addressed, because that is the only frame WebKit hands out for free —
    /// and it is enough: the script relays the message down through the iframes itself. See `script`.
    static func tell(_ web: WKWebView, muted: Bool) {
        web.evaluateJavaScript("window.\(switchName) && window.\(switchName)(\(muted))",
                               completionHandler: nil)
    }

    /// The name the switch goes by on the page's own global object. It has to be a global — a message
    /// arriving in a cross-origin iframe can only be handled by script that frame already has — and a
    /// page could therefore call it. That is not a capability: a page can mute and unmute its own
    /// media whenever it likes, with or without this.
    static let switchName = "__pmMediaMute"

    /// Hold every video and audio element on the page at zero, and keep holding it.
    ///
    /// A script rather than a switch, because WebKit has no public one — `WKWebView` will pause all
    /// media and will tell you what is playing, but muting a page is not something it offers. What is
    /// public is this: at document start, in every frame, override `play` to mute what it is about to
    /// start and sweep whatever the page adds afterwards. Embeds are iframes — a YouTube card is a
    /// page containing a player, not a player — which is why `forMainFrameOnly` is false.
    ///
    /// **Reaching those iframes later is the whole reason for the message plumbing.** A cross-origin
    /// frame cannot be scripted from the app or from its parent; what it can always be sent is a
    /// `postMessage`, so each copy of the script listens for one and passes it on to its own children.
    /// A frame that appears *after* the last toggle would miss the broadcast, so a frame asks its
    /// parent for the current position — but **only once it has media of its own to be wrong about**.
    ///
    /// **A frame with nothing to mute never speaks, and that matters more than it sounds.** This used
    /// to post to its parent unconditionally at document start, which meant PM announced itself to
    /// every iframe on the web: ad slots, comment widgets, and — the reason this changed — an
    /// identity provider's sign-in widget, which uses cross-frame `postMessage` as its own control
    /// channel and was handed ours before it had finished wiring up its own. A handler that assumes a
    /// shape throws on a message shaped like something else; the throw is synchronous and inside
    /// somebody else's listener, so nothing reaches the console and nothing reaches the network, and
    /// it surfaces as a form that quietly refuses to submit. Muting is not worth being audible on a
    /// page that has no sound in it.
    ///
    /// The ask is raised instead by the sweep that finds media and by `play` itself — late enough to
    /// be honest about what the frame is, early enough to be useful. Nothing is lost by waiting: the
    /// opening position is baked into the script, so a frame is already right unless mute was toggled
    /// after its page began, which is the only case the ask was ever for.
    ///
    /// **Only elements this muted are unmuted.** A page that muted its own preview meant it, and
    /// coming off mute should not turn that on. `muted` rather than `volume`, so unmuting does not
    /// have to guess how loud the page wanted to be.
    ///
    /// It is a best effort against a page that is at liberty to unmute itself, and it is honest about
    /// that: a card that insists on being heard is a card to turn autoplay off on.
    static func script(muted: Bool) -> WKUserScript {
        WKUserScript(source: """
        (function () {
          var mine = '__pmMutedByPM'
          var muted = \(muted)
          var observer = null
          var asked = false
          var hush = function (el) {
            try {
              if (muted) { if (!el.muted) { el.muted = true; el[mine] = true } }
              else if (el[mine]) { el[mine] = false; el.muted = false }
            } catch (e) {}
          }
          var ask = function () {
            if (asked || window.parent === window) return
            asked = true
            try { parent.postMessage({ pmMutedAsk: 1 }, '*') } catch (e) {}
          }
          var sweep = function () {
            var media = document.querySelectorAll('video, audio')
            if (media.length) ask()
            for (var i = 0; i < media.length; i++) hush(media[i])
          }
          var apply = function () {
            if (muted && !observer && document.documentElement) {
              observer = new MutationObserver(sweep)
              observer.observe(document.documentElement, { childList: true, subtree: true })
            } else if (!muted && observer) {
              observer.disconnect()
              observer = null
            }
            sweep()
          }
          var relay = function () {
            var frames = document.querySelectorAll('iframe, frame')
            for (var i = 0; i < frames.length; i++) {
              try { frames[i].contentWindow.postMessage({ pmMuted: muted }, '*') } catch (e) {}
            }
          }
          window.\(switchName) = function (on) { muted = !!on; apply(); relay() }
          window.addEventListener('message', function (e) {
            var note = e.data
            if (!note || typeof note !== 'object') return
            if (typeof note.pmMuted === 'boolean') { window.\(switchName)(note.pmMuted) }
            else if (note.pmMutedAsk) {
              try { e.source.postMessage({ pmMuted: muted }, '*') } catch (err) {}
            }
          }, false)
          var proto = window.HTMLMediaElement && HTMLMediaElement.prototype
          if (proto && proto.play) {
            var play = proto.play
            proto.play = function () { ask(); hush(this); return play.apply(this, arguments) }
          }
          document.addEventListener('play', function (e) { ask(); hush(e.target) }, true)
          apply()
          document.addEventListener('DOMContentLoaded', apply)
        })()
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    /// What the menu calls these, given how many cards it is about to act on.
    static func autoplayTitle(_ count: Int) -> String {
        count > 1 ? "Autoplay Media on \(count) Cards" : "Autoplay Media"
    }

    static func muteTitle(_ count: Int) -> String {
        count > 1 ? "Mute \(count) Cards" : "Mute"
    }

    private static func flag(_ key: String, on node: CanvasNode) -> Bool {
        if case .bool(let on)? = node.extra[key] { return on }
        return false
    }

    /// False is written as the *absence* of the key, so a card switched on and off again leaves the
    /// file exactly as it found it.
    private static func set(_ key: String, _ on: Bool, on node: inout CanvasNode) {
        node.extra[key] = on ? .bool(true) : nil
    }
}
