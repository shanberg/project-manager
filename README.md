# pm - Project Manager

CLI for project creation with domain-based numbering. **Raycast is the main frontend** – configure paths and run all commands from the extension.

**Assumptions:** You use Obsidian and Raycast, follow the PARA model for file management, and have mid-size projects that benefit from some structure but aren’t epics (e.g. no full project-management tooling).

PM tracks two kinds of thing. A **project** is numbered, lives in `active/`, and ends. An **area** is the ongoing sort — a standing responsibility, a recurring meeting — is named rather than numbered, lives in `areas/`, and doesn’t. They share everything else: the same notes file, tasks, sessions, focus and capture. See [docs/areas.md](docs/areas.md).

## Install

Requires Apple Silicon (arm64 only). The `pm` CLI runs on **macOS 13 or later**; the `PM.app` menubar app requires **macOS 26 or later**.

**On another computer (Homebrew)**

```bash
brew tap shanberg/s
brew install shanberg/s/project-manager   # the `pm` CLI
brew install --cask shanberg/s/pm         # the PM.app menubar app
```

The cask installs a **notarized, Developer ID–signed** build, so it opens on any Mac without Gatekeeper prompts, and `brew upgrade --cask pm` replaces it in place (existing Full Disk Access grants persist). If an older, self-built copy is already in `/Applications`, the cask install overwrites it cleanly.

Then install the Raycast extension from source (clone this repo, `cd raycast-extension && npm install`, then in Raycast add the `raycast-extension` folder). Paths come from pm config; the extension does not override them.

**Local dev (this repo)**

```bash
cd project-manager/pm-swift
swift build -c release   # or swift build for debug
# Binary: pm-swift/.build/release/pm (or .build/debug/pm)
# Add that path to Raycast "pm CLI Path", or copy to somewhere on PATH
# Use the release binary for best CLI responsiveness (debug is slower to start and run).

cd raycast-extension && npm install && npm run dev
```

**Benchmarking:** `PM_BENCHMARK=1 pm list` prints stage timings to stderr (loadConfig, getProjectFolders, etc.).

Raycast will load the extension. Paths come from pm config (`pm config init`). The extension reads them from pm and does not override. Set **pm CLI Path** in preferences if needed (default: Homebrew `/opt/homebrew/bin/pm`).

## Setup

**Via CLI:** `pm config init` – you'll be prompted for active and archive paths. The Raycast extension reads them from pm config and does not override.

These can be anywhere (e.g. different drives, cloud sync folders).

## Usage

**Raycast (recommended):**

- **Configure Project Manager** – View paths (from pm config), domains, structure
- **New Project** – Create a project (domain + title)
- **New Area** – Create an area (name only)
- **Take On a Folder as an Area** – Turn a folder you already keep into an area
- **List Projects** – Browse active/archive, open in Finder, add session notes
- **Archive Project** – Move a project to archive
- **Unarchive Project** – Move a project from archive back to active

**CLI:**

```bash
pm new <domain> <title>
pm new --area <title>
pm adopt [<folder>]
pm list [-a|--archive] [--areas] [--all]
pm archive <name>
pm notes session add <project> [label] [-d|--date YYYY-MM-DD]
pm notes session note <project> <text>   # Appends to today's session, creating it if needed
pm notes create <project>   # Requires valid config (active/archive paths) for template path
pm notes current-day
pm notes path <project>   # Exits 0 only if the notes file exists; 1 otherwise (for scripting)
```

**Examples:**
```bash
pm new W "Website Refresh"
# Creates: active/W-1 Website Refresh/ (or W-01, W-001 depending on existing convention)

pm new --area "Team 1:1s"
# Creates: areas/Team 1:1s/ — no number, and it never takes one

pm adopt             # Which folders in areas/ could become areas
pm adopt "Work"      # Take one on — writes a notes file into it, changes nothing else

pm list              # List active projects
pm list --areas      # List areas
pm list --archive    # List the archive (both kinds share it)
pm list --all        # List all three

pm archive "W-1 Website Refresh"   # By full name
pm archive W-1                     # By prefix (unambiguous)
pm unarchive W-1                   # Move from archive back to active
```

**Waiting on:** A task can say what it’s waiting on — a project, an area, or a person — with an inline `waiting: [[target]]`. A waiting task recedes in the list and is skipped by focus advancement, so what you’re offered next is always something you can actually start. When the project it names is archived, the wait reads as released — and PM says so once, out loud, because the tasks that were freed are usually in a project you weren't looking at. Renaming the project it names changes nothing you can see: the token resolves by the code it carries, and the current title is what gets drawn. See [docs/links.md](docs/links.md).

