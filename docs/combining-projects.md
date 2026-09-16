# Combining projects

**Status:** the master is built, 2026-09-16 — backlog 37; the merge is decided in outline and waits.
Two asks with one shape: a project made of projects (a *master*), and folding one project into another
(a *merge*).

Built: `pm-part-of` and its one-level check in PmLib (`ProjectPartOf.swift`, `ProjectPartOfTests`),
`project.setPartOf` and `project.get`'s `partOf`/`members` (contract 1.9.0), `pm part-of`, a rename of a
master rewriting its members' links, and in the app the rolled-up counts (`ProjectIndex.rollingUp`),
members nested in the sidebar, Projects and Part of on the card, Part Of… on a project's menu, and the
offer to archive members with their master.

## What `ProjectLifecycle` can do today

Move a project between scopes, rename it, adopt a folder
([ProjectLifecycle.swift](../pm-mac/PM/Model/ProjectLifecycle.swift)) — each of which moves one folder
whole. Nothing says one project is part of another, and nothing combines two documents.

## A project made of projects

### Taken

- **The master is an ordinary project.** It has its own folder, notes file, sessions and tasks — the
  work that belongs to the whole rather than to any part. Nothing about a master's document changes.
  This is the [areas.md](areas.md) move again: no second document type, a relationship instead.
- **"Part of" lives on the member**, as a frontmatter property beside `pm-icon`:

  ```yaml
  ---
  pm-part-of: "[[S-004 Project Manager Tool]]"
  ---
  ```

  On the member, because a member has one master and a master has any number of members — the same
  reason a wait lives on the task and not on the thing waited for ([links.md](links.md)). One line per
  member, written when you say so, never computed into anyone else's file. In frontmatter rather than
  the body, because it is a fact about the whole document, which is what `pm-icon` already established
  that frontmatter is for — and because Obsidian reads a quoted wikilink in a property as a real link, so
  the vault's backlinks and graph see the grouping without being told.
- **Resolved the way a wait is.** `pm-part-of` names a project the way `waiting:` does, through the one
  resolver both use, active before archived, and read through `WikilinkResolver` so a master renamed
  after its members were written still resolves. A name that resolves to nothing is shown as written and
  treated as no master.

### What a master shows

A master's card and window list its members, computed at read time from the folder scan — nothing is
stored on the master. For each member: its name and icon, its progress, its next open task, and whether
it is archived. The same numbers `ProjectIndex` already has for the sidebar.

### Decided (2026-09-16)

- **M1 — members on the master's card and in the sidebar.** A section titled Projects on the master's card, and
  members nested under their master in the sidebar's list.
- **M2 — rolled up.** A master's progress and its next due date count its members' tasks as well as its
  own, because a master is the whole and "how far along is this" is asked of the whole.
- **M3 — one level.** A member cannot be a master, and a master cannot be made a member. Refused at the
  write, with the reason, rather than resolved by nesting.
- **M4 — archiving a master offers to take its members.** Archiving a member leaves it listed on the
  master, marked done.
- **M5 — how it is set.** `project.setPartOf` (`partOf`, or `clearPartOf`), `project.get` answering
  `partOf` and `members`, `pm part-of`, and a Part Of… item on a project's menu. Areas can be either.

## Folding one project into another

### Taken

- **Sessions are interleaved by date, each marked with where it came from.** A's sessions go into B's
  `## Sessions` in date order, each labelled `from A` — appended to any label it already had — so the
  merged history is honest that it was two histories. Tasks stay inside the sessions that hold them, so
  their `TaskRef`s keep their date, and their digests do not change.
- **A is archived, not deleted.** Its folder stays in the archive with a note at the top saying where
  its work went, so a `[[A]]` written anywhere still resolves to something that says so.

### Open, for when it is built

- **G1 — the framing callouts.** A's summary, problem, goals and approach appended under B's with a
  `from A` line, or left in the archived A and linked.
- **G2 — Links and Learnings.** Unioned into B's, duplicates dropped by address.
- **G3 — the rest of A's folder.** Its canvas, attachments and subfolders moved into B, or left in the
  archived A.
- **G4 — undo.** One journal entry covering both files, or a merge that is only undone by hand.
