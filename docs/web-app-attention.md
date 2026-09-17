# Hearing from web apps

Backlog 26. Research, 2026-09-17 — nothing here is built. What it is for: several cards per chat
workspace, mail account or tracker, spread over several projects, and knowing when something relevant
arrives there — without a renderer per card and without a notification per message.

## 1. The shape this points at

**Listening belongs to the app, not to cards.** A card is a view onto a channel; the thing that hears
is one hidden page per *account* — a Slack workspace, a Gmail `/u/N`, a Discord login — owned by the
app, running whichever project windows are open, costing one renderer per account however many cards
point at it. Where an app has a usable API instead, the listener is a poll and costs no renderer.

**The app's own rules are the relevance filter.** Slack, Discord, Teams and Gmail decide what deserves a
notification from your settings — mentions, DMs, keywords, muted channels — *in the page*, before they
call `Notification`. A listener that catches those calls gets the already-filtered stream; everything
else is the quieter unread signal (§4).

**The board is the routing table.** A card's address names the account and usually the conversation
(`app.slack.com/client/T…/C…`, `discord.com/channels/guild/channel`, `mail/u/1/#label/x`), so a
notification lands on the projects whose cards match — channel first, then account.

**Quiet by default.** Counts on cards, dots on projects and the menubar; system notifications grouped
per project with a cool-down, and only for what the app itself would have notified about.

## 2. What WebKit gives an embedder (measured on this Mac, and read in WebKit's source)

| | Finding | How we know |
|---|---|---|
| `Notification` | Present on macOS. `permission` is `"default"`; `requestPermission()` resolves `"denied"` with no public way to grant it; `new Notification()` doesn't throw and shows nothing | Probe in PMViewTests; `UIDelegate.mm` answers false with no delegate |
| Catching it natively | **Private SPI**: `WKNotificationManagerSetProvider` (show/cancel/click), `_webView:requestNotificationPermissionForSecurityOrigin:decisionHandler:`, `_WKWebsiteDataStoreDelegate notificationPermissionsForWebsiteDataStore:` (survives reloads), `websiteDataStore:showNotification:` for service-worker notifications. Exported on this Mac; MacPin ships on it | WebKit source, `dyld_info -exports` |
| Catching it with a script | Replace `window.Notification` in the page world, every frame, at document start, reporting `granted`; also patch `ServiceWorkerRegistration.prototype.showNotification` and `permissions.query`. Ferdium, Tauri, teams-for-linux do this. **Misses notifications a service worker shows**, and loses WebKit's background exemption (§3) | Their source |
| Web Push | **Not available**: `webpushd` requires `com.apple.private.webkit.webpush`. A listener has to be a live page | WebKit source |
| Service workers | Work in a Mac embedder (the App-Bound Domains check is iOS-only) | Probe: `navigator.serviceWorker` present |
| Badging API | Absent by default (`setAppBadge` undefined); SPI `_setAppBadgeEnabled:` + `_webView:updatedAppBadge:`. Apps rarely call it outside installed PWAs | Probe, source |
| Processes | One WebContent process per view; `WKProcessPool` no longer shares | Apple docs |

## 3. Does a hidden page keep listening?

**WebKit suspends a page that stopped being visible**, 4 minutes later by default and 10 seconds under
memory pressure (`WebProcessPool::defaultWebProcessSuspensionDelay`), and a suspended page drops its
socket. **Two things exempt a page** (`WebPageProxy.cpp`): *it shows notifications* (the native
provider path, not a script shim), and *it updates its title* without a load or a user action. Both
are cleared on navigation.

Measured with a local WebSocket server pushing every 20s to a page with no window and a page in an
ordered-out window, for 8 minutes each:

| Page | Delivery | Socket |
|---|---|---|
| Changes its title on each message | Held up to 41s until the first title change, then **1–100ms** for the rest | Open |
| Never changes its title | **Batched about once a minute** (lags of 42s / 22s / 2s, every minute) | Open |

No suspension within 8 minutes in either — but this ran inside xctest, which RunningBoard may treat
differently from an app; reports from shipping apps show suspension at 4–16 minutes. **Has to be
re-measured inside Folio**, watching `_webProcessState`. Levers if it suspends: keep the listener in an
ordered-in window with `_windowOcclusionDetectionEnabled = NO`; deliver notifications natively.

