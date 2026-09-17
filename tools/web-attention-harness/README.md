# Web attention harness

Research tool for backlog 26 ([docs/web-app-attention.md](../../docs/web-app-attention.md)): one page per
account, logging what a web app tells an embedder — notifications (caught natively through WebKit's
notification SPI, or by replacing `Notification` in the page), title and favicon changes, and WebKit's
process state while the page is shown, in a hidden window, or in no window.

```bash
tools/web-attention-harness/run.sh                      # the window's log pane only
HARNESS_LOG_FILE=1 tools/web-attention-harness/run.sh   # also ~/Library/Logs/WebAttentionHarness/*.jsonl
tools/web-attention-harness/run.sh --selftest http://127.0.0.1:8765/   # both modes against a local page, then quit
```

File logging is off unless asked for: the lines carry message previews from real accounts. Sign-ins
live in the harness's own website data store, separate from Folio's.

Not done yet: real sessions against Slack, Discord, Teams, Gmail, Google Chat and WhatsApp — see §6 of
the research page.
