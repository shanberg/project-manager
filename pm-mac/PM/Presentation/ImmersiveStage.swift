import AppKit
import SwiftUI

/// The ground the note sits on, named from the system palette rather than mixed by hand.
///
/// A dark grey from the palette rather than black: black is a colour nothing else in the app uses, and
/// against it the note's own `labelColor` white is the highest contrast the screen can make — which
/// reads as harsh over a page of prose. These all resolve dark, because the stage forces a dark
/// appearance on itself and its window.
enum ImmersiveGround: String, CaseIterable, Identifiable {
    case windowBackground, underPageBackground, controlBackground, textBackground, black
    var id: String { rawValue }

    var nsColor: NSColor {
        switch self {
        case .windowBackground: return .windowBackgroundColor
        case .underPageBackground: return .underPageBackgroundColor
        case .controlBackground: return .controlBackgroundColor
        case .textBackground: return .textBackgroundColor
        case .black: return .black
        }
    }

    var label: String {
        switch self {
        case .windowBackground: return "Window background"
        case .underPageBackground: return "Under page"
        case .controlBackground: return "Control background"
        case .textBackground: return "Text background"
        case .black: return "Black"
        }
    }
}

/// How much of what's behind the surface is blurred through it.
///
/// `NSVisualEffectView` in `.behindWindow` mode is the only way to blur arbitrary other applications —
/// there is no radius to set, so the choice is a material and the material decides. Everything else
/// that could blur a desktop needs a screen recording of it.
enum ImmersiveBackdropBlur: String, CaseIterable, Identifiable {
    case none, fullScreenUI, hudWindow, underPageBackground, popover
    var id: String { rawValue }

    var material: NSVisualEffectView.Material? {
        switch self {
        case .none: return nil
        case .fullScreenUI: return .fullScreenUI
        case .hudWindow: return .hudWindow
        case .underPageBackground: return .underPageBackground
        case .popover: return .popover
        }
    }

    var label: String { self == .none ? "No blur" : rawValue }
}

/// The numbers and choices the presentation is made of.
///
/// A value rather than a set of constants, for one reason: these are the kind of numbers nobody gets
/// right by reasoning, and a rebuild per attempt is the difference between dialling them in and
/// settling for the first plausible set. The app always uses `.standard`; the tuning harness hands the
/// stage a different one off a row of sliders. There is exactly one production value and it is the
/// default, so nothing here is a knob a user can find.
struct ImmersiveTuning: Equatable {
    /// The scrim and the content start together and needn't finish together. Concealing the desktop
    /// and focusing on the note are two jobs with two deadlines, and which one should lead is a
    /// question about how it *looks*, which is why these are tuned rather than argued.
    var scrimIn: TimeInterval
    var contentIn: TimeInterval
    var contentOut: TimeInterval
    var scrimOut: TimeInterval

    /// Where the content starts — slightly *larger* than its resting size, so it settles inward as it
    /// sharpens. Coming up from smaller reads as a thing being pushed toward you; coming down from
    /// larger reads as a lens finding focus, which is what this mode is about.
    var startScale: CGFloat
    /// Enough blur to be unmistakably out of focus at the start without turning the first frame into a
    /// smear. Measured against the note's own type.
    var startBlur: CGFloat

    /// How opaque the ground is over whatever is behind it.
    ///
    /// This and `backdropBlur` trade against each other, and the trade is real rather than a matter of
    /// taste: at 0.9 the ground is all but solid and no amount of blur behind it is visible. A surface
    /// that wants its blur seen has to let some of the desktop through to be blurred.
    var dim: Double
    var ground: ImmersiveGround
    var backdropBlur: ImmersiveBackdropBlur

    /// Where the top edge of the content sits, as a fraction of the screen's height.
    ///
    /// Not centred, and not by accident. A block centred by its middle puts short content high and long
    /// content low, so the first line you read moves depending on how much you wrote last time — and
    /// the first line is the one thing that should be in the same place every time you summon this. So
    /// the *top* is anchored and the prose grows downward from it, which also leaves the upper part of
    /// the screen as quiet ground rather than as a margin that happens to be there.
    /// Where the top edge of the content would like to sit, as a fraction of the screen's height.
    ///
    /// A *starting* position, not a margin. The stage states it and the tenant honours it as far as its
    /// own content allows: a short note sits at this eyeline, a long one grows past it and uses the
    /// whole screen. Imposed as a fixed offset instead — which is how this began — it became a band at
    /// the top of the screen the prose could never enter however much of it there was.
    var contentTopFraction: CGFloat

    /// How far the prose fades out at the top and bottom edges of its scrolling region. Zero turns it
    /// off entirely.
    ///
    /// It has to be paid for twice, which is the whole subtlety: the same distance is also added to the
    /// text container's inset at both ends, so that at rest the first line sits *below* the fade and
    /// the last line above it. Without that the fade would be over the text rather than over the space
    /// text scrolls through, and a note you hadn't scrolled would open with its first line half gone.
    var edgeFade: CGFloat

    static let standard = ImmersiveTuning(scrimIn: 0.20, contentIn: 0.20,
                                          contentOut: 0.20, scrimOut: 0.10,
                                          startScale: 1.05, startBlur: 15,
                                          dim: 0.45, ground: .textBackground,
                                          backdropBlur: .fullScreenUI,
                                          contentTopFraction: 0.35, edgeFade: 28)

    func scrimCurve(presented: Bool) -> Animation {
        presented ? .easeOut(duration: scrimIn) : .easeIn(duration: scrimOut)
    }

