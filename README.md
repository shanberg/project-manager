# pm - Project Manager

CLI for PARA-style project creation with domain-based numbering. **Raycast is the main frontend** – configure paths and run all commands from the extension.

## Install

**On another computer (Homebrew only)**

1. **One-time: auth for private repo and GitHub Packages**  
   The formula downloads source from this (private) repo and fetches `@shanberg/project-schema` from GitHub Packages. On that machine, use one [classic PAT](https://github.com/settings/tokens) with **repo** (for the archive) and **read:packages** (for npm deps):
   - **Homebrew (private repo tarball):** `export HOMEBREW_GITHUB_API_TOKEN=YOUR_PAT` (or add to `~/.zshrc`).
   - **npm (private deps):** add to `~/.npmrc`: `//npm.pkg.github.com/:_authToken=YOUR_PAT`

2. **Tap and install:**
   ```bash
   brew tap shanberg/shanberg
   brew install shanberg/shanberg/project-manager
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

## Publishing (maintainers)

The CLI is published to GitHub Packages as `@shanberg/project-manager`. Prerequisite: publish `@shanberg/project-schema` to the same registry first.

**Manual publish (private) — recommended (no `npm login`, no legacy auth):**

GitHub Packages does not support web-based or OAuth login for npm; auth is token-only. The current approach is to put your token in config and run `npm publish`:

1. **Create a classic PAT** (GitHub Packages npm does not support fine-grained tokens yet). GitHub → Settings → Developer settings → [Personal access tokens](https://github.com/settings/tokens) → **Tokens (classic)** → Generate new token. Enable **write:packages** (and **read:packages** if you install from Packages elsewhere).
2. **Add the token to `~/.npmrc`** (create the file if it doesn’t exist):
   ```
   //npm.pkg.github.com/:_authToken=YOUR_TOKEN
   ```
   No `npm login` or legacy auth needed.
3. **Publish:** From this repo root, run `npm publish`. The package is published privately (`publishConfig.access` is `restricted`).

**Automated:** Create a GitHub Release (tag). The workflow in `.github/workflows/publish.yml` runs on release and publishes using `GITHUB_TOKEN` (package stays private). If you need a PAT for cross-repo or limits, add a `NODE_AUTH_TOKEN` repo secret.

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
