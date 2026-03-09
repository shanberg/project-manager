#!/usr/bin/env node
/**
 * Reads results.json from the visual test run and generates report.html
 * with embedded data so the report can be opened directly in a browser (file://).
 */

const fs = require("fs");
const path = require("path");

const scriptDir = __dirname;
const resultsPath = path.join(scriptDir, "results.json");
const reportPath = path.join(scriptDir, "report.html");

let data;
try {
  data = JSON.parse(fs.readFileSync(resultsPath, "utf8"));
} catch (e) {
  console.error("Could not read or parse results.json. Run ./run.sh first.");
  process.exit(1);
}

function escapeHtml(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function formatBlock(text, className = "") {
  const escaped = escapeHtml(text);
  return `<pre class="${className}">${escaped || "(empty)"}</pre>`;
}

const fixtures = data.fixtures || [];
const htmlParts = [];

for (const f of fixtures) {
  const name = escapeHtml(f.name);
  htmlParts.push(`<section class="fixture" id="fixture-${escapeHtml(f.name)}">`);
  htmlParts.push(`<h2>${name}</h2>`);
  htmlParts.push("<h3>Input markdown</h3>");
  htmlParts.push(formatBlock(f.markdown, "markdown"));

  htmlParts.push("<h3>Commands &amp; output</h3>");
  for (const cmd of f.commands || []) {
    const exitClass = cmd.exitCode === 0 ? "exit-ok" : "exit-fail";
    htmlParts.push(`<div class="command-block">`);
    htmlParts.push(`<div class="command">${escapeHtml(cmd.cmd)}</div>`);
    htmlParts.push(`<span class="exit ${exitClass}">exit ${cmd.exitCode}</span>`);
    if (cmd.stdout) {
      htmlParts.push("<details open><summary>stdout</summary>");
      htmlParts.push(formatBlock(cmd.stdout, "stdout"));
      htmlParts.push("</details>");
    }
    if (cmd.stderr) {
      htmlParts.push("<details><summary>stderr</summary>");
      htmlParts.push(formatBlock(cmd.stderr, "stderr"));
      htmlParts.push("</details>");
    }
    htmlParts.push("</div>");
  }
  htmlParts.push("</section>");
}

const style = `
  * { box-sizing: border-box; }
  body { font-family: ui-sans-serif, system-ui, sans-serif; margin: 0; padding: 1rem 2rem; max-width: 1200px; margin-left: auto; margin-right: auto; background: #1a1a1a; color: #e0e0e0; line-height: 1.5; }
  h1 { font-size: 1.25rem; margin-bottom: 0.5rem; }
  h2 { font-size: 1.1rem; margin-top: 2rem; margin-bottom: 0.5rem; color: #7dd3fc; border-bottom: 1px solid #333; padding-bottom: 0.25rem; }
  h3 { font-size: 0.95rem; margin-top: 1.25rem; margin-bottom: 0.35rem; color: #a5b4fc; }
  .fixture { margin-bottom: 2rem; }
  .markdown, .stdout, .stderr { background: #262626; padding: 0.75rem; border-radius: 6px; overflow-x: auto; font-size: 0.8rem; white-space: pre-wrap; word-break: break-all; border: 1px solid #333; }
  .command-block { margin: 1rem 0; padding: 0.75rem; background: #262626; border-radius: 6px; border: 1px solid #333; }
  .command { font-family: ui-monospace, monospace; font-weight: 600; color: #fbbf24; margin-bottom: 0.25rem; }
  .exit { font-size: 0.75rem; margin-left: 0.5rem; }
  .exit-ok { color: #86efac; }
  .exit-fail { color: #fca5a5; }
  details { margin-top: 0.5rem; }
  summary { cursor: pointer; font-size: 0.85rem; color: #94a3b8; }
  .nav { margin-bottom: 1.5rem; }
  .nav a { color: #7dd3fc; margin-right: 1rem; }
`;

const html = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>PM notes visual test report</title>
  <style>${style}</style>
</head>
<body>
  <h1>PM notes visual test report</h1>
  <p>Fixtures run against <code>pm notes path</code>, <code>pm notes show</code>, <code>pm notes todo complete W-1 0 0</code>, then <code>pm notes show</code> again.</p>
  <nav class="nav">
    ${fixtures.map((f) => `<a href="#fixture-${escapeHtml(f.name)}">${escapeHtml(f.name)}</a>`).join("")}
  </nav>
  ${htmlParts.join("")}
</body>
</html>
`;

fs.writeFileSync(reportPath, html, "utf8");
console.log("Wrote", reportPath);
