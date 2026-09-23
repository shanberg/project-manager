# Away time

**Status:** designed 2026-09-23. Step 1 built. Extends [time-tracking.md](time-tracking.md).
Covers tasks: idle-time handling; "no focus" apps.

## Already true (time-tracking.md D3, `AttentionKeeper.swift`)

- Counts time on the focused project while there's input anywhere on the Mac, in any app.
- Frontmost app doesn't matter; Folio need not be in front.
- 10 min with no input → span ends, back-dated to last input. `why: "paused"`.
- Lid, sleep, screen sleep, lock → span ends at last input. `why: "slept"`.
- Input after a pause → new span. `why: "resumed"`.
- No start/stop control exists or is planned.

## Evidence (attention.ndjson, 2026-09-22 → 23)

- 17 `paused` gaps in one afternoon, 11–84 min each.
- At ≥ 20 min: 8 gaps in one afternoon → a prompt per gap is too many.
- 11 `slept`→`resumed` pairs of ~0 min (lock/screen-sleep then immediate return). Not aways.

## Behaviour

### Aways

- Away = gap between an `ended` (`paused` | `slept`) and the next `resumed` on the same project.
- Derived on read. Nothing new stored for an away itself.
- Listed only when 10 min ≤ gap ≤ 4 h. Shorter: breaks. Longer: nights.
- Unanswered away = not counted. Same as today. No cost to ignoring.
- Answers: **Count for <focused project>**, **Other project…**, **Not work**.
- "Not work" only hides the away from lists; totals unchanged.

### Where aways appear

- Menubar menu: top row, most recent unanswered away only.
- Menubar: no badge, no count, no tint.
- Time card: **Away** section below the project rows, all unanswered aways in the card's period.
- No notification. Revisit only if long aways routinely go unanswered.
- Focus panel: not used (it opens on summon only).

### Calls

- During an away, each tick checks whether any process holds the default input device
  (CoreAudio `kAudioDevicePropertyDeviceIsRunningSomewhere`). No permission prompt.
- Mic in use at any tick → the `resumed` edge carries `during: "call"`.
- UI label: **On a call**. Still asks; never counts automatically (call may be another project's).

### No-focus apps

- User-chosen list of apps, by bundle ID. Settings › Time.
- One of them frontmost → span ends at activation time. `why: "elsewhere"`.
- Activation time from `NSWorkspace.didActivateApplicationNotification`; exact, no back-dating needed.
- Grace: 60 s. Frontmost < 60 s → span not split. Those seconds still not counted.
- Leaving the app (with input) → new span, `why: "resumed"`.
- Project focus unchanged.
- App name/bundle ID never written to the log.
- An `elsewhere` gap is not an away: never listed, never asked about.

### Corrections

- Click a span on a Time card → **Give to…** another project, or **Not work**.
- Same event as counting an away (below).
- Later correction beats earlier over the same range.
- Undoable (⌘Z appends the inverse; the log is never rewritten).

## Log format

New event kind in `~/.config/pm/attention.ndjson`:

```json
{ "id": "…", "at": "…", "event": "counted",
  "from": "2026-09-23T11:07:00Z", "to": "2026-09-23T11:27:00Z",
  "project": "S-004 Project Manager Tool", "key": "…", "source": "app" }
```

- `project`/`key` absent → range is **not work**.
- `at` = when the answer was given. `from`/`to` = the range it covers.
- Overrides every span and every earlier `counted` inside `[from, to)`.
- Applied in order of `at`; a later `counted` cuts an earlier one like any span.
- Clamped to the read's `now`.
- Doesn't open or close a span.
- Undo appends `{"event":"withdrawn","ref":"<counted id>"}`; the referenced `counted` is skipped entirely.
- New `AttentionSpan.Basis`: `counted`, alongside `measured` and `inferred`.
- Filtered reads (`projects:`) derive over the whole log, then filter spans.
  Another project's `began` ends this one's span; another project's `counted` takes time from it.
- New field on `began`: `during` (`"call"`).
- New `ended.why`: `elsewhere`.

## Contract / CLI

- `time.aways` — query. Period fields as `time.spent`. Returns unanswered aways: `from`, `to`, `project`, `during`.
- `time.count` — command. `from`, `to`, optional `project`. Appends one `counted`.
- `pm time aways`, `pm time count <from> <to> [project]`.
- `time.spent` spans gain basis `counted`; report marks them as it marks `inferred`.

## UI vocabulary

- Away (not "unaccounted", "idle").
- Count (not "claim").
- Estimated (UI for `inferred`; wire value unchanged).
- On a call.

## Settings › Time (new pane)

- No-focus apps list.
- Sitting durations switch (`PMShowsSittingDuration`, moved from Notes).
- Pause threshold stays hardcoded at 10 min.

## Privacy facts

- Log is local, unsynced, plain NDJSON.
- Log holds only: project, time, reason, source, focused task text.
- No app names, window titles, keystrokes, or screen content.

## Build order

1. `counted` event + derivation in `AttentionLog` (pure, tested): override, overlap, not-work, midnight split.
2. `time.aways` derivation (pure, tested): bounds, 0-min `slept` pairs excluded, `elsewhere` excluded.
3. Contract + CLI: `time.aways`, `time.count`, `pm time aways|count`.
4. No-focus apps: `AttentionKeeper` + Settings › Time pane.
5. Call hint in `AttentionKeeper`.
6. Menubar away row.
7. Time card: Away section, then span corrections.

## Not in this pass

- Notifications for aways.
- Auto-counting calls.
- Calendar events as evidence (waits on calendars, views.md).
- A configurable pause threshold.
- Fragmentation / switching stats (separate task).
