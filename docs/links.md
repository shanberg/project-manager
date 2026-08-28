# Waiting on

**Status:** built, 2026-08-28. `TaskContent` carries the token, `WaitTarget.swift` resolves it,
`task.setWaiting` publishes it, and the Mac app draws it inside the task line. Two things are
known-missing on purpose: the cross-project Waiting grouping, and the unblock moment — both below.

This settles what a link between projects *is* before any of it is written, because the answer turns
out to be "not a link between projects."

## What's actually being modelled

"Project A depends on project B" is almost never true as stated. What's true is that one piece of work
in A can't move until something in B lands. A whole project is rarely blocked — there are usually six
other things you could be doing in it.

That matters because PM is task-centric everywhere it counts. Focus is a task. `nextTask` is a task.
Due is a task. The menubar ring counts tasks. A project-level edge would be the one concept in the app
that composes with none of it.

So: **a wait is on a task, and the project-level reading is derived.** A project whose open tasks are
all waiting *is* blocked, computed rather than declared — the same move `ProjectKind.of(folderName:)`
makes when it reads kind off the folder and never stores it.

The generalisation that falls out for free is the one that earns the feature. The target of a wait
doesn't have to be a project. `waiting: [[Dana]]` is the more common real case — waiting on a person,
an invoice, a vendor reply — and it needs no extra machinery, because a project reference is just a
target that happens to resolve.

## Where the edge lives

Notes files are the truth, so an edge is text in a file. Three places it could have gone:

| | Cost | Why not |
|---|---|---|
| A line in `## Links` | zero new syntax — `parseLinksBlock` and `LinkEntry` already exist | project-granular, and untyped: no way to say this is a wait rather than a see-also |
| A new `## Waiting on` section | explicit | new section = template, `headerSections`, parser, serializer, `NotesRawEdit`, contract version, Raycast types — and still project-granular |
| **An inline token on the task line** | one field on `TaskContent` | — |

A task line already reads `- [ ] Ship it due: 2026-09-01 @`, and `TaskContent` exists precisely so
nothing re-derives that structure for itself. A third token is a change to one struct, and every
mutation path inherits it: `setDue`, `setText`, `complete`, `wrap`, `move` all decompose a line through
`TaskContent.split` and rewrite it through `render`, so a wait survives all of them without any of them
being told it exists.

```
- [ ] send the launch email waiting: [[Website Refresh]] due: 2026-09-05
```

**Canonical order puts the wait inside the due, not outside it.** `dueInlinePattern` only matches a
`due:` followed by the focus marker or the end of the line, so a canonical order ending in the wait
would have broken every existing due date. `split` peels trailing tokens in a loop rather than a fixed
sequence — with three of them, staying order-agnostic by hand would need six unrolled orderings — so a
line written any other way parses identically and is repaired to canonical on the next edit.

### The brackets are load-bearing

`due:` can afford to be permissive about what follows it because a date has a shape. A wait target is a
name, so an unbracketed `waiting:` would swallow the tail of any task containing the word — "stop
waiting: it already shipped" would parse as a wait on "it already shipped". The brackets give the value
the terminator it otherwise lacks, and they are the syntax the vault these notes live in already uses
for naming another note.

They also buy something unplanned: because the token is in the line rather than in a separate field,
**every free-text surface already accepts it.** Typing `waiting: [[Dana]]` into the quick bar, into
Raycast, into an MCP call, or into the note in Obsidian all land the same token, and `capture.parse`
needed no change at all.

## One side stores it; the other side is computed

Nothing writes "blocks W-2" into W-1. Two files that must agree is a consistency problem with no
transaction, and these files are hand-edited in Obsidian, renamed, and moved between folders. The wait
is written once, on the side that feels it, and the reverse direction is derived from the scan that
already walks the project folders.

The same rule settles inheritance. `Todo.effectiveWaiting` is the task's own wait, else the **nearest**
waiting ancestor's — nearest, not earliest, which is where it parts company with `effectiveDueDate`.
Two ancestors with due dates are competing deadlines and the soonest wins; two waiting ancestors are a
chain, and the one that blocks this task is the closest link in it.

## Resolution is lenient, and failure isn't an error

