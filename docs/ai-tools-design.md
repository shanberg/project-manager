# AI tools over work: Notion-style design for pm

This doc breaks down how Notion creates AI tools over work, then maps that to pm’s architecture and outlines how to implement something similar using local models or an API.

---

## 1. How Notion does it

### 1.1 Two modes

| Mode | Notion | Purpose |
|------|--------|---------|
| **On-demand** | Notion Agent (chat in corner) | Draft, edit, summarize; answer questions; one-off tasks while you work. |
| **Autonomous** | Custom Agents | Run on triggers/schedules; do multi-step work in the background. |

For pm, the useful parallel is: **on-demand** = “ask about this project / this note” from Raycast or CLI; **autonomous** = scheduled or event-driven helpers (e.g. “weekly summary”, “suggest next task”).

### 1.2 Core building blocks

1. **Context**  
   - Notion: specific pages/databases (and optionally Slack, web).  
   - Agent only sees what you grant; “keep context tight” is a best practice.

2. **Instructions**  
   - Outcome-focused: “Create a weekly status update summarizing completed tasks, blockers, next steps.”  
   - Concrete format and destination: “Post in #team-updates and add to Weekly Reports database.”  
   - Boundaries and edge cases: “If no updates, post ‘No updates’.”

3. **Triggers**  
   - **Schedule**: daily/weekly/monthly.  
   - **Events**: page/database created or updated, comment added, @mention.  
   - **Slack**: new message, emoji, @mention.  
   Best practice: high-signal triggers (e.g. @mention or specific property change), not “every change”.

4. **Actions**  
   - Read from pages/databases and connected apps.  
   - Create/update pages and database rows; post to Slack.  
   - All actions are scoped to what the agent has access to.

5. **Safety and observability**  
   - Access is explicit (no full workspace by default).  
   - Activity log: what ran, what triggered it, what was done.  
   - Version history and “undo” for agent config.

So: **context (what the AI sees) + instructions (what to do) + triggers (when) + actions (what it can change)**.

---

## 2. Mapping to pm

### 2.1 Your “workspace” = projects + notes (markdown)

| Notion concept | pm equivalent |
|----------------|----------------|
| Page | Project folder + `docs/Notes - {title}.md` |
| Database | List of projects (active/archive) + structure inside each notes file (sessions, tasks) |
| Block content | Notes sections (Summary, Problem, Goals, Approach, Links, Learnings) + Sessions with task lines |
| “Context” | One or more project notes (and optionally other files in the project) |

So “context” for an AI over pm is: **one or more `ProjectNotes` (parsed from markdown) plus optional raw markdown or file paths**. You already have `notes show` (JSON) and `notes path`; that’s enough to feed a model.

### 2.2 Instructions

Same idea as Notion: outcome-focused, with format and destination.

- “Summarize the focused project’s notes and suggest the next task.”
- “From this project’s Summary and Goals, write a one-paragraph status for a standup.”
- “List open tasks in today’s session and suggest an order.”

Destination in pm = **where the result goes**: stdout, a new session body, a new file in the project, or the clipboard (for pasting into Raycast/elsewhere).

### 2.3 Triggers (when the AI runs)

| Notion-style | pm implementation |
|--------------|-------------------|
| **On-demand** | User runs a Raycast command or CLI subcommand (e.g. `pm ai ask "summarize this project"`). |
| **Schedule** | Cron (or launchd) runs a script that calls the CLI with a fixed prompt and project(s). |
| **Event** | Harder without a daemon. Could be: “after adding a session” or “after completing the focused task” by having the last step of a Raycast action call an AI command. |

Start with **on-demand only**; add schedule/event later if you want “Custom Agent”-style automation.

### 2.4 Actions (what the AI can change)

Today pm can already:

- **Read**: `pm notes show <project>` → JSON (notes + todos).  
- **Write**: `pm notes write <project>` with stdin JSON.  
- **Add session**: `pm notes session add <project> [label]`.  
- **Todo ops**: complete, add, edit, wrap, set focus (via CLI or Raycast → CLI).

