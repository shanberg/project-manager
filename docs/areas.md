# Areas

**Status:** built, 2026-08-26, and reviewed. Every step in the order of work below is committed across PmLib, the CLI, the contract, the Mac app and the Raycast extension, and the seven defects the pre-release review turned up are fixed. Two things are known-missing on purpose: cadence, and adopting a folder you already have — both below.

This settles what an Area *is* before any of it is written, because most of the answer turns out to be "relax four assumptions", not "add a second document type" — and because the interesting question is where the difference between the two kinds is allowed to live.

## What's being modelled

The things that don't end. A standing responsibility (hiring, on-call, the design system), a relationship you keep (a weekly 1:1, a vendor), a meeting that recurs. PARA calls them Areas and files them beside Projects; PM has had nowhere to put them.

The distinction isn't size or importance. It's that a project accumulates toward a finish line and an Area accumulates forever. Everything below follows from that one difference.

## The document is already right

A project's notes file is a header of framing callouts and then `## Sessions` — an append-only log of dated sittings, each holding prose and tasks. That is exactly the artifact an ongoing thing wants, and it is what makes this cheap.

Better: [SessionWindow.swift](../pm-swift/Sources/PmLib/SessionWindow.swift) already gives occurrence-tracking away for free. A session is a *sitting*, split when the notes file has been untouched for ninety minutes. A weekly 1:1 is therefore one session per occurrence with no recurrence machinery at all — seven days is comfortably past the window, so sitting down on Thursday opens a new dated heading on its own, and a follow-up note typed an hour later joins it.

```
## Sessions

### Thu, Aug 21, 2026
- [ ] send Dana the levelling doc due: 2026-08-25
Talked through the promo case. She wants the scope conversation before comp.

### Thu, Aug 14, 2026
- [x] share the team survey results
```

Nothing in that needs inventing. What needs changing is the frame around it.

## What is actually project-shaped

| Assumption | Where it lives | Why it breaks |
|---|---|---|
| Folder is `CODE-NNN Title` | `buildProjectPattern`, [Projects.swift:3](../pm-swift/Sources/PmLib/Projects.swift:3) | An Area isn't the twelfth of anything. Numbers are for things that arrive in sequence and end. |
| Problem and Approach | [templates/notes.md](../templates/notes.md), `serializeNotes` | Both describe a finish line: what's wrong, and how it gets fixed. An Area has neither. |
| Health is `done/total` | `ProjectEntry`, [ProjectIndex.swift:44](../pm-mac/PM/Model/ProjectIndex.swift:44) | 47% complete on *Team 1:1s* is a number that will never mean anything. |
| Archive is the exit | `ProjectScope.opposite`, [ProjectMove.swift:11](../pm-swift/Sources/PmLib/ProjectMove.swift:11) | Areas are handed off or dropped, not finished — and `opposite` hardcodes a two-place world. |
| `deliverables/`, `previews/` | `defaultSubfolders`, [Config.swift:38](../pm-swift/Sources/PmLib/Config.swift:38) | A standing responsibility has resources and notes; it doesn't ship. |

Note what isn't in that table: the parser, task identity, focus, the dispatcher, the quick bar's capture grammar. `TaskRef` keys on project name plus ISO date plus digest ([task-identity.md](task-identity.md)), and an Area is just another project name. None of that moves.

## Where the divergence is allowed to live

Five differences is enough to scatter `if kind == .area` across the CLI, the library, the app and the extension, and then the only way to know how the two kinds differ is to walk the code and collect the branches. That is the failure worth designing against, so:

**One type owns every difference, and no call site branches on kind.**