`resolveWaitTarget` tries three ways of naming the same folder, from the most complete statement to the
least: the folder name, the title alone, then an unambiguous code prefix. Title before prefix, so a
folder literally titled `W-1` isn't shadowed by the prefix rule. All three compare case-insensitively —
this is a name someone typed into a sentence, not a path.

Roots are searched active → areas → archive, the same order `resolveProjectPath` uses. The order is
load-bearing rather than tidy: a project unarchived back into `active` is live again, so `active`
winning isn't a tiebreak, it's the rule that stops a restored project from still looking finished.

Three outcomes, and note that none of them is an error:

- **pending** — names something live. The wait stands.
- **released** — names something archived. Archiving *is* completion in PM; there's no other done
  state, which makes it a clean trigger. Whatever this task was waiting for has landed.
- **unresolved** — names something PM has no folder for, or something ambiguous. Drawn as written.

A name PM can't place is `unresolved`, not invalid, and that distinction is most of why the feature is
worth having: most things anyone waits on are people, and none of them are in the projects folder. An
ambiguous prefix collapses into the same case deliberately — the honest thing to draw for a name that
could mean two projects is what you'd draw for one that means none.

## What it changes about using PM

**Focus stops offering you blocked work.** `Todo.isAvailableForFocus` is `!checked && effectiveWaiting
== nil`, and every selector reads it rather than re-deciding: the now-style advance, the document-wide
fallback, and `nextDiveInLeaf`. Absent any wait it is exactly the `!checked` those three tested before,
so nothing about existing behaviour moved. When everything open is waiting, focus clears — that is the
honest answer, and the callers already handled nil.

The rule is about *advancement*, not about overriding you. Explicitly focusing a task, or adding a
subtask under a blocked parent, still takes focus: you asked for that one.

**A waiting row recedes.** Its text goes secondary and stays there — not struck through, which means
done, and a waiting task is the opposite of done. That recession is the signal that works no matter
where in the row the sentence ends, which matters because of how the wait is drawn.

## How it's drawn

The wait is **inside the task line, not a chip at the trailing edge.**

A due date is a chip because a date has a frame of its own: it's a fact *about* the task, and every
row's date lines up in the same column. A wait isn't that shape. What a task is waiting on is part of
the sentence it makes, so it is an attribute over characters — the line `RenderedNote` already draws
when it says emphasis and links go in the run and an image, which has a size of its own, cannot.

Two things follow. It wraps with the text it belongs to, on a row whose text deliberately wraps rather
than truncating. And the trailing edge keeps meaning one thing — when this is due — instead of holding
two chips and the hover controls in a column that was already tight.

The target is shown as its **title**, not its code, and isn't truncated. A title cut to
"Q3 Partner Migra…" is worse than the code, because at least the code is exact; and since both runs are
secondary on a waiting row, a long target makes the row quieter rather than louder.

That leaves colour, weight, slant and one trailing glyph to carry four states:

| state | colour | type | glyph |
|---|---|---|---|
| waiting on something live | secondary | regular | clock |
| inherited from a waiting parent | tertiary | *italic* | clock |
| the thing waited on is archived | green | medium | check |
| names something PM can't place | tertiary | regular | none |

Italic does the work a dashed border does for an inherited due date. It is the only one of these levers
that reads as *reported* rather than as *less important*, and that is the distinction: a descendant
isn't waiting a bit less, it's waiting because something above it said so.

The unresolvable case losing its glyph is deliberate. `waiting: [[Dana]]` is a complete and correct
statement, and a status marker on it would claim PM knows something about Dana that it doesn't.

### What this gives up

Scannability down the column. A chip lands at a fixed x on every row, so waits line up and can be found
without reading; inline, the marker sits wherever that row's sentence ends. The trade is deliberate —
you don't scan a project's list *for* blocked work, you scan it for what you can pick up, and the
recession does that at any x-position — but it moves the cost somewhere, and the somewhere is the
Waiting grouping below.

### Navigation

⌘-click was the obvious gesture for following the target and turned out to be taken: the row already
hands its modifiers to Finder-style selection. So navigation is the context menu — "Go to Website
Refresh" — alongside "Waiting On…" and "Stop Waiting". Stop Waiting appears only for a task's *own*
wait; an inherited one belongs to the ancestor that declared it, and clearing it from here would
silently edit a different row.

