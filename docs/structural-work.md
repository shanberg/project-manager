# Structural work

Findings from a critical read of the codebase on 2026-09-12, and the state of the work on each. This
is a working document: an item's **Status** is the truth about it, and an item that lands gets its
reasoning left behind rather than deleted, because the next person to look at that code will have the
same question that made it worth changing.

Ordered by leverage, not by severity. The first four are small changes that unblock or remove a whole
class of problem; the last two are large and want scheduling rather than opportunism.

**Discipline for each item:** verify the finding against the code before changing anything, get a test
that fails for the stated reason, fix, watch it pass, then run the suites that could plausibly have
noticed. An item is not done because the edit is written.

**Where it stands, 2026-09-12.** Items 0–6 are done — item 6 in part, and deliberately — and the dead
root scaffolding is gone. Every suite green:

| Suite | Before | After items 0–4 | Now |
|---|---|---|---|
| `pm-swift` | 722 | 735 | 745 |
| `PMViewTests` | 705 | 733 | 808 |
| Raycast | 55 | 116 | 116 |

Six claims in this document turned out **wrong, and are corrected in place below** — item 2's
premise about the config seam; item 1's claim that both main-queue hops were redundant; item 6's guess
that `CanvasBoardView+Commands` is one command table; the watcher finding's "mtime misses same-second
changes"; and, from a later pass, my own call that `validateUserInterfaceItem` was the best next
extraction; and "every write reads the whole file three times", which was right about the waste and wrong
about where it goes. The StoreRegistry finding was right that something could fail silently and wrong
about what.
Every one was caught by checking before editing, which is the argument for the discipline.

**Nothing is committed**, and several of these edits land in files that were already carrying in-flight
header-chrome work: `CanvasHeader`, `CanvasPageCapsule`, `CanvasTileCapsule` and `CanvasPaneController`
(item 5), `CanvasLinkNodeView` (item 6), and `project.pbxproj` (both). Worth reviewing those diffs as
two stories rather than one.

---

## 0. A baseline to measure against

**Status:** done, 2026-09-12. Everything green before any edit.

Nothing below is safe to trust without knowing what the tree did *before* it was touched. The working
tree is not clean — there is in-flight header-chrome work and an untracked
[CanvasPageLoad.swift](../pm-mac/PM/Canvas/CanvasPageLoad.swift) — so a failure found after an edit
has to be attributable to the edit rather than to what was already there.

| Suite | How | Baseline |
|---|---|---|
| `pm-swift` | `swift build && swift test` | 722 tests, 0 failures, 2 skipped |
| PM app build | `xcodebuild -scheme PM -destination 'platform=macOS,arch=arm64' build` | succeeds |
| `PMViewTests` | `xcodebuild -scheme PM -destination 'platform=macOS,arch=arm64' test` | 705 tests, 0 failures |
| Raycast | `cd raycast-extension && npm test` | 55 tests across 6 files, 0 failures |

Two things worth not rediscovering. **There is no `PMViewTests` scheme** — the target exists but the
schemes are `pm`, `PM` and `PmLib`, so the view tests run through the `PM` scheme's test action;
asking for `-scheme PMViewTests` fails with "does not contain a scheme". And the destination wants
pinning to `platform=macOS,arch=arm64`, because an attached locked iOS device otherwise stalls
`xcodebuild` indefinitely.

---

## 1. Coalesce `storeDidChange`

**Status:** done, 2026-09-12. Measured in the running app: launch went from 60 passes to 3, and one
external edit from 15 to 2.

One reload fired a full change-notification pass per property.

[PMStore.reload](../pm-mac/PM/Model/PMStore.swift) assigns fourteen `@Published` properties in
sequence — `projectKey`, `projectName`, `notesPath`, `projectPath`, `notes`, `icon`, `todos`,
`lastEditedAt`, `focusedKey`, `errorMessage`, `hasLoaded` among them. `ObservableObject` fires
`objectWillChange` on every one. [AppDelegate](../pm-mac/PM/AppDelegate.swift) subscribed to that
publisher and ran `storeDidChange()` for each: notifier sync, quick-bar refresh, window title
refresh, access-help check, a sorted-array comparison.

Then `handleExternalChange()` calls `reloadAllStores()`, which reloads *every* live store rather than
the one whose file changed — so the count multiplies by the number of open windows.

### One of the two hops was load-bearing, which is worth knowing before touching it

The subscription took two main-queue hops: `.receive(on: DispatchQueue.main)` and then an inner
`DispatchQueue.main.async`. The obvious reading is that both are redundant on a `@MainActor` class.
That reading is half wrong, and a scratch program settled it before anything was edited:

    during willSet: ["raw a=0 b=0", "raw a=1 b=0"]    // sink reads the OLD value
    after one hop:  ["hopped a=1 b=2", "hopped a=1 b=2"]

`objectWillChange` fires from `willSet`, *before* the new value lands, so a sink that reads the store
synchronously sees the value it is being told is about to change. **One hop is required for
correctness**; only the second is redundant. The same program showed the hop merges nothing — two
assignments still delivered two notifications — which is the amplification itself, isolated.

### What landed

