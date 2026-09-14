---
name: pm-ship
description: Ship a project-manager release, or replace the Folio.app installed on this Mac with a fresh build from the working tree. Use when asked to release, ship, cut a version, bump the version, publish to Homebrew, or to "install", "make it live", or update the running/installed app so a change can be seen.
---

# Shipping and installing project-manager

Two jobs, independent of each other. `install` is the local one you'll reach for constantly;
`release` is the public one.

## Install the app on this machine

A successful `xcodebuild` changes nothing the user can see — the app they run is
`/Applications/Folio.app`, and Folio is a menubar-only agent that keeps running the old build until
it's swapped out. To make a change live:

```bash
./scripts/install-app-local.sh
```

Builds Debug into `pm-mac/.build-dev`, quits the running Folio, replaces `/Applications/Folio.app`,
re-registers it with LaunchServices, and relaunches. `--release` builds Release instead;
`--no-launch` skips the relaunch. It regenerates the Xcode project itself when `project.yml`
is newer than the pbxproj.

Notes:
- Debug keeps the app's Full Disk Access grant across rebuilds (stable signing identity in
  `pm-mac/project.yml`), so prefer it.
- Confirm the new code is really in there before claiming it works — Debug builds put the code
  in `Folio.debug.dylib`, not the small `Folio` stub, and Swift inlines short literals, so probe with
  a long one:
  `strings -a /Applications/Folio.app/Contents/MacOS/Folio.debug.dylib | grep -F "<a long literal you just added>"`
- `open "pmpanel://show"` summons the focus panel, `open "pmpanel://window"` opens a project
  window, `~/.config/pm/pm-mac.log` shows it launched. Screenshots and window queries are
  blocked for the shell, so the *visual* result has to be confirmed by the user.
- Never launch the copy in `.build-dev` as a second instance — two bundles sharing
  `com.stuarthanberg.pm` make Siri bind to the stale one.

## Ship a release

```bash
npm run release -- patch    # or minor | major | an exact version like 0.34.0
```

One command: bumps `package.json` (and the Swift `pmVersion`, and `project.yml`), commits,
pushes, tags, builds the arm64 CLI tarball, builds + notarizes `Folio.app`, uploads both to the
GitHub release, and updates the Homebrew formula and cask in the tap.

**It pushes and tags before it builds the app.** Everything after the tag — notarization, the
app upload, the cask, the formula — can fail on its own, and when it does the version is already
public with nothing behind it. So: check first, don't pipe, verify after.

### Preflight, before the bump

Seconds each, and each one is a thing that has actually failed:

```bash
git status --short                                   # nothing unrelated in the tree
git rev-parse --abbrev-ref HEAD                      # main
gh auth status                                       # the upload credential
xcrun notarytool history --keychain-profile notary   # the signing credential
```

- **Commit or stash everything else first.** The script commits only the version files but then
  runs `git push`, so unrelated work in the tree either goes along for the ride or gets left in
  a confusing half-state.
- **If notarytool doesn't answer, stop — before the bump.** It fails closed and useless:
  `Error: No Keychain password item found for profile: notary`. Restoring it needs the
  maintainer's Apple ID and an app-specific password, which is theirs to type:
  `xcrun notarytool store-credentials notary --apple-id <you>@… --team-id 9626CTDMM9`.
  Ask them to run it **in their own Terminal**, and to re-run the preflight check there too —
  the credential lives in the data-protection keychain and has been visible to a Terminal while
  invisible to an agent shell (v0.35.0, 2026-09-10: same script, same machine, same shell,
  worked at 11:12 and could not find the profile at 12:39; not sandboxing, not the session, not
  the toolchain, not the profile name — all four ruled out).
  With no credential the honest options are to wait, or to ship the CLI alone on purpose with
  `SKIP_APP=1` and say so.
- Be on an Apple Silicon Mac with the Developer ID cert — it's the maintainer's machine, which
  this is.
- Pick the bump from what's actually in the diff: `patch` for fixes, `minor` for features.
  Ask if it isn't obvious.

### Running it

Run it with `run_in_background: true` and read the output file. **Never pipe it** — not through
`tee`, not `grep`, nothing: the shell reports the *last* command's status, so a release that died
comes back as exit 0 and reads as a clean run. That is precisely how v0.35.0 was announced as
shipped while the app had never been built.

Expect little from the log even when it does fail. `build-app-dist.sh` writes to a stdout the
caller captures (`APP_ZIP="$(… | tail -1)"`), so its progress and its errors both disappear; the
tell is a stray `no matches found for '==> Submitting to Apple notary service…'`, which is the
failed step's own message arriving where a filename was expected.

### Verify before saying it shipped

Exit 0 is not evidence. Look at the artifacts:

```bash
V=$(node -p "require('./package.json').version")
gh release view "v$V" --json assets --jq '.assets[].name'   # tarball AND Folio-v<V>.zip
grep -h 'version "' ../homebrew-s/Formula/project-manager.rb ../homebrew-s/Casks/pm.rb
```

Two assets, two bumped tap files. Anything less is a half-shipped release — say so plainly rather
than reporting the parts that worked.

### When it half-ships

**Don't re-run `npm run release`** — it bumps again and orphans the tag you already pushed. The
version, commit and tag are done; finish the rest by hand (0.35.0 shown):

```bash
./scripts/build-app-dist.sh 0.35.0 notary
gh release upload v0.35.0 dist/Folio-v0.35.0.zip --clobber
./scripts/update-cask.sh 0.35.0 "$(shasum -a 256 dist/Folio-v0.35.0.zip | awk '{print $1}')"
./scripts/update-homebrew-formula.sh v0.35.0
git -C ../homebrew-s add Formula/project-manager.rb Casks/pm.rb \
  && git -C ../homebrew-s commit -m "project-manager 0.35.0" && git -C ../homebrew-s push
```

A `dist/Folio-v<version>.zip` left behind by a failed run is the **pre-notarization** zip. It is not
distributable; `build-app-dist.sh` overwrites it. Never upload one that stapling didn't touch —
`xcrun stapler validate <app>` and `spctl -a -vv -t exec <app>` are how you know.

Useful env: `SKIP_APP=1` (CLI only), `TAP_DIR=` (tap is `../homebrew-s` by default),
`NOTARY_PROFILE=`. If notarization is rejected the script prints Apple's log; fetch it again
with `xcrun notarytool log <submission-id> --keychain-profile notary`.

Full detail, including the one-time signing setup: [docs/RELEASE.md](../../../docs/RELEASE.md).