**The Waiting list:** One window, across every project, of everything you're waiting on, grouped by what it's waiting on — ⌃⌘W, or Waiting… from the menubar. Anything that has landed sits at the top with a button that clears the wait on the whole group. `pm api call task.waiting` answers the same question on the command line.

**In the note editor:** `@` names a project or area — a filtered list, arrow keys, Return — and writes the `[[…]]` the vault reads. `/` opens what a line can carry: make it a task, give it a due date, or start a wait (which hands straight to the `@` picker). A `[[…]]` behaves as one thing: the caret steps over it and backspace takes all of it.

**Task focus:** Each project has a single focused (“now”) task, shown in the menubar and used by Complete Focused Task, Dive In, etc. How focus moves when you complete a task (parent's first leaf → next sibling’s first leaf → parent, with fallbacks) is documented in [docs/task-focus-flow.md](docs/task-focus-flow.md).

## Config

- `pm config get` - Show full config
- `pm config get activePath` - Show specific key
- `pm config set activePath /path/to/active` - Update active path
- `pm config set archivePath /path/to/archive` - Update archive path
- `pm config set notesTemplatePath /path/to/template.md` - Custom notes template (use `{{title}}` in the file). Set to empty for built-in template: `pm config set notesTemplatePath ""`
- `pm config set areasPath /path/to/areas` - Where areas live. Unset resolves to `{paraPath}/areas`, or `areas/` beside the active folder.
- `pm config set areaNotesTemplatePath /path/to/template.md` - Custom template for areas. Separate from `notesTemplatePath` because a project template carries a Problem and an Approach, which areas don't have.

**Optional – Obsidian CLI:** If you use Obsidian (1.12+) with the built-in CLI enabled, you can route notes read/write through it so edits are indexed by Obsidian. No hard dependency: if the CLI is off or unavailable, pm uses direct file I/O. Set `useObsidianCLI` to `true`, then set `obsidianVault` (vault name) and `obsidianVaultPath` (absolute path to vault root, e.g. `~/Documents/ObsidianVault`). Example: `pm config set useObsidianCLI true`, `pm config set obsidianVault "MyVault"`, `pm config set obsidianVaultPath ~/Documents/MyVault`.

Path values are stored as entered (e.g. `~/projects/active` stays as `~/projects/active`); tilde is expanded when resolving paths. This keeps config portable across machines.

Values with spaces: quote as one argument or pass as separate words:  
`pm config set activePath "/path/with spaces"` or `pm config set activePath /path/with spaces`

Config location: `~/.config/pm/config.json` (or `$XDG_CONFIG_HOME/pm/`)

Override: `PM_CONFIG_HOME=/custom/path pm ...`

## Testing against a throwaway vault

Never exercise the app or the CLI by hand against your real PARA folder — a few minutes of
poking at "new project" leaves permanent scaffolds behind. `scripts/dev-vault.sh` points
`PM_CONFIG_HOME` at a scratch vault under `.dev-vault/` (gitignored), which the app, the CLI
and the MCP server all follow:

```
./scripts/dev-vault.sh app        # build PM.app and launch it against the dev vault
./scripts/dev-vault.sh pm list    # run the CLI against the dev vault
./scripts/dev-vault.sh shell      # a shell with PM_CONFIG_HOME already exported
./scripts/dev-vault.sh reset      # wipe it back to empty
```

`swift test` is already self-contained — every test that touches disk builds its own
`temporaryDirectory/UUID()` tree and removes it — so it needs no sandbox. This script is for
the manual passes, which are what actually leak.

## Publishing (maintainers)

The CLI is a Swift binary. Version is in `package.json` (used by the release script) and in `pm-swift/Sources/pm/Version.swift` (used by `pm --version`); keep them in sync when cutting a release. Create a GitHub Release (tag); the release script builds the Swift binary, creates a tarball, uploads it to the release, and updates the Homebrew formula. See `docs/RELEASE.md`.


## Numbering

Numbers are unique across both `active` and `archive`. Padding adapts to your convention:

- Start with `W-1` → next is `W-2`, then `W-10`, `W-100`
- Start with `W-01` → next is `W-02`, then `W-100` when you hit 100

## Project Structure

Each project gets:

```
{domain}-{number} {title}/
├── deliverables/
├── docs/
│   └── Notes - {title}.md
├── resources/
├── previews/
└── working files/
```