[Coalescer](../pm-mac/PM/Shared/Coalescer.swift), a small `@MainActor` primitive that runs one job
once for a burst of requests on the next turn of the main queue — supplying the required deferral and
the coalescing together. `AppDelegate` now holds one and the subscription just calls `schedule()`.

Tested by [CoalescerTests](../pm-mac/PMViewTests/CoalescerTests.swift), seven cases. One of them,
`testAHopDefersTheWorkButDoesNotMergeIt`, asserts the *old* shape's behaviour deliberately, so that
reverting to it fails a test rather than quietly costing fourteen passes again. The others pin the
burst collapsing to one pass, the job seeing every value the burst wrote (the `willSet` property
above), a later burst still getting its own pass, and a job that requests again from inside itself
not being swallowed — which is why the flag is cleared before the job runs rather than after.

### How it was measured

Instrumenting `storeDidChange` with a counter, building against
[the dev vault](../scripts/dev-vault.sh) so nothing touched a real notes folder, and running the same
scenario twice — once with the coalescer and once with the old subscription restored:

| | Launch | One external edit |
|---|---|---|
| Old shape | 60 passes | 15 passes |
| Coalesced | 3 passes | 2 passes |

Fifteen for one edit is the fourteen assignments plus one, which is the arithmetic above confirmed
from the outside. The instrumentation was stripped afterwards and the shipped binary checked for it.

Verified end to end on the stripped build: the app launched against the dev vault, opened its window,
and picked up a `task.add` made by the CLI behind its back — `notesShow ok: todos=4` then
`todos=5` — with nothing logged as an error.

---

## 2. Get `PMStore` under test

**Status:** done, 2026-09-12. Nine tests, and both mutation checks bite.

`Model`, which holds `PMStore`, was 3,486 lines with no tests at all — the code that writes your
markdown, owns undo, and handles the stale-reference race.

### The diagnosis was wrong in a way worth recording

