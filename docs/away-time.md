# Away time

**Status:** designed 2026-09-23. Steps 1–2 and quiet focus built. Extends [time-tracking.md](time-tracking.md).
Covers tasks: idle-time handling; "no focus" apps.

## Timekeeper (`AttentionKeeper.swift`)

- Counts time on the focused project while there's input anywhere on the Mac, in any app.
- Frontmost app doesn't matter; Folio need not be in front.
- 10 min with no input → span ends, back-dated to last input. `why: "paused"`.
- Lock, user switch → span ends at last input. `why: "locked"`.
- System sleep, lid → span ends at last input. `why: "slept"`.
- Display sleep → nothing. Not a leave.
- Lock or sleep while already paused → extra `ended` written at that moment, as a marker inside the gap.
- Input after the pause moment → new span. `why: "resumed"`.
- Checks every 60 s; every 5 s while paused, so a resumption is stamped within ~5 s of the first input.
- No start/stop control exists or is planned.

### Fixed 2026-09-23

- Phantom resumes: a span ended by display sleep resumed on the next check with no new input
  (last input < 10 min old), then paused again at the same moment. Source of the log's 0-min
  `slept`→`resumed` pairs. Resuming now requires input after the pause.
- Logs before 2026-09-23: `slept` also covers display sleep and lock. Read as a leave (never overcounts).

## Evidence (attention.ndjson, 2026-09-22 → 23)

- 17 `paused` gaps in one afternoon, 11–84 min each.
- At ≥ 20 min: 8 gaps in one afternoon → a prompt per gap is too many.
- 11 `slept`→`resumed` pairs of ~0 min: phantom resumes (above).
- Typical agent work: ~1 min typing, then a wait of 10–80 min with no input.
- Display sleep on this Mac: 2 min on battery, 15 on power.

## Behaviour

### Gaps

- Gap = from an `ended` (`paused` | `slept` | `locked`) to the next `began` on any project.
- Gaps less than 30 s apart join into one (`awayBlip`).
  Cause: single inputs (keep-awake jiggle, nudged mouse) resume a span for seconds; the next pause back-dates to them.
  Seen 2026-09-22: 5 gaps at 15-min intervals = one 80-min gap.
  30 s, not longer: a typed prompt is a real return.
- A joined gap is judged whole. Spans inside it are removed.
- Derived on read (`AttentionLog.gaps`). Nothing new stored.

### Quiet focus

- Amends time-tracking.md D3 ("idle time is never counted").
- A gap is focus when all hold:
  - opened by `paused`, with no `slept` / `locked` marker in it;
  - no `elsewhere` in it;
  - ended by a `began` on the same project;
  - ≤ 15 min (`longestQuiet`).
- Focus gap → filled as a `measured` span, joined to the spans either side.
- Reason: reading or thinking about agent work, or testing it with a dark screen, is still work.
- Past 15 min the whole gap is an away, not the first 15 min of it.
  An unlocked lunch and a long agent run look identical; only you know which.
- A `counted` still beats quiet: "not work" over a quiet gap removes it.

### Aways

- Away = a gap that isn't quiet focus and has no `elsewhere` in it.
- Labelled with the project the gap interrupted.
- Listed only when 10 min ≤ away ≤ 4 h. Shorter: breaks. Longer: nights.
- Still going (no `began` yet) → not listed.
- Any standing `counted` overlapping an away → answered, not listed. Touching at an edge doesn't count.
- A range keeps aways that began in it.
- Unanswered away = not counted. No cost to ignoring.
- Real log, 2026-09-22 → 23: 9 aways, 1 quiet gap. Old logs mostly read as leaves (see Fixed).
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