So the “actions” for an AI are:

1. **Read-only**: run `notes show`, pass the JSON (and optionally paths) as context to the model; result is just text (e.g. summary, suggestion).  
2. **Write-back**: model returns a **structured response** (e.g. “new session body”, “updated summary”, “new task text”); your code calls `notes write` or session add with that payload.  

You don’t need the model to call the CLI directly. You need: (a) a **context builder** that turns `ProjectNotes` + optional extra into a prompt, and (b) a **response handler** that parses the model output and calls existing pm APIs (CLI or notes-api).

---

## 3. Implementation options

### 3.1 Local vs API

| Approach | Pros | Cons |
|----------|------|------|
| **Local model** (Ollama, llama.cpp, etc.) | No API key; data stays on machine; free at inference time. | Weaker at long context and instruction-following; need to manage model and context length. |
| **API** (OpenAI, Anthropic, etc.) | Strong instruction-following and summarization; easy to get good results. | Cost; data leaves the machine (unless you use a private endpoint). |
| **Hybrid** | Use API for “heavy” tasks (long summaries, multi-project), local for simple ones (next task suggestion). | Two code paths; need to abstract “run prompt and get text” behind one interface. |

Recommendation: **abstract the model behind a single “run prompt” interface** (e.g. `PromptRunner`). Implement one backend that calls Ollama (or similar) and one that calls an API. Then you can choose per command or via config (e.g. `pm config set aiProvider ollama|openai|off`).

### 3.2 Where the AI layer lives

- **CLI**  
  - New subcommand, e.g. `pm ai ask <project> "prompt"` or `pm ai summarize <project>`.  
  - Builds context from `pm notes show`, calls the model, prints or writes back.  
  - Fits scripts and cron; no Node required if you use Swift + HTTP to Ollama/API.

- **Raycast**  
  - New actions: “Ask AI about focused project”, “Summarize project”, “Suggest next task”.  
  - Extension calls `notes-api` to get notes, builds prompt, calls model (Node fetch to Ollama or API), then either shows result in Raycast or calls `writeNotes` / CLI for write-back.  
  - Best UX for on-demand; can share the same context-building and prompt logic with the CLI if you extract them to a small shared layer (e.g. a script or a tiny Node/Swift helper).

- **Shared layer**  
  - Context builder: “given project name, resolve path → notes show → ProjectNotes + todos.” Optionally add: path to `docs/` or other files to include.  
  - Prompt templates: e.g. “Summarize the following project notes and suggest the next task. Notes:\n{notes}\n\nFocused task: {focused}.”  
  - Response parser (for write-back): e.g. “if the user asked for ‘add a task’, look for a line like `TASK: ...` and call addTodoToTodaySession.”

Start with **one entry point** (e.g. Raycast “Ask about focused project” or CLI `pm ai ask`). Reuse the same context + prompt + runner so the second entry point is cheap.

---

## 4. Concrete implementation plan

### Phase 1: Read-only, one entry point

1. **Context builder**  
   - Input: project name (or “focused” resolved via existing logic).  
   - Use existing `getNotes(prefs, projectName)` (or CLI `notes show`) to get `ProjectNotes` + todos.  
   - Serialize to a compact text representation for the prompt (e.g. `formatNotesForDetail(notes)` plus “Open tasks: …” and “Focused: …”).  
   - Optional: add `notes.path` and allow including raw markdown or other files.

2. **Prompt runner**  
   - Interface: `runPrompt(systemPrompt?, userPrompt, contextText) → string`.  
   - Implementations:  
     - Ollama: POST to `http://localhost:11434/api/generate` (or chat endpoint).  
     - API: OpenAI/Anthropic chat completion with same system/user/context.  
   - Config: e.g. `aiProvider` (off | ollama | openai), `openaiApiKey` (or env), model name.