The editor behind "Waiting On…" is a plain text field rather than a project picker, because the target
is as often a person as a project and a picker would have no row to offer for one. In the note editor
the same job is done by `@`, below — which does have a picker, and can still take a name that matches
nothing, the thing Linear's mentions never have to do.

## Naming a project: `@` to type, `[[…]]` to store

The `waiting: [[Target]]` token is the file format. It is not what anybody types.

`@` is already this app's sigil for "name a project" — the quick bar's go-to mode and its capture
redirect both mean exactly that — so extending it into the note editor added a surface, not a meaning.
Typing `@web` puts up a filtered list ranked by `ProjectSearch` (initials and fragments, so "hmax"
finds "H-004 Maxwell Carmody"), and taking a row writes `[[W-1 Website Refresh]]`. The sigil is input;
the wikilink is storage; neither has to look like the other.

Two rules earn their keep:

**A bare `@` offers nothing.** ` @` at the end of a task line is the focus marker — the notes format's
own syntax, written by every focus command in the app — so a list that opened on the sigil alone would
appear every time a task took focus. Requiring one character costs nothing, because there is nothing
to search for yet, and removes the collision entirely.

**The full folder name is what gets written**, not the title the row shows. The title is what reads;
the folder name is what survives, because it carries the `CODE-NNN` that a rename keeps.

### `/` for what a line can carry

`/` opens the line commands: **Task**, **Waiting on…**, and the date presets. That list isn't a
starting subset — it is the entire vocabulary a task line has, which is what makes a slash menu the
right shape here instead of an open-ended palette. The dates are `duePresets`, the same list the due
chip's menu shows and `QuickCaptureParser` reads back, so "next week" means one day across the app.

Note what `/` is *not*: it isn't the quick bar's `>`. **Sigils that name an entity are global; sigils
that name a mode or an action are per-surface.** `@` means "a project" everywhere. `/` means "search"
in a launcher (Spotlight's idiom, and the quick bar's find-task mode) and "commands" in a document
(Notion's idiom, and the note editor's) — both correct in their own genre, and forcing one scheme
across both would make one of them wrong.

`Waiting on…` is where the two sigils meet. It writes `waiting: @` and hands straight over to the
mention picker, so the whole thing is one gesture:

```
- [ ] Legal review /wait ⏎ vendor ⏎
- [ ] Legal review waiting: [[W-3 Vendor Contract]]
```

That is the answer to the ordering problem the typed grammar had. `due:friday waiting: [[Dana]]` parses
and `waiting: [[Dana]] due:friday` doesn't, and the old fix was a rule to teach — the same rule the
quick bar's `@` redirect already documents. A picker writes the token in the right place, so there is
nothing left to teach.

## Tokens are atomic in PM, and only in PM

Obsidian is the storage substrate, not the UX anchor. PM's editor presents `[[…]]` as one thing: the
caret steps over it, backspace takes all of it, a click between the brackets lands beside it, and a
selection covering part of it covers all of it. A wash behind it says so before you try.

**Atomicity is behaviour, not representation.** The text storage stays exactly the markdown — every
rule is a PmLib transform over (text, index), and the view only decides when to ask. The alternative,
substituting an attachment for the token, would mean storage stops being the file, and everything
downstream assumes it is: `NotesRawEdit` splices raw text and `notesShow` takes a revision of the exact
bytes so a write can assert it saw this document. Both would need a translation layer, and that layer
is where format preservation goes to die.

The brackets are dimmed rather than hidden. Collapsing them to zero width is a TextKit layout job and
pure presentation — it can come later, on top of behaviour that is already right.

## Drawing a token

A pill is a rounded rect behind a run of glyphs, which neither SwiftUI's `Text` nor an
`AttributedString` can express — `backgroundColor` gives a rectangle hugging the letters with no
padding and no corners. So there is one `TokenLayoutManager`, shared by the note editor and by the
task rows through `TokenTextLabel`, and one drawing path: a reference looks the same whether you are
reading it or typing it.