The original finding said `PMStore` could not be tested because it reaches `ConfigStore.shared`,
`ProjectIndex.shared` and the global `loadConfig()`, and proposed constructor injection for config and
IO. Reading [Config.swift](../pm-swift/Sources/PmLib/Config.swift) before writing any of that showed
the premise was false:

    public func getConfigDir() -> String {
        if let pmConfig = ProcessInfo.processInfo.environment["PM_CONFIG_HOME"], ...

`getConfigDir()` reads the environment on **every call** — nothing is cached. So `loadConfig`,
`resolveNotesHandle`, `PMFiles` and `PMContract` all already follow `PM_CONFIG_HOME` wherever it
points. The seam was there the whole time; it is what [dev-vault.sh](../scripts/dev-vault.sh) and all
722 `pm-swift` tests already use. A constructor-injection refactor would have churned the app's most
delicate class to build a seam that existed.

**What actually blocked it** was one file. `PMContract` carried the affordance tier — `app.openWindow`,
`app.settings` — in the same file as the dispatcher adapter, so it named `WindowManager`,
`FocusPanelController`, `SettingsWindowController` and `ObsidianLink`, and could not be compiled
without the whole app around it. `PMStore` calls `PMContract` on every mutation, so it inherited that.

### What landed

The split the contract's own tiers already implied: mutations and queries are pure domain and mean the
same thing headless, while an affordance is *a request to a running app* that `pm api` and `pm mcp`
list and refuse. They now live in separate files —
[PMAffordances.swift](../pm-mac/PM/Model/PMAffordances.swift) holds the second tier, as an extension,
so all nine call sites still say `PMContract.performAffordance`. Everything left in `PMContract.swift`
needs PmLib and nothing else.

With that done, `PMFiles`, `PMContract` and `PMStore` join the test target and compile. `ProjectIndex`
deliberately does not: the bundle already had a fixture stub of it for the mention tests, and a real
folder scan in a unit test is the TCC hazard [Stubs.swift](../pm-mac/PMViewTests/Stubs.swift) exists to
avoid. The stub gained the three published streams and the warm/retain/release calls `PMStore` mirrors
— structurally, empty, per that file's own rule that a stub which grew an opinion would be a stub the
tests were quietly about.

[PMStoreTests](../pm-mac/PMViewTests/PMStoreTests.swift) builds a throwaway PARA vault per test in
`NSTemporaryDirectory()`, points `PM_CONFIG_HOME` at it in `setUp` and restores it in `tearDown`. Nine
cases: loading, progress, a completion reaching the file, undo restoring the pre-edit bytes and redo
re-applying them, focus *not* banking an undo step, a project switch clearing the stack, and the two
that matter most — a write aimed at a task that changed on disk being refused rather than landing on
whatever moved into its position, and two refusals in a row reading as two.

The first test asserts the store resolved a path inside the test vault. If that ever fails, the rest of
the file is reading somebody's real notes and means nothing.

### Proving the tests bite

A test that passes proves nothing until it has been shown to fail for the right reason. Two mutations,
each applied to the real source, run, and reverted:

| Mutation | Result |
|---|---|
| `mutate` stops banking the pre-edit document | 4 failures, including both undo tests |
| `Todo.reference` sends `digest: nil` | 4 failures, including both stale-reference tests |

The second is the one worth having. Dropping the digest is exactly the regression that would let a
click act on a line that had moved underneath it — silent, and a data-loss bug rather than a crash.
The suite now catches it.

**Still open:** the `PM_CONFIG_HOME` seam is process-global, so these tests cannot run in parallel
with anything else that reads config. QuickBar's 4,045 untested lines follow the same route and were
not attempted here.

---

## 3. Generate the Swift action facade

**Status:** done, 2026-09-12. Forty-three actions generated, ten drift tests, and the completeness
check proven to fire with the right sentence.

Safety was inverted across the contract's adapters. Raycast, talking over JSON, got compile-time
checking from `pm-api.generated.ts`. The Mac app — the in-process adapter, the heaviest caller,
seventeen call sites in `PMStore` alone — dispatched on raw strings (`"task.setDue"`,
`"app.openInFinder"`) into [ApiInput](../pm-swift/Sources/PmLib/Api/ApiTypes.swift), a struct of
twenty-nine optional fields serving forty-three actions, each of which uses two to four of them. So
`PMContract.perform("task.setDeu", …)` compiled in a build the extension would have rejected.

`ApiInput` defends itself on the grounds that "a per-action type would be a second description of the
same thing, maintained by hand beside the first" — which the build already falsified: the per-action
TypeScript types are *generated*, not maintained.

### What landed

[generate-api-actions.mjs](../pm-mac/scripts/generate-api-actions.mjs), the sibling of the Raycast
generator, emitting [PMActions.generated.swift](../pm-mac/PM/Model/PMActions.generated.swift) — a
`PMAction` enum with a case per action, plus each one's tier, its required fields, and its
exclusive groups. `PMContract.perform` and `performAffordance` now take `PMAction`; every call site
was migrated and no raw-string form remains.

Two things the generated tables buy beyond the misspelling:

**A missing field, said at the call site.** `perform` asserts in debug builds that the input sets
every required field and exactly one of each exclusive group. This is the half `ApiInput` genuinely
cannot express — the compiler has no way to know `task.setDue` without a `due` is incomplete, and the
dispatcher's refusal surfaces to a person as "that task changed on disk", which is the wrong sentence
for a bug in PM. Debug only, deliberately: in a release build the refusal is still correct, and
trapping in front of somebody over a programming error is not.

**`givenFieldNames`**, which that check reads, uses `Mirror` rather than encoding the input to JSON.
The synthesised `Codable` conformance omits nil optionals so the keys would answer the same question,
but that is a detail of how the compiler happens to synthesise an encoder, and this is a check whose
whole job is to be trustworthy.

### The drift test is stronger than its TypeScript counterpart

The Raycast test shells out to whatever `pm` it can find, because a subprocess binary *is* the
extension's counterpart. The app's counterpart is different — it links PmLib and calls the dispatcher
in-process — so [PMActionsTests](../pm-mac/PMViewTests/PMActionsTests.swift) compares against
`ApiRegistry.actions` in the library the bundle is compiled against. Nothing needs to be installed,
and it cannot pass against a stale binary.

Ten cases, both directions: an action the registry publishes with no case, a case naming an action
that no longer exists, the contract version, and per-action agreement on tier, required fields and
exclusive groups — each also spot-checked against hand-written expectations, so a bug that made both
sides agree on nonsense still fails.

### Proving it bites

| Mutation | Result |
|---|---|
| `task.snooze` added to `ApiRegistry` | `testEveryActionTheRegistryPublishesHasACase` fails, naming the action and the command to run |
| `PMStore.setDue` stops setting `clearDue` when `due` is nil | traps: `task.setDue needs exactly one of due, clearDue` |

The second mutation is the one that justifies the assertion, and finding it needed a test that
actually *runs* each write. `testEveryMutationTheStoreOffersRunsWithACompleteInput` drives every
mutation the store offers — and both directions of each exclusive pair, since setting one and
forgetting the other is the entire failure mode and one direction would catch half of it. Checking
the live app instead would not have worked: `pmpanel://` is navigation only and never writes.

**Deliberately not done:** per-action input *types*, the exact parallel of the TypeScript interfaces.
The `oneOf` groups make honest signatures need overloads, and forty-three generated function
signatures is a lot of surface for a check the debug assertion already makes at the point it matters.

---

## 4. One due-label rule, and a test that keeps it that way

**Status:** done, 2026-09-12. Five implementations down to two, the survivor checked against the
canonical one, and three dead modules removed.

[api-contract.md](api-contract.md) diagnosed this and is marked built as of 2026-08-22, but only the
action half landed.

### The drift was measurable, and worse than "two copies"

The Mac app's `RelativeDue` header claimed it was "ported from the Raycast extension's
`format-relative-due.ts` so both surfaces read identically". Running the two rule sets over every
day-offset inside a month:

| days out | menubar | Raycast |
|---|---|---|
| 11, 12, 13 | `in 1w` | `in 2w` |
| 18, 19, 20 | `in 2w` | `in 3w` |
| 25, 26, 27 | `in 3w` | `in 4w` |

…and the same nine in the past. **Eighteen of fifty-nine offsets — 31% — rendered the same task
differently depending on which surface you were looking at.** The Swift copy floored its units; the
TypeScript copy rounded them. Swift's own comment says why flooring is right: *"a badge never claims
more time than there is"* — rounding up tells you a deadline is further away than it is, which is the
direction that costs something.

It was not only the rounding. The TypeScript copy was a whole generation behind: it still fell back
to a bare `7/4` past a month, which Swift had already removed as *"the one answer a badge can't use —
a date is a fact you have to do arithmetic on, and the whole reason a badge is three characters wide
is that you read it without doing any"*. And it computed day deltas as `Math.floor(ms / 86400000)`,
which is wrong twice a year: an hour gained or lost to daylight saving moves a boundary, so a date
exactly seven days out reports six.

### What landed

[RelativeDue.swift](../pm-swift/Sources/PmLib/RelativeDue.swift) in **PmLib**, which is where it
always belonged — `CaptureParse` already referred to `RelativeDue.short` in a comment, describing a
type it could not see. Thirteen tests pin the phrasing, including the offsets where the copies parted
company. The Mac app's copy is deleted; its forty-one call sites did not change, because the type
kept its name and they already imported PmLib.

Raycast keeps a copy, **on purpose**: `formatRelativeDueShort` renders `nextDue` for every row of the
projects list, and asking the contract per row would be a subprocess per row — the exact cost the
contract was designed not to impose. So the fix is not to remove the copy but to stop it being
unchecked. `pm due-table` emits PmLib's rendering for every offset in the range where the two
disagreed; that output is checked in as a fixture, and
[due-labels-conformance.test.ts](../raycast-extension/src/lib/__tests__/due-labels-conformance.test.ts)
asserts the extension against all fifty-nine rows. The TypeScript was rewritten to match, calendar-day
arithmetic included.

`pm due-table` is deliberately **not** a contract action. `pm api describe` publishes what clients
build against; this is a test affordance for one client's copy of one rendering rule, and putting it
in the manifest would suggest it is part of the interface. It also writes its JSON by hand rather than
through `JSONSerialization.prettyPrinted`, which emits `"days" : -29` — a space Prettier then
reformats, which would make the checked-in fixture fail the lint of the package it lives in. The
generator's output and the fixture are now byte-identical.

### Dead code the cleanup exposed

- `formatRelativeDue` — zero product call sites; alive only because a test imported it, which is a
  test keeping code alive rather than covering it.
- `formatDueForMenubar` — zero call sites, and still carrying the old rounding rule.
- `formatDatePrecise` — the private helper those two shared.
- [task-timing.ts](../raycast-extension/src/lib/task-timing.ts) — thirty-three lines, zero callers,
  called out in the contract doc back in August for claiming a shared schema it does not have.

`format-relative-due.ts` went from 155 lines to 82.

### Proving it bites

Restoring `Math.round` in the week branch fails ten cases — the nine future offsets plus the named
`floors weeks rather than rounding them` test. Reverted; 116 Raycast tests pass, up from 55.

### One thing deliberately not merged

`ProjectSidebar.lastTouched` also floors a `days / 7`, and is **not** a copy of this rule: it says how
long since a project was edited, is always in the past, and has no "in"/"ago" vocabulary. It shares
the flooring convention because flooring is right, not because it is the same function.

### Still open

Nothing. This paragraph used to say Raycast had lost a sub-day readout — "in 3h 20m" for something due
today — and called restoring it a product decision. **That was wrong.** At `HEAD`, before any of this
work, `formatRelativeDueShort` never showed hours: it said "today", "3d", "2w" or "7/4". The hour and
minute formatting lived only in `formatDueForMenubar`, which had no callers anywhere in the extension —
the dead function listed above. No person ever saw the readout this paragraph described, so there was
nothing to restore. Checked against `HEAD` with `git grep` on 2026-09-12, after being asked to restore it.

---

## 5. Migrate to `@Observable`

**Status:** done, 2026-09-12. All twenty-four `ObservableObject` types migrated; none remain, and no
`@Published`. A hosted-SwiftUI test measures the win, and the app follows an external edit in one pass.

Deployment target is macOS 26. `@Observable` has been available since macOS 14 and was used nowhere.

### Settled before editing

A scratch program answered the questions the migration's safety depended on, the same way item 1's
`willSet` question was settled:

| Question | Answer | Why it mattered |
|---|---|---|
| Does `didSet` survive the macro? | yes | `QuickBarModel` rebuilds its rows from ten of them |
| Is `private(set)` observable from outside? | yes | nearly every store property is `private(set)` |
| Does tracking reach through a computed property? | yes | `QuickBarModel.preview` and others are computed |
| Does `onChange` fire before or after the value lands? | **before** | item 1's hop is still load-bearing |
| Is tracking a subscription? | **no — one-shot** | every Combine `.sink` port would silently die |

### The two traps, and what catches each

**Tracking is one-shot.** `withObservationTracking` arms one notification and stops watching, so the
direct translation of a `.sink` delivers the first change and then nothing — a failure that passes a
quick test and shows up as a menubar gone stale after one edit.
[ObservationRelay](../pm-mac/PM/Shared/ObservationRelay.swift) re-arms and routes through item 1's
`Coalescer`, which supplies the deferral `onChange`'s timing needs. Eight tests, including both defects
pinned as the *unrelayed* behaviour; dropping the re-arm fails three. It also carries
`ObservationRelay.wait(until:)`, the replacement for `for await x in store.$hasLoaded.values`.

**`@Observable` instruments every stored `var`**, not just the ones that were `@Published`. A model's
private bookkeeping silently becomes an invalidation source for every view reading it — a regression
`ObservableObject` could not have had, because a property had to opt in. This one was real:
[PMStoreObservationTests](../pm-mac/PMViewTests/PMStoreObservationTests.swift) failed on first run
naming seven `PMStore` properties — `boundKey`, `cancellables`, `heroSnapshot`, `lastCompletedRef`,
`waitRootsRelay`, `wantsAllProjects`, `writeFailures` — which now carry `@ObservationIgnored`.

A scripted audit then compared every migrated class against `HEAD`, class by class: what was
`@Published` then against what is observable now. Twenty-three of the twenty-four are identical. The
twenty-fourth is `PMStore`, whose `allProjects` and `indexRecents` are no longer stored at all — they
became the computed pass-throughs described below, and a read of either still registers the index's own
property.

**The audit's first run proved nothing, and is recorded because it looked like a pass.** It was started
from the repository root with paths relative to `pm-mac`, matched no files, and printed "clean". The
rerun prints what it checked. It also had a blind spot the migration script shared: a stored property
written `var x: Bool {` with its `didSet` on the next line reads as computed to both, so a
never-published one would have been left observable and not reported. A separate scan for that shape
found two across all twenty-four classes — `WindowSettings.showOnAllSpaces` and `restoreWindows`, both
previously `@Published` and both correctly observable now.

### What changed shape

- **Eight Combine subscriptions became relays** — the app delegate's store and PARA-roots watches,
  `PMStore`'s wait roots, `WaitingModel`, `WaitingWatcher`, a file card's undo-stack watch, the
  project window's canvas path, and the find field's match count. Where the old pipeline had
  `removeDuplicates` or `dropFirst`, the equivalent is written out and commented, because observation
  announces an assignment rather than a change of value.
- **`PMStore` stopped copying the project index.** `indexRecents` and `allProjects` were stored
  properties kept in step by two `assign(to:)` mirrors, because under `ObservableObject` a view could
  only notice a value physically present on the object it observed. They are now computed
  pass-throughs to `ProjectIndex`; the copies, the subscriptions and the turn in which a store held a
  stale scan all went away.
- **The app delegate's dependency is written down.** `PMStore.appDelegateDependencies` pairs each
  name with a read, so the two can't drift apart; the test above fails when a new observable property
  is added without a decision about it. Under `objectWillChange` that addition changed the app
  delegate's behaviour with nothing to notice. It deliberately lists all twenty-two, for the reasons
  in its comment — which means **the app delegate's pass count is not where this item's win is.**
- Views: `@ObservedObject` → plain property, `@Bindable` in the four files that take bindings;
  `@StateObject` → `@State`; the one `@EnvironmentObject` → `@Environment`. Shared singletons held by
  views became `let`, since a `private var` made one view's memberwise initializer private.

### Measured

The win is in SwiftUI bodies, so that is where it is measured.
[ObservationScopeTests](../pm-mac/PMViewTests/ObservationScopeTests.swift) hosts two real views on a
window, one reading `title` and one reading `rows`, and changes `rows`: under `@Observable` the title
view's body does not run again; under `ObservableObject` it does. Both halves are checked in, so a model
reverted to `@Published` fails a test.

End to end against [the dev vault](../scripts/dev-vault.sh), with `storeDidChange` instrumented and the
instrumentation stripped afterwards: the app followed an external `project.focus` and loaded the
project, and a `task.add` made by the CLI behind its back arrived as **one pass**, `todos=3` → `todos=4`.
Item 1's coalesced figure for one external edit was two. This was not a paired control run the way
item 1's was, so read it as "no regression, probably slightly better" rather than as a measured delta.

**Still open:** `PMViewTests` cannot click SwiftUI, so the evidence for views is body counts, not
interaction; the app was exercised through the CLI, not by hand. Unused `import Combine` lines were
not audited.

---

## 6. Break up `CanvasBoardView`

**Status:** done in part, 2026-09-12, and the rest deliberately not. Two passes: three collaborators out
of `+Commands` and the board, then the rules inside `+Input` and `+Tiling` — 59 tests for logic that had
none, every external caller untouched.

The finding stands: 6,144 lines, one class across five files, every member `internal` because an
extension in another file cannot see `private` — so the extension split moved text without creating a
boundary. Nothing in the test bundle can build a board, which is the same fact seen from the other side.

### The premise about `+Commands` was wrong

The original read called it "almost certainly a command table". Reading it first: it is **five
things** — pasteboard rules, 609 lines of contextual-menu construction, the `@objc` actions, a
170-line `validateUserInterfaceItem`, and card search. Extracting it as one type would have moved all
five into a new file with the same absent boundary.

### What moved

Each is a thing with rules, behind an interface that names what it needs and nothing else. The board
keeps its method names as one-line forwards, which is what let this happen without touching
`CanvasPaneController`, `CanvasScrollView` or the link card's calls — all in-flight or widely used.

| Collaborator | What it owns | Sees the board through | Tests | Mutation that fails them |
|---|---|---|---|---|
| [CanvasPageDirector](../pm-mac/PM/Canvas/CanvasPageDirector.swift) | when the page budget is applied; the heartbeat; stale refresh; pausing | `CanvasPageStage`, 7 members; cards via `CanvasPageCard`, 10 | 18 | no deferral mid-crossing, or hidden cards counted as seen — 3 fail |
| [CanvasClipping](../pm-mac/PM/Canvas/CanvasClipping.swift) | what copy puts on the pasteboard, in both flavours | a document and a set of ids | 9 | an edge carried when only one end was copied — 3 fail |
| [CanvasSearch](../pm-mac/PM/Canvas/CanvasSearch.swift) | which cards a search finds | a document, and an injectable title lookup | 9 | page names no longer searched — 2 fail |

The director is the one worth having. The case it pins — a page-budget review requested mid-crossing
is deferred until the board stops — was a measured 165–206ms stall inside a 350ms animation, fixed once
already and previously only checkable by running the animation. Its timing goes through an injectable
`Schedule`, so the tests decide when a turn ends rather than waiting for one.

`CanvasPageCard` needed three page hooks declared on `CanvasNodeView` as no-ops so `CanvasLinkNodeView`
can `override` them. Without that, protocol dispatch to an extension method would have silently skipped
the link card's versions.

**The line count barely moved, and that is the honest measure of this item:** the board files went from
6,144 to 5,935, and the three collaborators are 424 lines, much of it the comments and protocols that
make the boundary legible. What changed is not size but reach — the page logic can no longer see the
board's other members, and three sets of rules now have tests.

### Deliberately not done

- **The contextual menu builder.** 609 lines, but it reads sixteen board members and every item it
  builds targets a board action. Extracting it would produce a sixteen-member protocol, which is
  relocation rather than a boundary, and building an `NSMenu` has no rule worth a test.
- **The `@objc` actions.** They have to stay on the view: AppKit dispatches menu and key-equivalent
  selectors down the responder chain, and the board is the responder.
- **`validateUserInterfaceItem`.** An earlier pass of this document called its predicate half "the
  best next candidate". Measured by the test that ruled out the menu builder, it is the *more* coupled
  of the two: it reads twenty-four board members, and seventeen of its thirty-five cases retitle or tick
  the menu item in the same breath as answering. A pure predicate would take a twenty-four-field
  snapshot of the board, built on every menu validation. Not done.

### Second pass: `+Input` and `+Tiling`

The first pass left these untouched. Both are mostly things that must stay on the view — AppKit delivers
mouse and key events to the responder, and the board is it — so the question was what *rules* sit inside
them, measured by the same test as above: how much of the board each one reads.

**The key tables.** [CanvasBoardKeys](../pm-mac/PM/Canvas/CanvasBoardKeys.swift) holds the two modes that
take the keyboard for themselves. The workspace keys (docs/canvas-workspaces.md §7k) read two facts —
whether a placement is being chosen, whether a tile has focus — and picking reads two: whether a peek is
open, and whether anything is under the pointer. Both are now pure functions from a key press to a command,
and `keyDown` does what they return; handing a key to a card's editor and making things first responder
stay where they were. Twelve tests. Removing the ⌘/⌃ guard — which is what keeps a menu's key equivalents
the menu's — fails its test; removing the key-repeat guard, which stops a held Space flickering a peek,
fails its test.

**The tiling rules.** `plannedTiling`, `tileTargets`, `tilingSummary` and `preferredArrangement` read only
the document, the selection and the last tiling, so they moved into `CanvasTiling`, the pure namespace the
rest of the tiling rules already live in — with `canvasCardsInside`, which they need and which had been
sitting in the board file where the test bundle cannot reach it. Eleven tests in `CanvasTilingPlanTests`,
each a rule the code's own comments say was once wrong: nothing selected is nothing to tile (it used to be
everything on screen), a selected frame means the cards whose centres are inside it, the same cards in any
order get last time's arrangement, and asking for an arrangement keeps the order but not the sizes.
Dropping the frame expansion fails two; matching the remembered tiling by order instead of by set fails two.