Timers in a hidden page are throttled hard either way (a 1s interval fired 7 times in 180s with no
window) — so anything PM asks of a page runs on PM's clock (`evaluateJavaScript`), never the page's.

## 4. What each app gives

From Ferdium's recipes, teams-for-linux, and the apps' docs. Nobody documents what an app puts *in* a
notification — that is the gap the harness (§6) closes.

| App | URL names | Unread signal | One page hears | No-renderer route |
|---|---|---|---|---|
| Slack | workspace + channel | `*` title prefix; favicon: none / unread / mention | open workspaces (conflicting reports) | API needs an app per workspace, admin approval, 2025 rate limits |
| Discord | guild + channel | `(N)` = mentions, `• Discord` = unread | all servers of one login | none — automating a user account is banned |
| Teams v2 | nothing useful | `(N)` title | active tenant | Graph subscription: public HTTPS + consent |
| Google Chat | `/u/N` + space | title count; DOM | one `/u/N` | Chat API, Workspace only |
| Gmail | `/u/N` + label/thread | `Inbox (N) - address - Gmail` | one `/u/N` | **Atom feed** `/mail/u/N/feed/atom[/label]` with the session cookies — unsupported but real |
| Outlook | folder + item | DOM counts | one account | Graph: public HTTPS |
| WhatsApp | nothing | `(N)`; IndexedDB `model-storage` → `chat` | one account | none |
| Telegram | peer | DOM badges | one account | MTProto user API, allowed |
| Messenger | thread | `(N)` | one account | none |
| GitHub | repo + issue | header dot | active account | **Notifications API**, PAT; `If-Modified-Since` → 304 costs nothing |
| Linear | workspace + issue | none | one workspace | **GraphQL `notifications`**, personal key |
| Asana | project + task | none | switcher | **Events API**, PAT + sync token |
| Jira/Confluence | site + key | none | per site | **JQL polling**, API token |
| Google Calendar | `/u/N` | none | `/u/N` | `syncToken` polling |
| Notion, Figma | page / file | none | — | webhooks only (public URL) — no route |

**Three families, not one mechanism.** *Chat and mail* need a live listener page per account, with the
title as the universal quiet signal and caught notifications as the loud one. *Trackers* (GitHub,
Linear, Asana, Jira, Calendar) are better as API polls with a personal token — cheaper, and they carry
real ids. *Notion and Figma* offer nothing to an embedder today.

## 5. Routing a notification to a project

Notifications carry text — sender or channel name as the title, the message as the body — not ids.
Two ways to a card:

1. **Match names.** A card knows its conversation from its address and its page title
   (`CanvasPageTitles`); match the notification's channel or sender against those, then fall back to
   the account.
2. **Follow the click.** Slack, Discord and Teams open the conversation from the notification's own
   `onclick`. Firing it in the listener and reading where the page navigates gives the real ids — at
   the cost of marking that conversation read. Worth measuring, not assuming.

API polls route exactly: a GitHub notification names its repository and issue, which a card's address
already holds.

## 6. What is left to find out, in order

1. **A harness app with a logging listener**, signed in to real accounts (needs you, a few minutes
   each): record every `Notification`, service-worker notification, title and favicon change from
   Slack, Discord, Teams, Gmail, Google Chat, WhatsApp — what they carry, and whether one page hears
   every workspace or account.
2. **Suspension inside the real app**, over an hour, for a quiet page and a title-updating one.
3. **Native provider vs script shim** side by side: does the SPI path keep a page awake, and does
   either catch everything?
4. **Memory**: one listener page per account, measured, against the page budget.
5. **One tracker poll** (GitHub is the cheapest) end to end, to see the routing work on exact ids.

Then design: the listener registry, what Settings shows, the grouping and cool-down, and where a count
appears on a card, a tab and a project.

## Prior art and sources

Ferdium recipes and `notifications.ts`; teams-for-linux `mutationTitle.js` and `notificationBridge.js`;
MacPin `WebNotifier.swift`; Tauri notification plugin; WebKit `UnifiedWebPreferences.yaml`,
`UIDelegate.mm`, `WebPageProxy.cpp`, `WebProcessPool.cpp`, `webpushd`; GitHub, Linear, Asana, Graph
and Gmail API docs; Discord's self-bot policy.
