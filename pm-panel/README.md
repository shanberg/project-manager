# PM Panel

A small always-on-top Tauri window that shows the **current (focused) project** from the pm system. It reads `~/.config/pm/focused.json` and uses the **pm CLI** for notes data and task actions (`pm notes show`, `pm notes todo complete|focus|undo`, `pm list --all`, `pm config get`). The panel requires the **pm CLI on your PATH**.

## Requirements

- [pm](https://github.com/shanberg/project-manager) CLI installed and on your `PATH` (used for notes, project list, and task/focus mutations)
- A focused project set from Raycast or the panel’s project picker (List Projects → focus a project, or View Project)

## Permissions (macOS)

If your projects live in a protected folder (e.g. `~/Documents/PARA/Projects`), the **PM Panel app** (and the **pm** CLI it invokes) must have access. The panel reads `~/.config/pm/focused.json` and `recent-projects.json` directly and runs `pm` for notes and task actions. Grant **Full Disk Access** to the panel app so it can read the config dir; the `pm` process inherits the same environment and may need to be run from a shell that has access to your project paths.

**“The file … couldn’t be opened because you don’t have permission to view it.”** → add **PM Panel** (or the dev binary) to Full Disk Access.

**Most reliable way to add PM Panel:**

1. **Put the app where System Settings can see it:** Copy `pm-panel/src-tauri/target/release/bundle/macos/PM Panel.app` into **Applications** (drag it into the Applications folder in Finder). If you only run in dev, the running process is the binary at `pm-panel/src-tauri/target/debug/pm-panel`; you can still add the built .app to Applications just for the permission, or add that binary (see below).
2. Open **System Settings** → **Privacy & Security** → **Full Disk Access**.
3. Click **+**. In the list, open **Applications** and select **PM Panel**. Click **Open**. (If you’re in dev and only have the binary: click **+**, press **Cmd+Shift+G**, paste the full path to `pm-panel/src-tauri/target/debug/pm-panel**, press Go, select it, Open.)
4. Turn the toggle **on** for PM Panel. Click the lock at the bottom if needed so the change is saved.
5. **Quit** the panel completely (Cmd+Q), then launch it again. If it still fails, restart your Mac.

**If the + list doesn’t show PM Panel:** Drag **PM Panel** from the Applications folder (or from the bundle path above) **into** the Full Disk Access list instead of using +.

**During development** (`npm run tauri dev`), the panel process is a **child of Cursor (or Terminal)**. macOS applies the **parent app’s** Full Disk Access to the child. So either:

- **Easiest:** Add **Cursor** (or **Terminal**, if you run `tauri dev` from Terminal) to Full Disk Access. Then quit the panel and run `npm run tauri dev` again. The child process will be able to read the notes file.
- **Alternative:** Add the **debug binary** to Full Disk Access: in Full Disk Access click **+**, press **Cmd+Shift+G**, paste the full path to `pm-panel/src-tauri/target/debug/pm-panel`, press Go, select it, Open. Turn the toggle on, then quit the panel and run `npm run tauri dev` again.

The list may not show the binary by name (it can appear as a generic icon); the toggle still applies. After a rebuild, the same path is reused so the permission still applies.

## Development

```bash
cd pm-panel
npm install
npm run tauri dev
```

If `tauri dev` or `tauri build` fails with a `--ci` argument error, set `CI=0` in the environment (e.g. `CI=0 npm run tauri dev`).

## Build

```bash
cd pm-panel
npm run build
npm run tauri build
```

(Use `CI=0` before the build command if needed.)

## Configuration

- **Window:** Always on top (normal AOT), 380×120 by default, resizable.
- **Config path:** Uses `$HOME/.config/pm/focused.json`; ensure the fs scope in `src-tauri/capabilities/default.json` allows that path.
- **pm CLI:** The panel runs `pm` for `notes show`, `notes todo complete|focus|undo`, `list --all`, and `config get`. Ensure `pm` is on your PATH when running the panel.
