# System review: smells, redundancies, best practices

**Updates applied:** (1) README tap name fixed to `shanberg/s` in project-manager and homebrew-s. (2) Unused `github_private_repository_download_strategy.rb` removed from tap. (3) Release checklist added: `docs/RELEASE.md`. (4) README auth section now says "one token, two config locations".

---

## 1. Redundancy / dead code

**homebrew-s:** `github_private_repository_download_strategy.rb` at the tap root is **unused**. The formula inlines the strategy, so nothing `require_relative`s this file. The standalone file is also an older variant (token-in-URL, no API URL, no tag parsing).

- **Risk:** Confusion and drift if someone edits the file thinking it’s used.
- **Fix (done):** Removed `github_private_repository_download_strategy.rb` from the tap.

---

## 2. Wrong tap name in README

**project-manager README** says:
```bash
brew tap shanberg/shanberg
brew install shanberg/shanberg/project-manager
```
The actual tap is **shanberg/s** (repo `homebrew-s`). So installs will fail with “Unknown tap” unless the user corrects it.

- **Fix (done):** README in project-manager and homebrew-s now use `shanberg/s` and `brew install shanberg/s/project-manager`.

---

## 3. Manual release process (no automation)

Every new version requires:

1. Tag in project-manager (e.g. `v0.2.0`).
2. In homebrew-s: update formula `url` (ref to new tag), `version`, and `sha256`.
3. Getting sha256 requires a machine that can run `brew fetch` (private repo) or a script that uses a token to download and hash.

Best practice for “release → tap update” is automation, e.g.:

- **Option A:** In project-manager, on `release: published`, trigger a workflow in homebrew-s (or a reusable workflow) that downloads the tarball with `HOMEBREW_GITHUB_API_TOKEN`, computes sha256, and updates the formula (commit + push or open PR). Requires a token with repo + write to homebrew-s.
- **Option B:** Use something like `mislav/bump-homebrew-formula-action` if it supports private repos and custom strategies (your case is source tarball + custom strategy, so may need a custom script instead).

Without automation, version/url/sha256 can get out of sync and the formula can point at the wrong tag or a wrong checksum.

---

## 4. Version in multiple places

Version and release identity live in:

- `project-manager/package.json` → `version`
- Homebrew formula → `version "0.1.0"` and url `refs/tags/v0.1.0.tar.gz`
- (Implicitly) the tag name `v0.1.0`

There is no single source of truth. Releasing 0.2.0 means updating package.json, creating the tag, and updating the formula (url ref, version, sha256).

- **Mitigation:** A short release checklist or a script that takes a version and (where possible) updates formula url + version, and reminds you to run `brew fetch` and paste sha256, or adopt automation as in §3.

---

## 5. Two auth mechanisms for “another computer”

Users need:

- **HOMEBREW_GITHUB_API_TOKEN** – for the formula’s private tarball download.
- **~/.npmrc** – for `npm install` of `@shanberg/project-schema` during formula build.

Same PAT can have both `repo` and `read:packages`; it’s one token, two places. That’s expected but could be spelled out in the README (“one PAT, set in both env and .npmrc”) to avoid people creating two tokens.

---

## 6. Custom download strategy complexity

The inlined strategy (~50 lines) is doing the right thing:

- Uses GitHub API URL + `Authorization` header (not token-in-URL).
- Skips HEAD to avoid unauthenticated request.
- Supports both `refs/heads/` and `refs/tags/`.
- Clear error when download fails.

It’s more than a one-liner but justified for a private repo. The only alternative (shared file + `require_relative`) was dropped to avoid load-path issues on other machines, so inlining is a reasonable tradeoff. No change recommended unless Homebrew adds first-class support for private archive downloads.

---

## 7. Publish workflow (GitHub Packages)

`.github/workflows/publish.yml` runs on `release: published`, uses `GITHUB_TOKEN` and `packages: write`. For a repo’s own packages this is standard. If the repo is under an org with stricter policies, you might need a PAT with SSO or a dedicated token; otherwise current setup is fine.

---

## 8. Summary of recommended actions

| Priority | Action |
|----------|--------|
| High     | Fix README: `shanberg/shanberg` → `shanberg/s`, and correct install command. |
| High     | Remove or clearly mark as legacy `github_private_repository_download_strategy.rb` in homebrew-s. |
| Medium   | Add a short release checklist (or doc) for “new version”: tag, formula url+version+sha256, push. |
| Low      | Consider automating formula bump on release (script or workflow) to avoid manual sha256 and drift. |
