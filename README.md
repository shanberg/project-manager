# pm - Project Manager

CLI for PARA-style project creation with domain-based numbering. **Raycast is the main frontend** – configure paths and run all commands from the extension.

## Install

```bash
cd project-manager
npm link
cd raycast-extension && npm run dev
```

Raycast will load the extension. Set **Active Projects Path** and **Archive Path** in the extension preferences (Raycast Preferences > Extensions > Project Manager).

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
pm new M "Slides Redesign"
# Creates: active/M-001 Slides Redesign/ (or M-1, M-01 depending on existing convention)

pm list              # List active projects
pm list --archive    # List archived projects
pm list --all        # List both

pm archive "M-1 Slides Redesign"   # By full name
pm archive M-1                     # By prefix (unambiguous)
pm unarchive M-1                   # Move from archive back to active
```

**Domains:** M (Marketing), DE (Design Engineering), P (Product Design), I (Internal)

## Config

- `pm config get` - Show full config
- `pm config get activePath` - Show specific key
- `pm config set activePath /path/to/active` - Update active path
- `pm config set archivePath /path/to/archive` - Update archive path

Config location: `~/.config/pm/config.json` (or `$XDG_CONFIG_HOME/pm/`)

Override: `PM_CONFIG_HOME=/custom/path pm ...`

## Numbering

Numbers are unique across both `active` and `archive`. Padding adapts to your convention:

- Start with `M-1` → next is `M-2`, then `M-10`, `M-100`
- Start with `M-01` → next is `M-02`, then `M-100` when you hit 100

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