```swift
// PmLib/ProjectKind.swift

public enum ProjectKind: String, Codable, Sendable, CaseIterable {
    case project, area
}

public enum HeaderSection: String, Codable, CaseIterable {
    case summary, problem, goals, approach
}

public extension ProjectKind {
    /// The header sections a document of this kind is written with, in document order.
    var headerSections: [HeaderSection] {
        switch self {
        case .project: [.summary, .problem, .goals, .approach]
        case .area:    [.summary, .goals]
        }
    }

    /// Whether its names carry a `CODE-NNN ` prefix and draw a number.
    var isNumbered: Bool { self == .project }

    /// Which kind a folder is, read off its name — never stored.
    static func of(folderName: String) -> ProjectKind

    /// Where it lives unarchived, which is where unarchiving returns it to.
    var homeScope: ProjectScope
    func root(in paths: ResolvedPaths) -> String

    /// The scaffold a new one is created with.
    func subfolders(in config: PmConfig) -> [String]

    /// What putting one away is called.
    var retireVerb: String { self == .project ? "Archive" : "Put Down" }
}
```

Everything downstream *reads* those properties rather than re-deciding: `serializeNotes` walks `kind.headerSections`, `createProject` consults `isNumbered` / `root` / `subfolders`, the app's header form renders the same section list, the sidebar's kind filter is `ProjectKind.allCases`, and the menu item's title is `retireVerb`.

The invariant that makes it hold: **no call site decides anything by comparing against a specific kind.** A difference that can't be phrased as a property of the kind is the signal to add a property, not to branch where it's needed. Grepping one symbol then gives the complete list of every place the two kinds part ways, and adding a third kind — if that ever happens — is a data change in one file rather than a hunt.

The rule is about *deciding*, not about mentioning. Selecting rows by kind — the sidebar's kind filter, the partition that pulls Areas into their own section — is a query, and comparing there is exactly what it means. What isn't allowed is a call site working out for itself what an Area should *do*: the first pass of the app had a row deciding `kind == .area` before it showed a date, and that belongs behind `showsProgress`, where the ring reads it too.

One more property, worth naming because it's free: **the read path doesn't diverge at all.** `parseNotes` reads whatever sections are present in a document and always has; it needs no kind and gets none. Only writing and presenting consult it.

## The Area document

An Area's header is a **subset** of a project's, not a different vocabulary:

```markdown
# Team 1:1s

> [!summary] Summary
> Weekly 1:1s with the four people reporting to me.

> [!info] Goals
> 1.  everyone has a current growth plan
> 2.  no one goes two weeks without a conversation
> 3.  

## Links

## Learnings

## Sessions
```

Summary and Goals carry over; Problem and Approach are omitted. Goals reads differently here — standing rather than terminal, the state being held rather than the thing being driven at — but it's the same field, the same three numbered slots, and the same editor.

This is why the divergence stays small. There is no new callout, no new regex, no new field on `ProjectNotes`, and no change to the manifest's published shape or to Raycast's mirrored types. `serializeGoals` and `extractGoals` already exist and are already tested.

`## Learnings` does the work the header doesn't. On a project it collects what you found out on the way to done; on an Area it's the section that accumulates for years, and it's where a standard discovered in practice belongs — rather than in a field filled in on day one and never revisited.

### Omission has to be a write-side rule

`serializeNotes` ([NotesSerialize.swift:57](../pm-swift/Sources/PmLib/NotesSerialize.swift:57)) writes a fixed skeleton, and `notes.setDetails` falls back to a full re-serialize whenever sessions differ. So "the template just leaves Problem out" isn't enough — the first detail edit would put an empty Problem callout back into every Area file.

It takes the kind instead, and emits a section when:

```
kind.headerSections.contains(section)  ||  the section is non-empty
```

The first clause is the rule; the second is what keeps it from destroying anything. An Area never grows an empty Problem callout it has no use for, and a Problem someone typed into an Area by hand in Obsidian is preserved rather than silently dropped on the next write. Both directions need a round-trip test.

## Identity, on disk

```
{paraPath}/
  active/     W-12 Website Refresh/
  archive/    W-04 Old Thing/
  areas/      Team 1:1s/
                docs/Notes - Team 1:1s.md
                resources/
```