**And a duplicate the move turned up.** The board's `tile` had its own copy of the arrangement precedence —
asked, then remembered, then saved, then preferred — beside the one in the planner. Both now call
`CanvasTiling.arrangement(asked:remembered:saved:cardCount:)`; putting "saved" ahead of "remembered" fails
its test.

The board files went from 5,935 lines to 5,845; `CanvasBoardKeys` is 132 and `CanvasTiling` grew from 528 to
620. As with the first pass, the measure is reach rather than size.

Not done, and why:

- **The mouse handling.** The drag state is already a value type (`Gesture`), and what `mouseDragged` does
  with it is apply it to views — frames, the overlay, autoscroll — which is the part that has to be on one.
- **`projectCardTakes`**, three cases that forward straight to the card's own commands.
- **`retileForWindowSize`'s guards**, three checks of view state — visible rect, picking, mid-flight — each
  of which only means something on a live board.

---

## Smaller things, carried here so they aren't rediscovered

**`StoreRegistry`'s manual refcounting fails silently.** *Status: done, 2026-09-12 — as a different
fix from the one proposed.* The proposal was a lease token whose `deinit` releases. Every one of the
twenty acquire/release sites was read first, and **all are balanced**: the `previous !== store` check in
`FocusPanelController` looks like a missing release and is only redundant, since its guard has already
returned; `LiveSessionNote` and the quick bar release on every branch; and nothing calls
`PMStore.bind(to:)`, so a store's key can't drift from the one it was registered under. Balanced,
though, only on the condition that each completion a release rides in actually runs — and that was
where the fault was.

