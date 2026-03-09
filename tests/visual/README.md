# PM notes visual test suite

Run pm notes commands against fixture markdown files and view the results in an HTML report.

## Quick start

From the **repo root** (or from `tests/visual/`):

```bash
./tests/visual/run.sh
node tests/visual/generate-report.js
open tests/visual/report.html   # or xdg-open / start on other platforms
```

Or in one step from repo root:

```bash
./tests/visual/run.sh && node tests/visual/generate-report.js
```

## What it does

1. **run.sh**  
   Builds `pm` (if needed), creates a temporary config and a single project `W-1 VisualTest`. For each `.md` file in `fixtures/` it:
   - Writes that markdown to the project’s notes file
   - Runs: `pm notes path W-1`, `pm notes show W-1`, `pm notes todo complete W-1 0 0`, `pm notes show W-1` again
   - Appends the fixture name, markdown, and each command’s stdout/stderr/exit code to `results.json`

2. **generate-report.js**  
   Reads `results.json` and writes `report.html` with the fixture markdown and all command outputs so you can inspect behavior in the browser.

## Adding fixtures

Add a new `.md` file under `fixtures/`. It should roughly match the project notes schema:

- `# Title`
- Optional callouts: `> [!summary]`, `> [!question]`, `> [!info] Goals`, etc.
- `## Links`, `## Learnings`, `## Sessions`
- Under Sessions: `### Day, Date, optional label` and task lines like `- [ ] Task text` or `- [ ] Task @` for focus

The same command sequence runs for every fixture (notes path, notes show, todo complete 0 0, notes show). To change or extend commands, edit the list in `run.sh`.

## Requirements

- **swift** – to build the pm binary
- **jq** – to build JSON in the runner
- **node** – to generate the HTML report