A third root beside active and archive, reached by a new `areasPath` config key resolving the way the other two do (explicit value, else `{paraPath}/areas`). This costs nothing in identity: a project key is already `basePath:name`, so `~/PARA/areas:Team 1:1s` is a valid key today, and everything holding a key — `focused.json`, open windows, the store registry — keeps working without knowing an Area exists.

**Scan rule.** Projects are found by regex over folder names. Areas can't be, since their names are arbitrary. An Area is a directory under `areasPath` whose notes file resolves — one `stat` per folder, the same test `pm notes path` already makes, and it means a stray folder dropped into `areas/` is ignored rather than appearing as an empty Area.

**Scaffold.** `docs/` and `resources/`, from a new `areaSubfolders` config key. The rest is project vocabulary.

**`ProjectScope` gains a third case, and `opposite` goes.** `opposite` worked while there were two roots and stopped the moment there were three: everything archives into the one `archive/` — one archive, as PARA has it — but what comes back out goes to `active` or to `areas` depending on what it is.

The first draft of this said the answer would be *recorded* when a folder was put away. That was wrong, and the fix is better than the thing it replaces: **the kind is derived from the folder's name, never stored.** `W-12 Website Refresh` and `Team 1:1s` are not the same shape, so an archived folder still says which it is a year later, and both kinds can share one archive with no marker file at all.

A stored field would have to survive being moved in Finder, renamed in Obsidian, and restored from a backup, and would be silently wrong the first time it didn't. Folder names are already how PM identifies a project; this asks them one more question. It also means the grammar `projectTitle` was taught in step 1 — strip a prefix only when there is one — *is* the kind discriminator, shared rather than stated twice.

The cost is that renaming a project's folder to drop its prefix turns it into an Area. That's the same bargain every other name-derived fact here makes, and it is at least visible.

### The defect this depended on — fixed

`projectTitle` ([NotesHelpers.swift:42](../pm-swift/Sources/PmLib/NotesHelpers.swift:42)) stripped the code prefix by splitting on the first space and keeping the rest. Correct for `W-12 Website Refresh`; wrong for every unprefixed name. The folder `Team 1:1s` yielded the title `1:1s`, so `getNotesPath` wrote `docs/Notes - 1:1s.md`.

`resolveNotesPath` would have hidden it on reads — it falls back to any `Notes - *.md` in `docs/` — which is precisely why the write side had to be fixed rather than left to it: the fallback keeps finding the right file while every write mints the wrong one beside it.

It now strips only a name matching `^[A-Za-z]+-\d+\s+`. Tests in `NotesHelpersTests`.

## In the app

**Sidebar.** Areas get their own section, below the projects. Projects are the changing foreground; Areas are the standing context that's always there, and interleaving them into the domain groups would bury them. Grouping (`by domain`, `by due`) doesn't apply, so the Areas section renders flat, sorted by name or recency — `ProjectSortOrder.code` has nothing to sort on and is skipped rather than falling back to zero. The filter grows a kind axis beside the existing active/archived one.

**No ring.** The completion ring is `done/total` and an Area has no denominator. The row shows its open-task count and last-touched date in the same slot. Same in the menubar: an Area can be the focused project, and while it is, the focused task shows without a progress arc around it.

**Quick bar.** Unchanged. `@` search finds Areas alongside projects — `ProjectSearch`'s subsequence match never cared about the code prefix — and capture appends to the current session identically, because `currentSessionPreservingFormat` is about the file, not the kind.

**New Area.** Title only. No domain picker, no number, no dry-run preview of the folder name, because the folder name is the title.

**Header editor.** The form was four hardcoded fields; it renders `kind.headerSections` instead. This is the one place in the app where the kind has to be consulted rather than merely displayed: the *read* view already hides a blank section and so needs no kind, but offering a field is what puts content in it, and the serializer keeps an omitted section precisely when it isn't empty. An Area given a Problem box would get a Problem, and it would stick.

## The API surface

**An Area is a project with a kind, not a second entity.** No `area.*` actions. `task.add`, `session.start`, `session.note`, `notes.addLink`, `task.focus`, `focus.get` and every query already take a project reference and keep working untouched; publishing parallel actions would double the manifest to say the same things twice.

