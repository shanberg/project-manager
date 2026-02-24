# Release (project-manager)

One command: bump version, push, tag, update Homebrew formula, push tap.

From the **project-manager** repo, with `GITHUB_TOKEN` or `HOMEBREW_GITHUB_API_TOKEN` set:

```bash
npm run release -- patch    # 0.1.2 → 0.1.3 (bug fixes)
npm run release -- minor    # 0.1.2 → 0.2.0 (new features)
npm run release -- major    # 0.1.2 → 1.0.0 (breaking changes)
npm run release -- 0.2.0    # or set an exact version
```

The script bumps `package.json`, commits and pushes, tags and pushes the tag, downloads the tarball and updates the formula with the correct sha256, then commits and pushes the tap.

**Tap location:** Default is `../homebrew-s`. Override with `TAP_DIR` if your tap lives elsewhere.

**Optional:** To only update the formula (e.g. after releasing another way): `npm run update-homebrew-formula -- v0.1.3`

## 3. One-time per machine (new installs)

Users need **one** PAT with **repo** and **read:packages**, in **both** places:

- `HOMEBREW_GITHUB_API_TOKEN` (env or shell profile) — for the formula's private tarball.
- `~/.npmrc`: `//npm.pkg.github.com/:_authToken=YOUR_PAT` — for `@shanberg/project-schema` during build.
