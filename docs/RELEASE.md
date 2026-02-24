# Release checklist (project-manager)

Use this when cutting a new version (e.g. 0.2.0). Version exists in three places; all must stay in sync.

## 1. project-manager repo

- [ ] Bump `version` in **package.json** (root).
- [ ] Commit and push to `main`.
- [ ] Create and push tag:  
  `git tag v0.2.0 && git push origin v0.2.0`
- [ ] (Optional) Create a GitHub Release from the tag so the publish workflow runs and publishes to GitHub Packages.

## 2. homebrew-s tap

- [ ] In **Formula/project-manager.rb** update:
  - **url** ref: `refs/tags/v0.1.0.tar.gz` → `refs/tags/v0.2.0.tar.gz`
  - **version**: `"0.1.0"` → `"0.2.0"`
- [ ] On a machine with `HOMEBREW_GITHUB_API_TOKEN` set, run:  
  `brew fetch shanberg/s/project-manager`  
  and copy the **Actual** (computed) SHA256 from the mismatch message.
- [ ] Set **sha256** in the formula to that value.
- [ ] Commit and push the formula changes to the tap.

## 3. One-time per machine (new installs)

Users need one PAT with **repo** and **read:packages**, set in two places:

- `HOMEBREW_GITHUB_API_TOKEN` (env or shell profile) — for the formula’s private tarball.
- `~/.npmrc`: `//npm.pkg.github.com/:_authToken=YOUR_PAT` — for `@shanberg/project-schema` during build.
