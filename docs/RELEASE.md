# Release (project-manager)


One command: bump version, push, tag, update Homebrew formula, push tap.

From the **project-manager** repo, with `GITHUB_TOKEN` or `HOMEBREW_GITHUB_API_TOKEN` set:

```bash
npm run release -- patch    # 0.1.2 → 0.1.3 (bug fixes)
npm run release -- minor    # 0.1.2 → 0.2.0 (new features)
npm run release -- major    # 0.1.2 → 1.0.0 (breaking changes)
npm run release -- 0.2.0    # or set an exact version
```

The script reads the current version from `package.json`, bumps it (or uses the version you pass), writes it back, then commits and pushes, tags, downloads the tarball and updates the formula with the correct sha256, then commits and pushes the tap. **`package.json` must have a `"version"` field** (e.g. `"0.1.4"`) so the script can bump it; the script will fail with a clear message if it’s missing.

**Tap location:** Default is `../homebrew-s`. Override with `TAP_DIR` if your tap lives elsewhere.

**Optional:** To only update the formula (e.g. after releasing another way): `npm run update-homebrew-formula -- v0.1.3`

## Install (users)

Users install via the Homebrew tap: `brew tap shanberg/s` then `brew install shanberg/s/project-manager`. The formula fetches the tarball from this repo’s GitHub releases.
