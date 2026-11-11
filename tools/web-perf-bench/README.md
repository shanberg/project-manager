# Web perf bench

Same scenario, two engines: Folio's WKWebView cards vs Chrome windows at the same tile sizes.

- `scenario.json` — sites (URL + ready selector), layouts (columns of sites), rounds, dwell times. 5K = 2560×1440 pt.
- `probe.js` — injected at document start in both engines: rAF frame intervals per phase, FCP/LCP, ready selector, settled (500 ms with no frame > 50 ms), trusted wheel count, long animation frames (Chromium only).
- `run-folio.sh <Folio.app>` — bench build (own bundle id) + scratch vault + `bench.canvas` (one card per layout × site, so no crossing is a handover). `Shared/LayoutBench.swift` crosses workspaces via `onGoToWorkspace`, cold = every off-screen page frozen and its resume/snapshot/visit forgotten. Records card milestones (asked/start/commit/reveal/finish) and the window's own frames per crossing.
- `run-chrome.mjs` — Playwright on Google Chrome, profile in `profiles/chrome`, one window per tile; cold = windows closed on leaving a layout. Reuses Folio's tile frames from `results/tiles.json` when present. Chrome's background throttling left on.
- `sampler.py` — CPU seconds + RSS per process role every 250 ms. Folio: processes macOS holds the app responsible for (WebContent, GPU, Networking). Chrome: the browser's process tree.
- `report.py <result dirs…>` — per layout, first round apart from later rounds, medians and p95.
- `.build/cookie-export <domain>` — a site's Chrome cookies as Playwright JSON (Folio's `CanvasCookieImport`); `swiftc -O -o .build/cookie-export cookies/main.swift ../../pm-mac/PM/Canvas/CanvasCookieImport.swift -lsqlite3`.

Variants: `PM_BENCH_WARM=1`, `PM_BENCH_UNFILTERED=1` (Folio block lists off for the scenario's hosts), `--warm` (Chrome).

Sign-in: `PM_BENCH_COPY_COOKIES="Google Chrome"` copies cookies into the bench build; `PM_BENCH_SIGNIN=1` opens the board to sign in by hand. Chrome: `cookie-export figma.com > c.json && node run-chrome.mjs --cookies c.json`, `node run-chrome.mjs --signin`. Discord keeps its token in localStorage, so cookies don't carry it: sign in by hand in each engine.

Known differences between engines:
- Folio caps non-engaged cards at 60 fps (`CanvasPageView.setFullFrameRate`); the bench scrolls without engaging, so Folio tiles run at 60.
- Chrome tiles are separate windows; Folio tiles are views in one window.
- HTTP cache is kept in both; round 0 is the first load into it.