**The brackets are the padding.** They're marked as `.controlCharacter` glyphs — AppKit's own mechanism
for a character that occupies a width you choose and paints nothing — rather than `.null`, which has no
width and simply vanishes. So the same characters that were visible punctuation become the space inside
the pill. Nothing about the file changes: `NotesRawEdit` still splices raw text, the revision a write
asserts against is still a revision of the real bytes, and every offset still counts the brackets.

The rows had to be AppKit for a second reason: **hit testing**. `TokenLabelView.hitTest` returns nil
anywhere that isn't a pill, so a pill takes the click and everything else falls straight through to the
row — selection, double-click-to-focus and drag are untouched. A label that swallowed clicks would have
broken selecting a task by clicking its text.

Surfaces without a layout manager — a menu item, the sidebar's next-task line, the quick bar's search
rows — get the same result by rewriting, through `displayingWikilinks`. Both are presentation.

### Four things that cost a round each

Written down because each is invisible until it bites, and three of them are the same shape: a
measurement that looked plausible and was wrong.

- `boundingBoxForControlGlyphAt` is asked once per **glyph**, and there are two brackets a side. Half
  the padding per glyph gives the token twice what was set.
- `CGFloat.greatestFiniteMagnitude` as a text container's width overflows TextKit's own arithmetic. The
  layout it returns is garbage, and the garbage read as a plausible "ideal width" of a few hundred
  points — so every row wrapped into a narrow column. Use a large *finite* value.
- `usedRect` is clamped to the container, so laying out in a 1pt container to find the longest word
  reports 1pt. A minimum has to be measured word by word.
- SwiftUI probes a view with a **zero-width** proposal to learn how narrow it can go. Answering with the
  ideal makes it look inflexible at full width, and an `HStack` divides leftover space among its
  flexible children — so the task text and the empty gap beside it each took half the row. Report an
  honest minimum, and give the content `.layoutPriority` over the `Spacer`.

None of these produced an error. They produced a layout that looked deliberate.

## The three questions a task list gets asked

A wait answers each differently, and each has one implementation:

| question | function | who asks |
|---|---|---|
| What's outstanding? | `openTasks` | counts, progress, search — and due dates, deliberately: a blocked task due Friday is when the deadline matters most |
| What could I pick up? | `availableTasks` | focus advancement, sidebar next-task, switcher, menubar, focus panel |
| What am I blocked on? | `waitingTasks` | the Waiting grouping |

`heroTask` sits beside them: the focused task, else the first available one. That fallback is the half
that mattered — four surfaces spelled it as "first *open* task" in two different phrasings, so the
sidebar, the switcher, the menubar and the focus panel would each offer work that focus itself had
declined to. The defect predates waits; waits made it load-bearing.

A focused task that is waiting still wins. Focus advancement skips waits, so getting there took a
deliberate act, and the hero reports what the document says rather than overruling it.

## Known-missing, on purpose

**The Waiting grouping.** One list, across every project, of everything you're waiting on, grouped by
target — because the unblock event is per-target, so grouping that way makes each one a readable list
the moment it lands. This is where the alignment given up by drawing inline has to be paid back, and
it is the other half of the feature rather than a nice-to-have.

**Renames.** A stored `[[W-1 Website Refresh]]` stops resolving the moment the project is renamed to
`W-1 Site Refresh`: the query is longer than the folder and diverges, so no rule matches. Writing the
full folder name is half the answer; the other half is a rule that resolves a target by the `CODE-NNN`
it starts with, plus drawing the *resolved* title rather than the stored text — so a rename becomes
invisible, the way it is in Linear.

**The unblock moment.** Archive W-1 and every task waiting on it goes live. Today that shows up as a
green check the next time you look at the project. It should announce itself once — "3 tasks were
waiting on W-1" — and that deserves to be designed rather than left as a badge quietly flipping.

## Deliberately not built

**Task-to-task waits.** A `TaskRef` in a link would need the digest, and digests move when text is
edited — so the wait would break every time someone fixed a typo in the task they were waiting on.
Project granularity is coarser and holds still.

**Parent/child projects.** "Part of" wants rollup progress, and progress here is `done/total` per
project. If it ever arrives it's a `ProjectKind`-shaped conversation, not another edge type.

**A typed relation vocabulary.** "Relates to", "supersedes", "see also" are navigation, and `## Links`
already does navigation. Only "waiting on" changes behaviour, so only "waiting on" earned a token.