    func contentCurve(presented: Bool) -> Animation {
        presented ? .easeOut(duration: contentIn) : .easeIn(duration: contentOut)
    }

    /// How long the whole thing takes to leave, for a caller sequencing anything after it.
    var outDuration: TimeInterval { max(scrimOut, contentOut) }

    /// A paste-ready literal, for the harness to print once the numbers are right.
    var literal: String {
        String(format: """
        ImmersiveTuning(scrimIn: %.2f, contentIn: %.2f,
                        contentOut: %.2f, scrimOut: %.2f,
                        startScale: %.2f, startBlur: %.0f,
                        dim: %.2f, ground: .%@,
                        backdropBlur: .%@,
                        contentTopFraction: %.2f, edgeFade: %.0f)
        """, scrimIn, contentIn, contentOut, scrimOut, startScale, startBlur,
             dim, ground.rawValue, backdropBlur.rawValue, contentTopFraction, edgeFade)
    }
}

/// The presentation's tuning, offered to whatever is being presented.
///
/// Passed down rather than read off a shared constant: the stage owns *where on the screen* a thing is
/// presented and how it's framed, but only the tenant knows how tall it wants to be, and the two have
/// to be resolved together. So the stage states its preferences and the tenant honours the ones it
/// understands. A tenant with nothing to say about its own height can ignore all of this and fill.
private struct ImmersiveTuningKey: EnvironmentKey {
    static let defaultValue: ImmersiveTuning = .standard
}

extension EnvironmentValues {
    var immersiveTuning: ImmersiveTuning {
        get { self[ImmersiveTuningKey.self] }
        set { self[ImmersiveTuningKey.self] = newValue }
    }
}

enum ImmersiveTransition {
    /// Reduce Motion turns the whole thing into a cross-fade. Scale and blur are the motion; the
    /// dissolve isn't, and taking that away too would mean a surface that blinks into being, which is
    /// harder to follow rather than easier.
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

/// The desktop, blurred, through the window.
///
/// `.behindWindow` blending is what makes this blur *other applications* rather than the view's own
/// contents — the window server does it, so it costs nothing and needs no screen-recording grant. It
/// has no radius: the material is the whole choice. It's faded in by opacity, since a material can't
/// be animated any other way.
private struct BackdropBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = material
        // `.active` rather than `.followsWindowActiveState`: this window is a non-activating panel and
        // often isn't the active one by AppKit's reckoning even while you're typing into it. Left to
        // follow, the blur drops out from under the note at exactly the wrong moments.
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        if view.material != material { view.material = material }
    }
}

/// What the presenter's window draws: a ground, and one piece of content placed on it.
///
/// The stage knows nothing about what it's showing. That's the point — which surface this eventually
/// belongs to is still open, and a presenter that named its tenant would have to be rewritten to
/// answer it.
@MainActor
final class ImmersiveStageModel: ObservableObject {
    /// The transition's one variable. Everything the stage animates reads off this.
    @Published var presented = false
    @Published var content: AnyView = AnyView(EmptyView())
    /// `.standard` everywhere but the tuning harness.
    @Published var tuning: ImmersiveTuning = .standard
    /// Called when a click lands on the ground rather than on the content.
    var onBackdropClick: () -> Void = {}
}

struct ImmersiveStage: View {
    @ObservedObject var model: ImmersiveStageModel

    /// Read once per body rather than per modifier: a setting that changed halfway through the
    /// transition would leave the scale and the blur disagreeing about which transition they're part of.
    private var reduceMotion: Bool { ImmersiveTransition.reduceMotion }

    var body: some View {
        ZStack {
            backdrop
            model.content
                // All three on one layer, which is what keeps them in step with each other. Blur first
                // so the scale operates on the blurred result rather than the other way round —
                // scaling a sharp image and then blurring it gives a blur whose radius changes with
                // the scale.
                .blur(radius: blurRadius)
                .scaleEffect(scale)
                .opacity(model.presented ? 1 : 0)
                .animation(model.tuning.contentCurve(presented: model.presented),
                           value: model.presented)
                // The content gets the whole screen and places itself within it. The stage can't do
                // the placing: where the top edge should land depends on how tall the content wants to
                // be, which only the content knows.
                .environment(\.immersiveTuning, model.tuning)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Dark, whatever the app's colour mode says — and this is not the app ignoring a preference.
        // The ground is a dark system colour by construction, so there is no light version of this
        // surface to have a preference *about*: in Light mode the note would have been near-black text
        // on near-black. The window carries the same appearance, which is what makes the `NSTextView`
        // inside the editor resolve `labelColor` to a legible one.
        .preferredColorScheme(.dark)
        .ignoresSafeArea()
    }

    /// The blur and the ground over it, on one curve, with the click target on top of both.
    private var backdrop: some View {
        ZStack {
            if let material = model.tuning.backdropBlur.material {
                BackdropBlur(material: material)
            }
            Color(nsColor: model.tuning.ground.nsColor)
                .opacity(ScreenDimSettings.honouringAccessibility(model.tuning.dim))
        }
        .opacity(model.presented ? 1 : 0)
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { model.onBackdropClick() }
        .animation(model.tuning.scrimCurve(presented: model.presented), value: model.presented)
    }

    private var blurRadius: CGFloat {
        guard !reduceMotion else { return 0 }
        return model.presented ? 0 : model.tuning.startBlur
    }

    private var scale: CGFloat {
        guard !reduceMotion else { return 1 }
        return model.presented ? 1 : model.tuning.startScale
    }
}
