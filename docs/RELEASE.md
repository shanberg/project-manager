# Release (project-manager)


One command: bump version, push, tag, build Swift binary, create tarball, upload to GitHub release, update Homebrew formula, push tap.

From the **project-manager** repo, with `GITHUB_TOKEN` or `HOMEBREW_GITHUB_API_TOKEN` set:

```bash
npm run release -- patch    # 0.1.2 → 0.1.3 (bug fixes)
npm run release -- minor    # 0.1.2 → 0.2.0 (new features)
npm run release -- major    # 0.1.2 → 1.0.0 (breaking changes)
npm run release -- 0.2.0    # or set an exact version
```

The script reads the current version from `package.json`, bumps it (or uses the version you pass), writes it back, commits and pushes, creates tag, then runs `scripts/build-release-tarball.sh` to build the Swift CLI for **arm64 only** (`swift build -c release --triple arm64-apple-macosx`) and pack `pm` into `project-manager-<version>.tar.gz`, uploads the tarball to the GitHub release, **builds and notarizes the native `PM.app`** (see below), uploads it too, and updates both the Homebrew formula and cask (sha256 + version). **Run the release from an Apple Silicon Mac.** **`package.json` must have a `"version"` field**

## Native app (PM.app) signing & notarization

The menubar app is distributed as a notarized, Developer ID–signed zip via the Homebrew **cask** `pm` (`Casks/pm.rb` in the tap). Consumers get it with `brew install --cask shanberg/s/pm` and it opens with no Gatekeeper prompt.

One-time setup on the release machine (already done for the current maintainer):

1. **Developer ID Application certificate** in the login keychain — verify with `security find-identity -v -p codesigning` (look for `Developer ID Application: … (9626CTDMM9)`). Create it in Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ `+` ▸ Developer ID Application.
2. **notarytool keychain profile** named `notary`:
   ```bash
   xcrun notarytool store-credentials notary --apple-id <you>@… --team-id 9626CTDMM9
   ```
   (paste an **app-specific password** from account.apple.com, not your Apple ID password).

Signing config lives in `pm-mac/project.yml`: **Debug** signs with Apple Development (keeps local TCC/Full Disk Access grants stable across rebuilds); **Release** signs with Developer ID + hardened runtime (required for notarization).

`scripts/build-app-dist.sh <version> [notary-profile]` does the whole app chain standalone — Release build → re-sign with a secure timestamp (a plain `xcodebuild build` omits it, which notarization rejects) → verify hardened runtime → zip → `notarytool submit --wait` → check the verdict is **Accepted** → `stapler staple` → re-zip → `spctl` assessment. Output: `dist/PM-v<version>.zip`. `scripts/update-cask.sh <version> [sha256]` bumps the cask.

`npm run release` runs both automatically. Pass `SKIP_APP=1` to release only the CLI (e.g. from a machine without the cert/profile); `NOTARY_PROFILE=<name>` overrides the profile name. If notarization is rejected, the script prints Apple's log — fetch it again with `xcrun notarytool log <submission-id> --keychain-profile notary`.

**Tap location:** Default is `../homebrew-s`. Override with `TAP_DIR` if your tap lives elsewhere.

**Optional:** To only update the formula (e.g. after releasing another way): `npm run update-homebrew-formula -- v0.2.0`

**Homebrew formula:** The tarball contains a single directory `project-manager-<version>/` with a `pm` binary. The formula in the tap should install that binary (e.g. `bin.install "pm"`). If the formula still expects the old Node tarball layout, update it once to install the Swift binary.

## Install (users)

Users install via the Homebrew tap: `brew tap shanberg/s`, then `brew install shanberg/s/project-manager` (the `pm` CLI) and `brew install --cask shanberg/s/pm` (the `PM.app` menubar app). The formula and cask fetch their assets from this repo’s GitHub releases.
