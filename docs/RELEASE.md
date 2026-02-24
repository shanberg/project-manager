# Release checklist (project-manager)

Use this when cutting a new version (e.g. 0.2.0). Version exists in three places; the first two are manual, the tap can be updated automatically.

## 1. project-manager repo

- [ ] Bump `version` in **package.json** (root).
- [ ] Commit and push to `main`.
- [ ] Create and push tag:  
  `git tag v0.2.0 && git push origin v0.2.0`
- [ ] Create a GitHub Release from the tag (so the publish workflow runs and, if configured, the Homebrew formula is updated).

## 2. homebrew-s tap (optional if automation is set up)

If the repo has the **TAP_PUSH_TOKEN** secret (a PAT with `repo` for `shanberg/homebrew-s`), the workflow **Update Homebrew formula** runs on release and updates the formula (url ref, version, sha256) and pushes to the tap. No manual steps.

If not using automation:

- [ ] In **Formula/project-manager.rb** update url ref, **version**, and **sha256**.
- [ ] To get sha256: on a machine with `HOMEBREW_GITHUB_API_TOKEN` set, run  
  `brew fetch shanberg/s/project-manager`  
  and use the **Actual** value.
- [ ] Commit and push the formula to the tap.

## One-time: enable automatic formula updates

In this repo (project-manager): **Settings → Secrets and variables → Actions** → New repository secret:

- **Name:** `TAP_PUSH_TOKEN`
- **Value:** A classic PAT with **repo** scope (or fine-grained with read/write to `shanberg/homebrew-s`).

The **Update Homebrew formula** workflow uses it to push formula changes to the tap on each release. No need to run `brew fetch` on another machine or paste checksums.

## 3. One-time per machine (new installs)

Users need one PAT with **repo** and **read:packages**, set in two places:

- `HOMEBREW_GITHUB_API_TOKEN` (env or shell profile) — for the formula’s private tarball.
- `~/.npmrc`: `//npm.pkg.github.com/:_authToken=YOUR_PAT` — for `@shanberg/project-schema` during build.
