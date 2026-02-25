# pm - Project Manager

CLI for project creation with domain-based numbering. **Raycast is the main frontend** – configure paths and run all commands from the extension.

**Assumptions:** You use Obsidian and Raycast, follow the PARA model for file management, and have mid-size projects that benefit from some structure but aren’t epics (e.g. no full project-management tooling).

## Install

**On another computer (Homebrew)**

```bash
brew tap shanberg/s
brew install shanberg/s/project-manager
```

Then install the Raycast extension from source (clone this repo, `cd raycast-extension && npm install`, then in Raycast add the `raycast-extension` folder). Leave **pm CLI Path** empty so the extension uses `pm` from PATH.

**Local dev (this repo)**

```bash
cd project-manager
npm link
cd raycast-extension && npm run dev
```

Raycast will load the extension. Set **Active Projects Path** and **Archive Path** in the extension preferences (Raycast Preferences → Extensions → Project Manager).

## Setup

**Via Raycast:** Open Extension Preferences and set the two paths. The extension creates the config on first use.

**Via CLI:** `pm config init` – you'll be prompted for active and archive paths.

These can be anywhere (e.g. different drives, cloud sync folders).

## Usage

**Raycast (recommended):**

- **Configure Project Manager** – Open preferences to set paths
- **New Project** – Create a project (domain + title)
- **List Projects** – Browse active/archive, open in Finder, add session notes
- **Archive Project** – Move a project to archive
- **Unarchive Project** – Move a project from archive back to active

**CLI:**

```bash
pm new <domain> <title>
pm list [-a|--archive] [--all]
pm archive <name>
pm notes session add <project> [label] [--date YYYY-MM-DD]
pm notes create <project>
pm notes current-day
pm notes path <project>
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

## Config

- `pm config get` - Show full config
- `pm config get activePath` - Show specific key
- `pm config set activePath /path/to/active` - Update active path
- `pm config set archivePath /path/to/archive` - Update archive path

Config location: `~/.config/pm/config.json` (or `$XDG_CONFIG_HOME/pm/`)

Override: `PM_CONFIG_HOME=/custom/path pm ...`

## Publishing (maintainers)

The CLI is published to GitHub Packages as `@shanberg/project-manager`. Publish `@shanberg/project-schema` to the same registry first.

Create a GitHub Release (tag). The workflow in `.github/workflows/publish.yml` runs on release and publishes using `GITHUB_TOKEN` (package stays private).


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
