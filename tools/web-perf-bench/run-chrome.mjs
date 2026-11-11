#!/usr/bin/env node
// Chromium reference run: the scenario's layouts as one Chrome window per tile, at the tile's size,
// on a dedicated profile. Cold = a layout's windows are closed when you leave it and opened afresh
// when you return (a fresh renderer, the HTTP cache kept — the same as a reclaimed Folio card).
//
//   node run-chrome.mjs --signin                 open every site once to sign in by hand, then quit
//   node run-chrome.mjs --cookies c.json         import cookies (Playwright shape) into the profile
//   node run-chrome.mjs [--warm] [--rounds N]    run; results in results/chrome-<stamp>/
import { chromium } from 'playwright-core';
import { spawn, execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { tileRects, loadScenario } from './layout.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const arg = (name, fallback) => {
  const i = process.argv.indexOf(name);
  return i < 0 ? fallback : process.argv[i + 1];
};
const flag = (name) => process.argv.includes(name);

const scenario = loadScenario(arg('--scenario', path.join(here, 'scenario.json')));
const rounds = Number(arg('--rounds', scenario.rounds));
const warm = flag('--warm');
const profile = path.join(here, 'profiles', 'chrome');
const probe = fs.readFileSync(path.join(here, 'probe.js'), 'utf8');
const stamp = new Date().toISOString().replace(/[:.]/g, '-');
const out = path.join(here, 'results', `chrome-${warm ? 'warm' : 'cold'}-${stamp}`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const context = await chromium.launchPersistentContext(profile, {
  executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  headless: false,
  viewport: null,
  // Only what automation needs. Playwright's defaults turn off background throttling, paint holding,
  // the hang monitor, IPC flood protection, and force sRGB — none of which a real Chrome does.
  ignoreDefaultArgs: true,
  args: [`--user-data-dir=${profile}`, '--remote-debugging-pipe', '--no-first-run', '--no-default-browser-check', '--password-store=basic',
         '--use-mock-keychain', 'about:blank'],
});

if (arg('--cookies')) {
  const cookies = JSON.parse(fs.readFileSync(arg('--cookies'), 'utf8'));
  await context.addCookies(cookies);
  console.log(`imported ${cookies.length} cookies`);
  await context.close();
  process.exit(0);
}

if (flag('--signin')) {
  // One page per host is enough: a sign-in is per site, not per page.
  const hosts = new Map(Object.values(scenario.sites).map((s) => [new URL(s.url).host, s.url]));
  for (const url of hosts.values()) await (await context.newPage()).goto(url).catch(() => {});
  console.log('Sign in in each window, then quit Chrome with ⌘Q (so it writes the sign-in to disk).');
  await new Promise((r) => context.on('close', r));
  process.exit(0);
}

fs.mkdirSync(out, { recursive: true });
const events = fs.createWriteStream(path.join(out, 'events.jsonl'));
const log = (kind, fields = {}) => events.write(JSON.stringify({ t: Date.now(), kind, ...fields }) + '\n');

// The browser process: the one on our profile without a --type.
const browserPid = Number(execFileSync('pgrep', ['-f', `user-data-dir=${profile}`]).toString().split('\n')
  .filter(Boolean).map(Number).find((pid) => !execFileSync('ps', ['-o', 'args=', '-p', String(pid)])
    .toString().includes('--type=')));
const sampler = spawn('python3', [path.join(here, 'sampler.py'), '--tree', String(browserPid),
  '--out', path.join(out, 'procs.jsonl')], { stdio: 'ignore' });
// Never leave the sampler behind: it outlives a crashed runner and holds the caller's pipe open.
const stopSampler = () => { try { sampler.kill('SIGTERM'); } catch (_) {} };
process.on('exit', stopSampler);
process.on('uncaughtException', (e) => { console.error(e); stopSampler(); process.exit(1); });
process.on('unhandledRejection', (e) => { console.error(e); stopSampler(); process.exit(1); });

// Where the screen is and how much a window's frame adds around its viewport, from a scratch window.
const scratch = context.pages()[0] ?? await context.newPage();
const cdp0 = await context.newCDPSession(scratch);
const { windowId: w0, bounds: b0 } = await cdp0.send('Browser.getWindowForTarget');
const inner0 = await scratch.evaluate(() => [innerWidth, innerHeight, screen.availLeft, screen.availTop,
                                            screen.availWidth, screen.availHeight]);
const frame = { dx: b0.width - inner0[0], dy: b0.height - inner0[1] };
const screenArea = { left: inner0[2], top: inner0[3], width: inner0[4], height: inner0[5] };
log('setup', { browserPid, frame, screenArea, warm, scenario });
if (screenArea.width < scenario.screen.width) {
  console.warn(`screen is ${screenArea.width}pt wide, scenario wants ${scenario.screen.width}`);
}
const tilesFile = path.join(here, 'results', 'tiles.json');
// Folio's frames are fractional points; window bounds take whole ones.
const folioTiles = Object.fromEntries(Object.entries(fs.existsSync(tilesFile)
  ? JSON.parse(fs.readFileSync(tilesFile, 'utf8')) : {}).map(([k, rects]) => [k, rects.map((r) => ({
    site: r.site, x: Math.round(r.x), y: Math.round(r.y), width: Math.round(r.width), height: Math.round(r.height) }))]));

async function openTile(rect) {
  const site = scenario.sites[rect.site];
  const page = await context.newPage();
  await page.addInitScript(`window.__benchReadySelector = ${JSON.stringify(site.ready)};\n`
    + `window.__benchNotReadySelector = ${JSON.stringify(site.notReady ?? null)};\n${probe}`);
  const cdp = await context.newCDPSession(page);
  const { windowId } = await cdp.send('Browser.getWindowForTarget');
  await cdp.send('Browser.setWindowBounds', { windowId, bounds: { windowState: 'normal' } });
  await cdp.send('Browser.setWindowBounds', { windowId, bounds: {
    left: screenArea.left + rect.x, top: screenArea.top + rect.y,
    width: rect.width + frame.dx, height: rect.height + frame.dy } });
  const opened = Date.now();
  page.goto(site.url, { waitUntil: 'commit', timeout: 0 }).catch(() => {});
  return { rect, page, opened };
}

const readyOf = (tile) => tile.page.evaluate(() => window.__bench?.marks).catch(() => null);

async function runLayout(layout, round, live) {
  const rects = folioTiles[layout.name]
    ?? tileRects(layout, { width: screenArea.width, height: screenArea.height }, scenario.gap);
  const start = Date.now();
  log('layout-start', { layout: layout.name, round });
  let tiles = live.get(layout.name);
  if (tiles) {
    for (const t of tiles) await t.page.bringToFront();
  } else {
    tiles = [];
    for (const rect of rects) tiles.push(await openTile(rect));
  }
  // Wait for every tile to settle, or time out.
  const deadline = start + scenario.dwell.readyTimeoutSeconds * 1000;
  while (Date.now() < deadline) {
    const marks = await Promise.all(tiles.map(readyOf));
    if (marks.every((m) => m?.settled != null)) break;
    await sleep(100);
  }
  const allSettled = Date.now();
  log('layout-settled', { layout: layout.name, round, ms: allSettled - start });
  for (const t of tiles) await t.page.evaluate(() => window.__bench?.setPhase('idle')).catch(() => {});
  await sleep(scenario.dwell.quietSeconds * 1000);
  // Scroll each tile in turn with real (CDP) wheel events at its centre; the others are 'bg'.
  for (const t of tiles) {
    for (const o of tiles) await o.page.evaluate((p) => window.__bench?.setPhase(p),
                                                 o === t ? 'scroll' : 'bg').catch(() => {});
    await t.page.bringToFront();
    // Raw CDP wheel events, not awaited, at a steady 60/s: Playwright's mouse.wheel waits for each to be
    // handled, which would make a busy page receive fewer of them than an idle one.
    const input = await context.newCDPSession(t.page);
    const at = { x: t.rect.width / 2, y: t.rect.height / 2 };
    await input.send('Input.dispatchMouseEvent', { type: 'mouseMoved', ...at });
    const until = Date.now() + scenario.dwell.scrollSecondsPerTile * 1000;
    let dir = -1, n = 0;
    while (Date.now() < until) {
      input.send('Input.dispatchMouseEvent', { type: 'mouseWheel', ...at, deltaX: 0, deltaY: -60 * dir }).catch(() => {});
      if (++n % 30 === 0) dir = -dir;
      await sleep(16);
    }
    await input.detach().catch(() => {});
  }
  for (const t of tiles) await t.page.evaluate(() => window.__bench?.setPhase('idle2')).catch(() => {});
  await sleep(scenario.dwell.quietSeconds * 1000);
  for (const t of tiles) {
    const report = await t.page.evaluate(() => window.__bench?.report()).catch((e) => ({ error: String(e) }));
    log('tile', { layout: layout.name, round, site: t.rect.site, rect: t.rect, opened: t.opened, report });
  }
  log('layout-end', { layout: layout.name, round, readyMs: allSettled - start });
  if (warm) {
    live.set(layout.name, tiles);
  } else {
    for (const t of tiles) await t.page.close();
  }
}

const live = new Map();
for (let round = 0; round < rounds; round++) {
  for (const layout of scenario.layouts) {
    console.log(`round ${round + 1}/${rounds}: ${layout.name}`);
    await runLayout(layout, round, live);
  }
}
sampler.kill('SIGTERM');
events.end();
await context.close();
console.log(out);
