# Release (project-manager)


One command: bump version, push, tag, build Swift binary, create tarball, upload to GitHub release, update Homebrew formula, push tap.

From the **project-manager** repo, with `GITHUB_TOKEN` or `HOMEBREW_GITHUB_API_TOKEN` set:

```bash
npm run release -- patch    # 0.1.2 → 0.1.3 (bug fixes)
npm run release -- minor    # 0.1.2 → 0.2.0 (new features)
npm run release -- major    # 0.1.2 → 1.0.0 (breaking changes)
npm run release -- 0.2.0    # or set an exact version
```

The script reads the current version from `package.json`, bumps it (or uses the version you pass), writes it back, commits and pushes, creates tag, then runs `scripts/build-release-tarball.sh` to build the Swift CLI for **arm64 only** (`swift build -c release --triple arm64-apple-macosx`) and pack `pm` into `project-manager-<version>.tar.gz`, uploads the tarball to the GitHub release, and updates the Homebrew formula (sha256 and version). **Run the release from an Apple Silicon Mac.** **`package.json` must have a `"version"` field**

**Tap location:** Default is `../homebrew-s`. Override with `TAP_DIR` if your tap lives elsewhere.

**Optional:** To only update the formula (e.g. after releasing another way): `npm run update-homebrew-formula -- v0.2.0`

**Homebrew formula:** The tarball contains a single directory `project-manager-<version>/` with a `pm` binary. The formula in the tap should install that binary (e.g. `bin.install "pm"`). If the formula still expects the old Node tarball layout, update it once to install the Swift binary.

## Install (users)

Users install via the Homebrew tap: `brew tap shanberg/s` then `brew install shanberg/s/project-manager`. The formula fetches the tarball from this repo’s GitHub releases.
