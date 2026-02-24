# Release checklist (project-manager)

Use this when cutting a new version (e.g. 0.2.0). Version exists in three places; the first two are manual, the tap can be updated with the script.

## 1. project-manager repo

- [ ] Bump `version` in **package.json** (root).
- [ ] Commit and push to `main`.
- [ ] Create and push tag:  
  `git tag v0.2.0 && git push origin v0.2.0`
- [ ] Create a GitHub Release from the tag (so the publish workflow runs and, if configured, the Homebrew formula is updated).

## 2. homebrew-s tap (run locally)

From the **project-manager** repo, with `GITHUB_TOKEN` or `HOMEBREW_GITHUB_API_TOKEN` set (so the script can download the private tarball):

```bash
./scripts/update-homebrew-formula.sh v0.2.0
```

Or omit the tag to use the version from `package.json`:

```bash
./scripts/update-homebrew-formula.sh
```

The script downloads the tarball, computes sha256, and updates `Formula/project-manager.rb` in the tap (default: `../homebrew-s`; override with `TAP_DIR`). Then commit and push in the tap repo.

**Optional CI:** The **Update Homebrew formula** workflow does the same on release if you add a **TAP_PUSH_TOKEN** secret (PAT with `repo` for `shanberg/homebrew-s`). Use the script when you prefer to run it locally.

## 3. One-time per machine (new installs)

Users need **one** PAT with **repo** and **read:packages**, in **both** places:

- `HOMEBREW_GITHUB_API_TOKEN` (env or shell profile) — for the formula's private tarball.
- `~/.npmrc`: `//npm.pkg.github.com/:_authToken=YOUR_PAT` — for `@shanberg/project-schema` during build.
