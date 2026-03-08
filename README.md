# pm - Project Manager

CLI for project creation with domain-based numbering. **Raycast is the main frontend** – configure paths and run all commands from the extension.

**Assumptions:** You use Obsidian and Raycast, follow the PARA model for file management, and have mid-size projects that benefit from some structure but aren’t epics (e.g. no full project-management tooling).

## Install

Requires **macOS 13 or later** (Apple Silicon arm64 only).

**On another computer (Homebrew)**

```bash
brew tap shanberg/s
brew install shanberg/s/project-manager
```

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
- **List Projects** – Browse active/archive, open in Finder, add session notes
- **Archive Project** – Move a project to archive
- **Unarchive Project** – Move a project from archive back to active

**CLI:**

```bash
pm new <domain> <title>
pm list [-a|--archive] [--all]
pm archive <name>
pm notes session add <project> [label] [-d|--date YYYY-MM-DD]
pm notes create <project>   # Requires valid config (active/archive paths) for template path
pm notes current-day
pm notes path <project>   # Exits 0 only if the notes file exists; 1 otherwise (for scripting)
```

**Examples:**
```bash
pm new W "Website Refresh"
# Creates: active/W-1 Website Refresh/ (or W-01, W-001 depending on existing convention)

pm list              # List active projects
pm list --archive    # List archived projects
pm list --all        # List both

pm archive "W-1 Website Refresh"   # By full name
pm archive W-1                     # By prefix (unambiguous)
pm unarchive W-1                   # Move from archive back to active
```

**Task focus:** Each project has a single focused (“now”) task, shown in the menubar and used by Complete Focused Task, Dive In, etc. How focus moves when you complete a task (parent's first leaf → next sibling’s first leaf → parent, with fallbacks) is documented in [docs/task-focus-flow.md](docs/task-focus-flow.md).

## Config

- `pm config get` - Show full config
- `pm config get activePath` - Show specific key
- `pm config set activePath /path/to/active` - Update active path
- `pm config set archivePath /path/to/archive` - Update archive path
- `pm config set notesTemplatePath /path/to/template.md` - Custom notes template (use `{{title}}` in the file). Set to empty for built-in template: `pm config set notesTemplatePath ""`

**Optional – Obsidian CLI:** If you use Obsidian (1.12+) with the built-in CLI enabled, you can route notes read/write through it so edits are indexed by Obsidian. No hard dependency: if the CLI is off or unavailable, pm uses direct file I/O. Set `useObsidianCLI` to `true`, then set `obsidianVault` (vault name) and `obsidianVaultPath` (absolute path to vault root, e.g. `~/Documents/ObsidianVault`). Example: `pm config set useObsidianCLI true`, `pm config set obsidianVault "MyVault"`, `pm config set obsidianVaultPath ~/Documents/MyVault`.

Path values are stored as entered (e.g. `~/projects/active` stays as `~/projects/active`); tilde is expanded when resolving paths. This keeps config portable across machines.

Values with spaces: quote as one argument or pass as separate words:  
`pm config set activePath "/path/with spaces"` or `pm config set activePath /path/with spaces`

Config location: `~/.config/pm/config.json` (or `$XDG_CONFIG_HOME/pm/`)

Override: `PM_CONFIG_HOME=/custom/path pm ...`

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