`reload` states the rule ("a completion that only ran on success would strand a caller waiting on it the
one time the read failed"), and **four of the store's other completions broke it**, returning early
without calling `then`: `mutate` when no project is loaded, `undoLast` with nothing to undo, `pasteTasks`
with an empty block, and `openCurrentSession` when no session opened. The last one was reachable from
the quick bar: `>session` hands its receipt through that completion, so a project that wouldn't open left
the bar waiting on an answer that never came. All four now complete on every path. A mutation with no
project also reports itself as a refused write ("No project is open, so nothing was written."), so the
bar's `settle` — which compares failure tokens — says it failed instead of confirming; nothing to undo
deliberately does *not*, because `AppDelegate` notifies about refused writes while PM is in the
background, which is exactly when the bar is used. `openCurrentSession` now answers `Int?`; the board
card ignores nil, so a failed start leaves an open note alone.

Four tests in [PMStoreTests](../pm-mac/PMViewTests/PMStoreTests.swift); restoring the four early returns
fails all four. The lease token was not built: it would change twenty call sites to guard against an
imbalance none of them has, and Swift does not promise a local's lifetime to the end of its scope, so a
lease held in a local is its own new way to release early.

One oddity recorded rather than changed: `ProjectLinks` deliberately keeps the store object after
releasing its registry hold, for a page name that arrives seconds later. A second acquire in that window
builds a second `PMStore` for the project. The write is still safe — it goes through the contract, with a
revision check — but the late label lands on an undo stack no window is showing.

**Every write reads the whole file three times.** *Status: done in part, 2026-09-12 — measured first,
and the measurement moved the problem.* The finding proposed carrying pre- and post-write revisions in
`ApiResult` so the snapshots either side of a write could be skipped. Timing it showed the reads are not
the cost. A temporary probe (deleted afterwards) built synthetic vaults by cloning one project made
through the real API, and timed what `PMStore.mutate` and the `reload` after it do around a `task.add`:

| Projects | One resolution | One file read | Contract write alone | `mutate`-shaped tick | Share outside the write |
|---|---|---|---|---|---|
| 20 | 0.8 ms | 0.03 ms | 6.6 ms | 11.0 ms | 40% |
| 200 | 3.4 ms | 0.03 ms | 10.0 ms | 21.6 ms | 54% |
| 1,000 | 16.1 ms | 0.03 ms | 22.8 ms | 72.0 ms | 68% |

**Reading the file costs nothing; resolving the project costs everything.** `resolveNotesHandle` reads the
config, lists all three PARA roots to match the name, stats the notes file, and reads the config again —
and `mutate` did it three times per tick (before, after, reload) on top of the contract's own. Those are
local-SSD temp vaults; a real vault in a protected Documents folder was not measured and is unlikely to be
faster.

What changed: `mutate` resolves once and takes both snapshots from that handle, and undo/redo does the
same for its banked snapshot and its write. Safe because no mutation passed to `mutate` moves a project
folder — all eleven are edits inside the notes document — and the reload that follows still resolves for
itself, so a folder moved from outside mid-write is still recovered from. By the arithmetic of the table
rather than a second timing, that is one resolution fewer per tick: about 3ms of 22 at two hundred
projects, 16ms of 72 at a thousand. Dropping `mutate`'s after-snapshot fails both undo tests; dropping
undo/redo's banked snapshot fails the redo test.

Not done, and why:

- **Carrying revisions in `ApiResult`**, as proposed. It would save reads that cost 0.03ms each.
- **Reusing the after-snapshot for `reload`**, which would save a second resolution. A store following
  the focused project can switch projects between the write and the reload, and reusing a handle across
  that switch would show one project's tasks under another's name — a new branch the current tests do not
  cover.
- **The real lever was upstream, in `pm-swift`** — every surface listing every PARA root on every call.
  Now done; see *A cache for root listings*, below.

**And a flaky test found while verifying this, which was mine.** One clean run of `PMStoreTests` failed and
took seven seconds; three reruns and thirty isolated iterations passed. The cause was the `waitForFile`
helper written for item 3: it returned as soon as the *file* showed a write, before the store's reload had
landed, so the next step could act on out-of-date tasks and have its write rightly refused. It now also
waits for the store's `lastEditedAt` to match the file's modification date. Proven rather than re-run:
with `reload`'s read delayed by 300ms, the old helper fails every time — the store still showing "First
task" after the wait returned — and the new one passes. The delay was removed afterwards.

Related, unchanged: `maxHistory = 100` full document copies, per store, per project, held for the session.

**A cache for root listings.** *Status: done, 2026-09-12.* Turning a project name into a folder lists all
three PARA roots, and every surface does it on every call — the CLI, the MCP server, Raycast through the
CLI, the Mac app several times a tick. Every one of those calls ends in the same two raw listings in
[Projects.swift](../pm-swift/Sources/PmLib/Projects.swift), so that is where the cache went:
`DirectoryListingCache` keeps each root's entries — names, and which are folders — against the root's
modification date, which moves whenever an entry is added, removed or renamed. Only the listing is cached.
Whether an area-shaped folder holds notes depends on what is inside it, which does not move the root's
date, so that is asked afresh every time.

Three rules keep it from answering with a listing that is out of date, and each has a test that fails
when the rule is removed:

- **The date is read before the listing.** Read after, a change landing between the two stores the old
  entries under the new date, where they look current until the next change. Read before, the worst case
  is one listing too many.
- **Nothing is kept while the directory changed in the last two seconds.** A filesystem that records
  whole seconds, or two like FAT, gives a folder created in the same second as the listing the same date —
  so `project.create` followed at once by `task.add` in one MCP session would not find the project. This is
  git's "racily clean" rule for its index.
- **An entry is trusted for ten seconds at most**, as a backstop for mounts that never move a directory's
  date. On APFS the date alone is exact.

Errors and directories with no readable date are never cached. Ten tests in
[DirectoryListingCacheTests](../pm-swift/Tests/pmTests/DirectoryListingCacheTests.swift): the three rules
against a filesystem and clock the test controls, plus a project created and used at once and one renamed
on disk, both through the real resolver. Measured before and after with the same probe, on the same
machine, in one session — synthetic vaults on local disk, a fifth of the projects active:

| Projects | Resolve, before → after | App-shaped tick, before → after |
|---|---|---|
| 20 | 0.70 → 0.67 ms | 9.1 → 9.3 ms |
| 200 | 3.0 → 1.6 ms | 16.8 → 12.3 ms |
| 1,000 | 15.6 → 6.9 ms | 54.1 → 28.3 ms |

Nothing changes with twenty projects, where listing was never the cost. What is left at a thousand is the
config read twice per resolution, the path checks, and matching every folder name against the project
pattern on every call — each small, and not attempted. The CLI benefits least: a process that exits after
one call lists each root once either way. The app and the MCP server, which stay running, are where this
pays.

**Two mechanisms for the same watching job.** *Status: checked 2026-09-12; not a defect, left alone.*
The finding said `CanvasDocumentStore`'s two-second mtime poll "misses same-second changes". On APFS it
does not: a probe writing the same file twice twenty milliseconds apart got two different modification
dates, and both watchers compare for *inequality* (`stamp != knownStamp`, `signature != lastSignature`)
rather than "newer than", so any change of stamp is seen. The lessons `ConfigWatcher` learned — that a
vnode watch goes silent after an atomic save replaces the inode — are lessons about its vnode fast path,
which the canvas watch doesn't have and so can't get wrong. What the difference actually costs is latency:
an edit made in Obsidian reaches an open board within two seconds rather than at once. Not worth a second
copy of `ConfigWatcher`'s machinery for a board. Its repeating `Timer` does retain the store, but
`CanvasStoreRegistry` stops the watch when the last holder releases, so that is not a leak either.

**Dead scaffolding in the repo root.** *Status: done, 2026-09-12.* Deleted: `tsconfig.json`
(`rootDir: src`, and `src/` does not exist); `package-lock.json` (locked at version 0.1.14, pinning
`commander` and `@shanberg/project-schema`, with a `bin` pointing at the deleted `dist/cli.js`); the
root `node_modules/`; and the four `project-manager-0.2.x.tar.gz` npm-era tarballs.

**And one thing the original read missed, which was still running.** `.github/workflows/publish.yml`
ran `npm ci && npm run build && npm publish` on every published release. `npm run build` has not
existed since the TypeScript CLI was deleted, so it **failed on every release** — all of the last ten
runs, v0.31.0 through v0.39.0, report failure, and the v0.39.0 log stops at `Missing script: "build"`. It happened to fail before
`npm publish`, which would otherwise have pushed the repo root to GitHub Packages. Deleted with the
rest; deleting the lockfile alone would have broken it one step earlier.

Kept, having checked: `dist/` is live — `build-app-dist.sh` writes `dist/PM-v<version>.zip` and
`update-cask.sh` reads it. `package.json` is `release.sh`'s source of truth for the version.
`tests/visual/` drives the Swift binary and is current.

---

## What was already good, recorded so it doesn't get "fixed"

Hygiene here is better than most production codebases, and the findings above are about structure that
grew past its original shape rather than about carelessness. Across 76k lines: no `try!`, no `as!`, no
`TODO`/`FIXME`/`HACK`, and all twenty-two `fatalError` sites are `init(coder:)` boilerplate.
`pm-swift` is 12k production lines against 10.4k test lines. `ConfigWatcher`'s vnode-plus-poll design
is a correct answer to a subtle problem and should not be simplified by someone who hasn't hit it.
