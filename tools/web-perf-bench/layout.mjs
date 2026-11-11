// Tile rectangles for a layout, in points, relative to the content area's top-left.
// Equal columns, equal rows within a column, `gap` between — the shape Folio's grid tiling makes.
// When a Folio run has written `tiles.json` (the frames it actually laid out), prefer that.
import fs from 'node:fs';

export function tileRects(layout, area, gap) {
  const cols = layout.columns.length;
  const colW = (area.width - gap * (cols + 1)) / cols;
  const rects = [];
  layout.columns.forEach((column, c) => {
    const rows = column.length;
    const rowH = (area.height - gap * (rows + 1)) / rows;
    column.forEach((site, r) => {
      rects.push({
        site,
        x: Math.round(gap + c * (colW + gap)),
        y: Math.round(gap + r * (rowH + gap)),
        width: Math.round(colW),
        height: Math.round(rowH),
      });
    });
  });
  return rects;
}

export function loadScenario(path) {
  const s = JSON.parse(fs.readFileSync(path, 'utf8'));
  for (const [key, site] of Object.entries(s.sites)) {
    if (/_URL$/.test(site.url)) throw new Error(`scenario: set sites.${key}.url (still ${site.url})`);
  }
  return s;
}
