// In-page probe, identical in every engine. Injected at document start in the top frame.
// The runner prepends `window.__benchReadySelector` (must be shown) and `__benchNotReadySelector`
// (must not be: a loading bar) for the site.
// Times are ms on the page's performance clock; `origin` converts them to epoch ms.
(() => {
  if (window.top !== window || window.__bench) return;
  const B = (window.__bench = {
    origin: performance.timeOrigin,
    phase: 'load',
    frames: [],          // [phase, intervalMs, at]
    marks: {},           // fcp, lcp, selector, settled, domContentLoaded, load
    loaf: [],            // long animation frames, Chromium only: [start, duration, blocking]
    longtasks: [],       // Chromium only: [start, duration]
  });

  let last = 0;
  const tick = (t) => {
    if (last) B.frames.push([B.phase, t - last, t]);
    last = t;
    requestAnimationFrame(tick);
  };
  requestAnimationFrame(tick);

  const observe = (type, fn) => {
    try { new PerformanceObserver((l) => l.getEntries().forEach(fn)).observe({ type, buffered: true }); }
    catch (_) { B.marks['no-' + type] = true; }
  };
  observe('paint', (e) => { if (e.name === 'first-contentful-paint') B.marks.fcp = e.startTime; });
  observe('largest-contentful-paint', (e) => { B.marks.lcp = e.startTime; });
  observe('long-animation-frame', (e) => B.loaf.push([e.startTime, e.duration, e.blockingDuration]));
  observe('longtask', (e) => B.longtasks.push([e.startTime, e.duration]));
  B.visibility = [[performance.now(), document.visibilityState]];
  document.addEventListener('visibilitychange', () => B.visibility.push([performance.now(), document.visibilityState]));
  document.addEventListener('DOMContentLoaded', () => { B.marks.domContentLoaded = performance.now(); });
  addEventListener('load', () => { B.marks.load = performance.now(); });

  // Ready = the site's selector is shown and its not-ready selector isn't.
  // Settled = after ready, 500ms in which no frame took longer than 50ms.
  const selector = window.__benchReadySelector;
  const poll = setInterval(() => {
    const now = performance.now();
    if (B.marks.selector == null) {
      const shown = (sel) => {
        const el = sel && document.querySelector(sel);
        const box = el && el.getBoundingClientRect();
        return !!(box && box.width > 0 && box.height > 0);
      };
      if (shown(selector) && !shown(window.__benchNotReadySelector)) B.marks.selector = now;
      return;
    }
    const recent = B.frames.filter((f) => f[2] > now - 500);
    if (now - B.marks.selector >= 500 && recent.length > 5 && recent.every((f) => f[1] < 50)) {
      B.marks.settled = now;
      clearInterval(poll);
    }
  }, 50);

  B.wheels = 0;
  addEventListener('wheel', (e) => { if (e.isTrusted) B.wheels++; }, { capture: true, passive: true });

  B.setPhase = (name) => { B.phase = name; return performance.now(); };

  // Stats over one phase's frame intervals, against the page's own median as the nominal interval.
  B.stats = (phase) => {
    const xs = B.frames.filter((f) => f[0] === phase).map((f) => f[1]).sort((a, b) => a - b);
    if (xs.length < 3) return { phase, frames: xs.length };
    const q = (p) => xs[Math.min(xs.length - 1, Math.round(p * (xs.length - 1)))];
    const nominal = q(0.5);
    const total = xs.reduce((a, b) => a + b, 0);
    const missed = xs.reduce((a, x) => a + Math.max(0, Math.round(x / nominal) - 1), 0);
    return {
      phase, frames: xs.length, seconds: total / 1000,
      fps: xs.length / (total / 1000), nominalMs: nominal,
      p50: q(0.5), p95: q(0.95), p99: q(0.99), worst: xs[xs.length - 1],
      over50: xs.filter((x) => x > 50).length, missed,
    };
  };

  B.report = () => ({
    url: location.href, origin: B.origin, marks: B.marks,
    phases: [...new Set(B.frames.map((f) => f[0]))].map(B.stats),
    loafCount: B.loaf.length,
    loafBlockingMs: B.loaf.reduce((a, l) => a + (l[2] || 0), 0),
    longtaskMs: B.longtasks.reduce((a, l) => a + l[1], 0),
    heapMB: performance.memory ? performance.memory.usedJSHeapSize / 1048576 : null,
    wheels: B.wheels,
    visibility: B.visibility,
    viewport: [innerWidth, innerHeight, devicePixelRatio],
  });
})();