Three things change:

- `project.create` takes `kind`, and rejects `domain` when the kind is `area` rather than ignoring it.
- `project.list` takes a `kind` filter, and every project result carries its kind.
- `notes.setDetail` refuses a Problem or Approach on an Area — the same rule the serializer follows, enforced where the caller can be told about it instead of discovering that a field it sent didn't stick.

The contract went to **1.2.0**, and Raycast's generated client was regenerated from it.

One thing this didn't need, which is the point: **`resolveProjectPath` is where Areas actually became usable.** It's the single place every surface turns a name into a thing, so teaching it the third root is what made `task.add`, `session.note`, `notes.get`, `task.focus` and the rest work on an Area without one of them changing.

`project.focus` did need fixing on the way past — it built its key from `activePath`, which was the same string for every project and is wrong the moment something outside `active/` can be focused.

## What this deliberately doesn't do: cadence

The tempting design is a declared rhythm — `weekly`, `monthly` — with an Area going overdue for attention when its last session is older than the interval, feeding the Up Next band, `task.whatsDue` and a drain-down ring. It's computable from data already on hand, and it answers the real objection to Areas: a project earns attention through due dates and progress, so an Area with neither could rot silently at the bottom of the list.

It's deferred anyway, because the better version of the idea is calendar-shaped — surfacing the right notes *during* the meeting rather than nagging that a meeting is overdue — and that's a larger conversation that applies to projects just as much. Building an interval field first would leave the calendar work arguing with an existing feature instead of replacing nothing.

Until then Areas have one time signal, free: `modified`, the notes-file mtime the index already reads, shown as last-touched and sortable by recency. Not a nag. Enough to see which Area has been ignored.

## Taking on a folder you already keep

An Area is "a directory PM has written notes into". That rule is what stops PM claiming every folder it can see — and it is also what leaves a PARA vault's existing Areas unreachable, because they were there long before PM knew the word. Adopting is the door the rule needs.

```
pm adopt              # what could become an area
pm adopt "Work"       # take it on
```

**It writes one file and creates the one directory to put it in.** No `resources/`, no scaffold, no tidying. A folder you already keep is already organized the way you organize things, and a command that rearranged it in passing would be a worse deal than one that left it alone. `createProject` builds a folder and so decides its shape; this one is a guest.

`getAdoptableFolders` is the exact complement of `getAreaFolders` over the same set — area-shaped directories, split by whether they carry notes. Every such folder is in one list or the other, never both and never neither, and there's a test that says so. That's what makes the picker in the app and the list in Raycast trustworthy: what they offer is precisely what isn't already an Area.

Only Areas. Adopting a folder as a *project* would mean renaming it to `CODE-NNN Title` — taking a number and changing what the folder is called on disk — which is a different act with a different blast radius, and nobody has asked for it.

## Still missing, on purpose

**Case.** The fallback derives `areas`; a vault laid out as `Projects` / `Archive` / `Areas` has the capitalized form. On case-insensitive APFS they are the same directory, which is why it works — on a case-sensitive volume PM would make a second one beside it. Preferring an existing case variant when the parent has one is a small fix nobody has needed yet.

## Order of work

1. ~~`projectTitle` strips only a real code prefix, with tests.~~ **Done.**
2. ~~`ProjectKind` and `HeaderSection` in PmLib.~~ **Done.**
3. ~~`areasPath` and `areaSubfolders` in config; the Area scan; `ProjectScope` third case; the kind derived from the folder name.~~ **Done.**
4. ~~`serializeNotes` takes a kind and applies the emit rule.~~ **Done.**
5. Creating one: an Area template, and a `createArea` beside `createProject` that draws no number. `project.create` / `project.list` / `notes.setDetails` take kind; manifest bump.
6. App: index, sidebar section and kind filter, New Area, the section-list header form.
7. Raycast: New Area, and the kind filter in List Projects.

Steps 2–5 are headless and testable. Nothing in 6 or 7 needs a decision they don't already settle.