3. **One flow**  
   - **CLI**: `pm ai ask <project> "Summarize this project and suggest the next task."`  
     - Resolve project; get notes JSON; build context text; run prompt; print result.  
   - **Or** Raycast: “Ask AI” with a text field; same context + prompt; show result in a detail view.  
   - No write-back yet.

4. **Config**  
   - Store in pm config: `aiProvider`, `aiModel`, `openaiApiKey` (or read from env).  
   - If `aiProvider` is `off` or unset, `pm ai` exits with a clear “AI not configured” message.

Deliverable: user can ask a question about a project and get an answer with no changes to notes.

### Phase 2: Simple write-back

1. **Structured output**  
   - For “add a task” or “add a session note”, define a small format, e.g. “`TASK: <text>`” or “`SESSION_NOTE: <text>`” in the model reply.  
   - Parser extracts that and calls existing `addTodoToTodaySession` or session add.

2. **Safety**  
   - Only allow write-back when the user explicitly runs “Add task from AI” (or similar), not on every “ask”.  
   - Optionally: show the proposed change in Raycast and require “Confirm” before calling `writeNotes` or CLI.

3. **Prompts**  
   - “Given the project notes and the user request, output a single next task as: TASK: <task text>.”  
   - No generic “do anything” — one action type per command.

Deliverable: one or two write-back actions (e.g. “Suggest and add next task”) with confirmation.

### Phase 3: Triggers and reuse

1. **Scheduled**  
   - Script (e.g. `weekly-pm-summary.sh`) that runs `pm list`, picks active projects (or a configured list), runs `pm ai ask <project> "Weekly status paragraph"` and appends to a file or sends somewhere.  
   - No new pm code beyond `pm ai ask` and context building.

2. **Event-style**  
   - In Raycast, after “Complete focused task” or “Add session”, optionally run a follow-up: “Suggest next task” and show it (or offer to add it).  
   - Still on-demand from the user’s perspective; no daemon.

3. **Templates and instructions**  
   - Store a few prompt templates in config or in the repo (e.g. “Standup”, “Weekly summary”, “Next task”).  
   - `pm ai ask <project> --template standup` loads that template and fills in context.  
   - Mirrors Notion’s “clear instructions” and “definition of done” without building a full agent UI.

---

## 5. Notion best practices applied to pm

| Notion practice | In pm |
|-----------------|--------|
| Keep context tight | Context = one project’s notes (and optionally its `docs/` or a second project). Don’t send all projects by default. |
| Outcome-focused instructions | Prompts like “Summarize and suggest next task” or “One paragraph standup” rather than “do whatever you think is best.” |
| Define “done” | For write-back: “Output exactly TASK: <text>” so parsing is reliable. |
| Specific triggers | On-demand: user picks project and action. Schedule: cron + explicit project list. |
| Batch when possible | For “summarize all active projects”, build one context blob and one prompt instead of N calls. |
| Test before automating | Use `pm ai ask` manually until the output is good; then add to cron or Raycast. |

---

## 6. Summary

- **Notion** gives agents **context** (pages/databases), **instructions**, **triggers**, and **actions**; you replicate that by treating **pm’s project notes (and optional files) as context**, **prompt templates as instructions**, **CLI/Raycast/cron as triggers**, and **existing notes/todo APIs as actions**.
- **Implementation**: abstract **context building** (from `notes show` + optional files) and **prompt running** (Ollama + API behind one interface). Add **read-only** “ask” first, then **bounded write-back** (e.g. add task / add session note) with confirmation. Add **scheduled** runs via cron and **templates** for standup/weekly/next-task.
- **Local vs API**: support both via the same runner interface and config; start with one provider (e.g. Ollama) to avoid keys, then add API for better quality when needed.

This keeps the design close to Notion’s mental model (context, instructions, triggers, actions) while fitting pm’s markdown-and-CLI design and your preference for clear data flow and fail-fast behavior.
