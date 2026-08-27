# Developer notes

The distilled why and how of this plugin, for a contributor (or a future
maintenance session) starting from a bare clone. The README covers using it;
`CLAUDE.md` carries the project rules and hard constraints. Everything here
was learned building against a live Omarchy 4.0.1 system (hostname Navi),
usually by reproducing the failure first. The PM workspace's `exchange/`
numbered docs (present alongside this repo during development, not required
to build or maintain it) corroborate specific claims below where cited —
treat them as evidence, not as something a fresh clone needs to have.

## Architecture

| File | Role |
|---|---|
| `Service.qml` | The data layer and the only owner of machine-wide state: every `Process`, `Timer`, and piece of mutable data lives here. Loaded once by the shell (`kinds: ["service", ...]`, `keepLoaded: true`). |
| `BarWidget.qml` | The bar button. Eager-`Loader`-hosted panel, GitHub octicon + count pill. One instance **per monitor** — reads `Service.qml`'s public properties, owns none of its own. |
| `Panel.qml` | The popup UI: hero, degradation hint, search field (v1.2), five sections (inbox, review requests, open PRs, open issues, repo activity), each independently foldable (v1.2). One instance **per monitor**, same as `BarWidget.qml`. Binds to the service; writes nothing back to it except calling `refresh()`/`openUrl()`/`setRepoSort()`/`setIssuesFilter()`. |
| `SectionHeader.qml` | v1.1: kit-styled section header (label + right-aligned count/`"…"` pill, optional `extra` slot) shared by all five `Panel.qml` sections; also where the F1 recent/stars and (v1.2) G4 Focus/All toggles are instantiated. v1.2 adds `collapsed`/`toggled()` for the click-to-fold header (G3). |
| `Model.js` | Pure logic, no Quickshell imports, ES5-compatible so plain Node can `require()` it: every `gh` JSON → UI-shape mapping function, the URL allowlist, the failure classifier, field/list caps, (v1.1) `repoPill`/`sortRepos`/`ownerFromNameWithOwner`/`isExternalOwner`/`mergedSettings`, and (v1.2) `matchesQuery`/`filterIssues`/`lastComment`/`subscribedFromViewerSubscription`. Fully unit-testable without a running shell. |
| `scripts/fetch-dashboard` | `bash`: `exec gh api graphql` with the combined query (openPRs + repos + review-requests + v1.1's `myIssues`, each PR/issue/review-request node also carrying v1.2's `comments(last: 1)` and (issues only) `viewerSubscription`) embedded as a fixed string. |
| `scripts/fetch-notifications` | `bash`: `exec gh api -i notifications [-H "If-None-Match: $1"]` — the ETag is the one remote-derived script argument anywhere in this plugin. |
| `scripts/probe-auth` | `bash`: `gh api user --jq .login` under `timeout 25`, translated to one of five stable exit codes. Does **not** call `gh auth status` (see below). |

**The split rule** (same as Ristretto's, `~/.config/omarchy/plugins/halmylyseas.ristretto/docs/developers.md`):
panels exist once per monitor, so anything singleton — processes, timers,
network state — belongs in `Service.qml`, and `BarWidget.qml`/`Panel.qml`
reach it only via `shell.serviceFor("halmylyseas.github-status")`, always
null-guarded (`shell` may not have injected yet, or the lookup may miss).
Nothing in either UI file spawns a process, opens a URL, or touches
`internal` state directly — every mutation funnels through `Service.qml`'s
`refresh()`/`openUrl()`.

## Decisions that look odd until you know why

- **No disk cache, no `FileView`, anywhere.** `06-design.md`'s "Security
  invariants" made this non-negotiable up front, and the two closest prior
  plugins both paid for the alternative: Ristretto shipped an unbounded
  `preload: true` `FileView` over a user-writable directory
  (`RISTRETTO-UNBOUNDED-TOGGLES-FILEVIEW`) and the closest sibling plugin,
  `viniciusfnery.github-inbox`, was flagged in its own marketplace review for
  unbounded cache-file reads on predictable paths. Keeping every list in QML
  memory only (`internal.notifications`/`openPRs`/`reviewRequests`/`repos`,
  `Service.qml:260-263`) makes that whole finding class structurally
  impossible — there is no file to swap, symlink, or overgrow. The accepted
  cost is a blank/"Loading…" panel for a couple of seconds after every shell
  restart, since nothing survives it.

- **A `gh` HTTP 304 is success, printed as a non-zero exit.** Live-verified
  (`exchange/07-s1-scaffold.md`): `gh api -i notifications -H
  'If-None-Match: "<etag>"'` against a genuinely-unchanged inbox prints the
  full `HTTP/2.0 304 Not Modified` status/header block to **stdout**, `gh:
  HTTP 304` to **stderr**, and exits **1**. `Model.classifyFailure` matches
  that stderr text to the tag `"http-304"`, and `handleNotificationsExit`
  (`Service.qml:709-732`) special-cases it *before* anything reaches the
  generic failure path: the ETag is refreshed if a new one appears in the
  header block (it can, even on a 304), `lastSyncMs` bumps via
  `onFetchSuccess("notifications")`, and — deliberately — `internal.
  notifications` is **not** reassigned, so no `notificationsChanged` signal
  fires. That non-signal is itself the proof the 304 branch ran rather than
  the 200 branch, which always reassigns the array even to `[]`
  (`exchange/08-s2-service.md`'s probe evidence). Treat any future change
  near this path with suspicion if it starts unconditionally reassigning
  `internal.notifications` — that would defeat the whole point of
  conditional requests (an unchanged inbox becomes a free, near-zero-cost
  poll).

- **Per-source status tracking, worst-of derivation.** The public `status`/
  `lastSyncMs`/`rateLimitedUntil` (`Service.qml:76-83`) look like plain
  properties but are all *computed*, never assigned. Three independent
  sources — the auth probe, the dashboard poller (its own GraphQL rate-limit
  bucket), the notifications poller (a separate REST bucket, different
  cadence) — each own `probeStatus`/`dashboardStatus`/`notifStatus` and their
  own `*LastSyncMs`/`*RateLimitedUntilMs` inside `internal`
  (`Service.qml:244-289`). `computeStatus()` (`Service.qml:323-328`) takes
  the worst of whichever sources currently matter, by the fixed severity
  order `no-gh > unauthenticated > rate-limited > offline > loading > ok`
  (`worstOf`, `Service.qml:304-309`); `lastSyncMs` is `Math.max` of the two
  pollers' own sync times (bumped by *either* succeeding, 304 included);
  `rateLimitedUntil` (`pickRateLimitedUntil`, `Service.qml:334-347`) only
  ever reflects a source that is *currently* rate-limited. This exists
  because the naive version — one shared `status`, written by whichever
  poller finishes last — flaps and masks: a rate-limited dashboard poller
  gets silently un-flagged the moment the *unrelated* notifications poller
  succeeds on its own 60s cadence, `status` reads `"ok"` while PR/repo data
  is actually stale, and the dashboard poller's own rate-limit skip-guard
  goes moot, causing an immediate wasted retry against a still-rate-limited
  API. Live-reproduced both broken and fixed (`exchange/12-s5b-correctness-
  review.md` Finding 2, `exchange/14-s6-fixes.md`'s 90s real-403 probe). The
  probe's `probeStatus` is deliberately excluded from `computeStatus()` once
  `internal.pollersActive` is true (`Service.qml:311-328`) — otherwise a
  single stale/inconclusive probe result (e.g. the watchdog's "offline"
  classification below) would permanently outrank two healthy, continuously
  refreshing pollers.

- **Timer `interval` is assigned imperatively at arm time, never bound
  live.** `dashboardTimer`/`notificationsTimer` (`Service.qml:567-583`,
  `662-675`) declare `interval` as a plain literal, then reassign it only at
  two points: `onRunningChanged` when the timer starts, and at the top of
  `onTriggered` before scheduling the next cycle. A live binding over
  `root.dashboardIntervalSec` (itself live over `shell.shellConfig`) was the
  original shape and was live-reproduced as broken
  (`exchange/12-s5b-correctness-review.md` Finding 3,
  `timer-interval-probe.qml`): a QML `Timer`'s live-bound `interval`
  restarts the countdown from zero on *any* dependency change, discarding
  whatever fraction of the wait had already elapsed — the exact bug class
  Ristretto's own suspend-timer review (`A1`) already paid for once. The
  fix's contract, documented at `Service.qml:568-574`: a settings edit takes
  effect at the next natural cycle boundary, never mid-wait.

- **Partial GraphQL: null means "don't replace", `[]` means "genuinely
  empty".** `scripts/fetch-dashboard` fetches three logically independent
  things (`openPRs`, `reviewRequests` via a separately-aliased `search`,
  `repos`) in one GraphQL call. GraphQL itself allows a response to carry
  `data` for the parts that succeeded *and* `errors` for the ones that
  didn't in the same envelope — realistic here because `search` has its own,
  stricter rate-limit bucket than the object-graph API. `Model.mapDashboard`
  returns each section as either a mapped array (however many nodes, `[]`
  included — a real "nothing here") or `null` (the field wasn't present as
  an object in `data` at all). `handleDashboardExit` (`Service.qml:613-637`)
  only reassigns the sections that came back non-null, logs `parsed.errors`
  alongside whatever did parse, and only routes to the full-failure path
  when **all three** are null (`gotSomething`, `Service.qml:618-619`). The
  earlier shape blanket-discarded the whole fetch on any non-empty `errors`
  array — safe (never renders garbage) but wasteful, and it fed the status-
  flapping problem above by classifying a two-thirds-successful cycle as a
  full failure.

- **URL allowlist + array-form exec, not string interpolation.**
  `Model.isSafeGithubUrl` (`Model.js:343-...`) requires the
  `^https://github\.com/` prefix (`SAFE_GITHUB_URL_RE`), rejects any control
  character or whitespace right after it (`CONTROL_OR_WHITESPACE_RE =
  /[\x00-\x20\x7f]/`), and caps overall length at `FIELD_CAP_URL` (2048).
  `Service.qml:openUrl` (`Service.qml:125-131`) checks that, then calls
  `Quickshell.execDetached(["xdg-open", url])` — an argv array, never a
  shell string, so even a URL that somehow passed the allowlist can't be
  shell-reparsed. This two-layer design exists because `apiUrlToWebUrl`
  builds `webUrl` out of a notification's GitHub-controlled `subject.url`;
  an adversarial repo/notification is exactly the threat model the security
  review (`exchange/11-s5a-security-review.md` F1) tested against —
  `.../pulls/1; rm -rf /` and a literal newline right after the prefix both
  originally passed a prefix-only check. `apiUrlToWebUrl` itself now
  restricts owner/repo to `[A-Za-z0-9_.-]+` and validates the trailing ID
  segment against a per-endpoint charset (`SEGMENT_ID_RE` — digits for
  issues/pulls/releases/discussions, a hex SHA shape for commits) instead of
  capturing `(.+)$` unbounded. If you add a new URL-producing code path,
  route it through `isSafeGithubUrl` before it can reach `openUrl` — there
  is no second gate.

- **`Text.PlainText` on every GitHub-controlled string; `SafeToolTip`
  instead of the first-party tooltip.** `Panel.qml` sets `textFormat:
  Text.PlainText` + `elide: Text.ElideRight` on every `Text` element that
  renders a remote-derived field (notification/PR/review-request/issue/repo
  title/reason/meta/age/owner text) — grep-provable
  (`grep -c 'textFormat: Text.PlainText' Panel.qml` → 20 as of the v1.2
  delta, up from 19 at v1.1 and 12 pre-delta — only +1 despite G2 adding
  three new `SafeToolTip` call sites (`PrRow`/`ReviewRequestRow`/`IssueRow`)
  because `SafeToolTip`'s own `PlainText` is declared once, on its shared
  `component` definition (`Panel.qml:832-...`); reusing the component at
  three more sites doesn't add three more grep-visible lines. The one new
  hit is the G1 search row's "✕" clear glyph. `SectionHeader.qml` → 2 (the
  pre-existing count pill plus v1.2's fold chevron, both synthesized glyphs —
  not remote, but PlainText as policy)). This exists
  because the closest sibling plugin, `viniciusfnery.github-inbox`, was
  flagged in its own marketplace maintainer review for rendering
  GitHub-controlled notification titles through a component that
  auto-detected and rendered HTML-like markup. One catch this plugin's own
  review found: `qs.Ui.PanelToolTip` (the first-party tooltip component) does
  **not** set `Text.PlainText` on its internal `Text` — it inherits Qt
  Quick's `Text.AutoText` default. Since the repo-activity row's hover
  tooltip shows `lastCommitHeadline` (a commit message — GitHub-controlled,
  in principle attacker-influenceable even on the user's own repo via a
  merged PR from someone else), `Panel.qml` defines `component SafeToolTip:
  ToolTip { ... }` — a structural copy of `PanelToolTip` with `Text.
  PlainText` forced on its `contentItem`. **Never use `PanelToolTip`
  directly on remote-derived text in this file** — `grep -n PanelToolTip
  Panel.qml` should only ever match the comments explaining why
  `SafeToolTip` exists, never an actual instantiation.

- **`viewer.issues(states: OPEN, ...)` with no `filterBy` is already
  authored-scoped — no `search author:@me` fallback needed.** v1.1's F3
  ("issues opened by the user") needed the query's exact semantics
  live-verified, not assumed: is `viewer.issues` "issues assigned to the
  viewer's repos" or "issues the viewer themselves authored"? A read-only
  `gh api graphql` probe against the real account
  (`exchange/20-s8-data-delta.md`) returned 5 issues across 5 different
  repos the account doesn't own, every one with `author.login ===
  viewer.login` — conclusively authored-scoped, the same shape `viewer.
  pullRequests` (the existing `openPRs` connection) already has. The spec's
  documented fallback, `search(query: "is:open is:issue author:@me", type:
  ISSUE)`, bills GraphQL's stricter `search` rate-limit bucket (the same
  concern already on record for `reviewRequests`) and was never needed.
  `scripts/fetch-dashboard` adds this as `myIssues: issues(...)`, aliased
  the same way `openPRs`/`repos` are, in the same single query. If GitHub
  ever changes this connection's semantics, the fallback in
  `exchange/19-feedback-delta-spec.md` is the documented next step — verify
  live again before switching, the same way this decision itself was made.

- **`sortRepos` is a client-side sort over the already-fetched 20-repo
  query window, not a second query.** F1 ("sort by last activity or
  stars") sorts whatever `repositories(first: 20, ...)` already returned in
  `Model.js`, then `Service.qml` slices to `repoLimit` (3–30) at read time —
  changing `repoSort` re-orders instantly with no new `gh` call. This is
  correct at this project's scale (a solo maintainer's own repo count) but
  is a real limitation: a star-sort over an account with *more* than 20
  repos would only ever consider the 20 most-recently-pushed (the query's
  fixed `orderBy`), never the account's actual highest-starred repo if it
  happens to sit outside that window. Documented here rather than fixed
  because widening or re-querying per sort mode is out of scope for a
  status-bar panel capped at 30 visible rows anyway — flag this file if the
  repo cap or the query's `first:` value ever changes without checking
  whether this note still holds.

- **The probe watchdog, and why `probe-auth` needs its own `timeout 25`.**
  `dashboardProc`/`notificationsProc` both `exec gh ...` directly in their
  scripts, so the PID Quickshell's `Process` tracks *is* `gh` — a
  `Process.running = false` kills it directly. `scripts/probe-auth` cannot
  do that: it needs to capture `gh api user`'s output and branch on it
  (401 vs. everything else), so it runs `output="$(gh api user ...)"`, a
  command substitution that forks a subshell — the tracked PID is one
  generation *above* the real `gh` call. Two consequences, found the hard
  way: (1) without a watchdog at all, a hung `gh api user` (network not yet
  up at boot, a captive portal, a stalled TCP connection with no fast
  refusal) left `probeProc.running` permanently `true`, so `startProbe()`'s
  own re-entrancy guard silently no-op'd every future attempt forever,
  including every 5-minute `reProbeTimer` firing — the plugin stuck on
  "Loading…" with no self-recovery short of a manual restart
  (`exchange/12-s5b-correctness-review.md` Finding 1, live-reproduced: five
  consecutive silent no-ops over 16s). `probeWatchdog`
  (`Service.qml:540-555`), matching `dashWatchdog`/`notifWatchdog`'s exact
  30s shape, fixes that — but (2) force-stopping the *tracked* PID only
  kills the wrapper script, leaving the real `gh api user` call orphaned and
  still running. Fixed by wrapping the call itself in `timeout 25` inside
  `scripts/probe-auth` (under the QML watchdog's 30s, so it fires first in
  the ordinary case and actually terminates `gh`, with the QML watchdog as a
  pure backstop). Live-verified: direct isolated run against a hanging mock
  `gh` — exit 5, elapsed exactly 25s, zero leaked processes afterward.
  The watchdog classifies a timeout as `"offline"`, not `"no-gh"` (a hang is
  network-shaped, not "the binary is missing"), and unconditionally sets
  `internal.pollersActive = true` so the real pollers get to determine the
  true state themselves rather than waiting on an inconclusive probe.

- **F4's "…"-vs-confirmed-"0" pill is gated per-source, not on the blended
  `lastSyncMs`.** (`exchange/23-s11-delta-review.md` F1, fixed in S12.)
  `dashboardTimer`/`notificationsTimer` both have `triggeredOnStart: true`
  and both start the instant `internal.pollersActive` flips true — on
  essentially every cold start they fire their first fetch in the same JS
  tick and race two genuinely independent, differently-shaped `gh` calls
  (one combined GraphQL query vs. one lightweight REST GET) with no
  ordering guarantee. The original implementation gated all five
  `SectionHeader`s' "…" state on one property (`Panel.qml`'s `root.synced`,
  `!!svc && svc.lastSyncMs !== 0`) — `lastSyncMs` is `Math.max` of the two
  pollers' own sync times, so it flips true the moment EITHER poller
  succeeds. Whichever poller lost the race then had up to four sections
  (or one, in the symmetric case) show a real `count === 0` fold — "0", not
  "…" — for data that had never actually been fetched, exactly the false
  "confirmed empty" state F4 was specced to prevent. `Service.qml` now
  exposes `dashboardLastSyncMs`/`notificationsLastSyncMs` (public, alongside
  the still-blended `lastSyncMs`, which stays the hero's "Synced Xm ago"
  signal — nothing there needed to change), and `Panel.qml` gates each
  `SectionHeader` on the one source that actually backs it: `notifSynced`
  for Inbox, `dashboardSynced` for the other four. See
  `exchange/24-s12-release.md` for the cold-start probe evidence (both
  orderings of the race, before/after).

- **`internal.login` can now be learned two ways, not one — and why the
  second way is a one-shot re-map, not a live re-derivation.**
  (`exchange/23-s11-delta-review.md` F2, fixed in S12.) Previously,
  `internal.login` was set only inside `handleProbeResult`'s `exitCode ===
  0` branch — if the very first auth probe failed with a non-auth
  classification (`"offline"`/`"rate-limited"`/`"error"`, all reachable from
  `probe-auth`'s generic exit-5 bucket) or hung into `probeWatchdog`, the
  pollers still started (correct — never block polling on the probe alone),
  but nothing ever scheduled another probe attempt, since `reProbeTimer`'s
  only other restart sites are the no-gh/unauthenticated branches. F6's
  owner pill on every Inbox row silently and permanently disabled
  (`isExternalOwner`'s conservative default treats an unknown login as
  "never external") for the rest of the session — no self-heal short of a
  restart. The realistic trigger ("the network isn't up yet at shell
  startup or resume-from-suspend") is the ordinary case, not an edge case —
  the exact scenario `exchange/12-s5b-correctness-review.md` Finding 1
  already flagged for the probe hanging in the first place. Two-part fix:
  (a) `handleDashboardExit` opportunistically captures `internal.login` off
  `Model.mapDashboard`'s new `login` return field (every dashboard response
  carries `viewer.login` whenever any viewer-scoped section resolved — a
  free read, no extra `gh` call) whenever `internal.login` is still empty;
  (b) `maybeRearmReProbeForLogin()` restarts `reProbeTimer` (the existing
  5-minute "slow re-probe" cadence, not a new faster one) after a non-auth
  probe failure or watchdog timeout, purely to keep retrying login capture,
  independent of `pollersActive`. Both capture sites are guarded to set
  `internal.login` **only from empty**, never overwrite an already-known
  value — this is deliberate, not an oversight: it keeps the fix from
  fighting the F3 accepted-risk tradeoff below (a live re-derivation on
  every dashboard response would "fix" F3 but reopen it as a
  correctness/trust question — which source wins if the probe and the
  dashboard ever briefly disagree — that's out of scope for a targeted
  fix). Because `internal.notifications` only ever holds the already-mapped
  list (the raw REST body is never retained past `handleNotificationsExit`,
  by design — see the ETag/304 note above), the one-shot re-map after (a)
  learns the login re-derives `isExternal` from each item's own already-
  known `owner` field (`Model.remapNotificationsExternal`) rather than
  waiting out a full `notificationsIntervalSec` poll or needing to retain a
  second copy of raw data anywhere.

- **G1 search field is not auto-focused on open — the key catcher keeps
  focus by default, the field earns it only on click.** (v1.2,
  `exchange/26-feedback2-delta-spec.md`, `exchange/28-s14-ui-delta.md`.)
  `KeyboardPanel` already force-focuses its own `PanelKeyCatcher` on every
  open via an internal `Qt.callLater`; a second, independent
  `Qt.callLater(searchField.forceActiveFocus)` from `Panel.qml`'s own
  `onOpenedChanged` would race that — undocumented ordering between two
  handlers scheduled into the same event-loop queue, not a guarantee. The
  shape actually used follows the closest first-party precedent for an
  inline text editor living inside a `KeyboardPanel` — the network plugin's
  Wi-Fi passphrase prompt (`/usr/share/omarchy/shell/plugins/panels/network/
  Panel.qml:834-874,991-996`): a real `Ui/TextField`, focused only by an
  explicit user action (a click), with `PanelKeyCatcher.blocked: !!
  searchField && searchField.activeFocus` so the moment the field holds
  focus, the catcher stops intercepting keys — `PanelKeyCatcher.qml`'s own
  header comment prescribes exactly this shape. The image-picker's
  `filterable` idiom (typing directly into an invisible-focus carousel via
  its own `Keys.onPressed`) was considered and rejected: that panel never
  binds `j/k/h/l`, this one already does (`PanelKeyCatcher`'s vertical
  scroll), and `PanelKeyCatcher.Keys.onPressed`'s own if/else chain consumes
  those letters *before* the generic `textKey` channel a filterable-style
  field would need — concretely, **"Nujabes" contains a "j"**, the human's
  own example string, which would have been silently truncated typing
  through that channel. Esc is handled locally on the field itself
  (`Keys.onEscapePressed`): clears a non-empty query first, closes the panel
  on a second Esc — no change to `PanelKeyCatcher` itself. A clickable "✕"
  is always present too, for mouse users and as a fallback.

- **G4's `subscribed` fails open, in both directions, deliberately.**
  (v1.2, `exchange/26-feedback2-delta-spec.md`.) `Model.
  subscribedFromViewerSubscription` treats a missing/`null`
  `viewerSubscription` field as `true` (subscribed), never `false`; `Model.
  filterIssues`'s `"focus"` branch keeps a row whose `subscribed` field is
  anything other than exactly `false` (`subscribed !== false`, not
  `subscribed === true`). Both choices point the same direction on purpose:
  a schema hiccup, a future GraphQL field rename, or a hand-built/legacy
  item missing the field entirely must never cause an issue the user cares
  about to silently vanish under the default "Focus" view — the failure
  mode of an over-eager filter (an issue wrongly hidden) is worse than the
  failure mode of an under-eager one (an issue wrongly shown, which is
  exactly what "All" is there to reveal anyway). This mirrors the project's
  existing fail-open precedent for `isExternalOwner`'s "unknown login is
  never external" default. Live-verified against the real account
  (`exchange/27-s13-data-delta.md` §1): `ValveSoftware/Proton#8626` comes
  back `viewerSubscription: "UNSUBSCRIBED"` → `subscribed: false` → hidden
  in Focus, the exact acceptance case from the human's own feedback.

- **G3's fold state is session-only, per-panel-instance, deliberately not
  persisted to `shell.json`.** (v1.2, `exchange/26-feedback2-delta-spec.md`.)
  `Panel.qml`'s five `xCollapsed` booleans
  (`inboxCollapsed`/`reviewRequestsCollapsed`/`openPRsCollapsed`/
  `myIssuesCollapsed`/`repoActivityCollapsed`) are plain properties on the
  panel root, reset alongside `searchQuery` in the same `onOpenedChanged`
  branch — "resets on panel reload" is the spec's own words, not an
  implementation shortcut. This is a different persistence tier than
  `repoSort`/`issuesFilter` (both go through `Model.mergedSettings` →
  `shell.updateEntryInline`, survive a restart) on purpose: a fold is a
  transient "I don't need to see this right now" gesture scoped to one
  look at the panel, not a standing preference like sort order or which
  issues to see by default — persisting it would mean a section a user
  folded once during a busy afternoon stays invisible forever until they
  remember to unfold it, silently hiding future data the way F4's own
  "less old clutter" complaint was originally about. If a future feedback
  round asks for persisted fold state, it is a new, explicit decision, not
  a natural extension of this one.

## Accepted risks (documented, not fixed)

- **`StdioCollector` has no byte ceiling.** Every `Process`'s stdout is
  buffered into one JS string before `onExited` fires (`probeOut`/`dashOut`/
  `notifOut`, `Service.qml:503-504,604-605,700-701`) — Quickshell doesn't
  expose a size limit on `StdioCollector`, only `waitForEnd`. Left
  unbounded deliberately, per-source rationale documented inline at each
  declaration site: `fetch-dashboard`'s GraphQL query hard-caps every list
  with explicit `first:` values (20/20/10); `fetch-notifications` never
  passes `--paginate`, so at most one default-sized REST page is ever
  requested; `probe-auth`'s `gh api user` has an inherently tiny response
  shape. All three also sit under the shared 30s watchdog backstop. The
  actual threat model here is a malicious repo's *content* (titles,
  headlines), which this bounds fine — an oversized response would require
  something outside that model entirely (a compromised/MITM'd
  `api.github.com`, or a `gh`/GitHub server bug), which is out of scope for
  v1. If Quickshell ever exposes a `StdioCollector` size cap, use it.

- **The count pill is bespoke — there was no first-party pattern to copy.**
  Unlike the boolean status-dot (`omarchy.tailscale`) or whole-glyph
  recoloring (`agents`' `active` state), nothing shipped in
  `/usr/share/omarchy/shell/` renders a numeric bar badge
  (`exchange/03-shell-api.md` §13 trap 13). `BarWidget.qml`'s count-pill
  `Rectangle` (min-width `Style.space(14)`, width grows to fit the digits,
  negative-overhang anchoring so it sits astride the icon's corner) was
  built from scratch, theme-token-driven (`Style.space`, `Color.background`
  for text-on-pill contrast, `root.urgent`/`Color.urgent` for the fill), and
  capped via `Model.badgeText()` ("99+" past 99) so a large unread count
  can't blow out the bar's fixed slot width. It has since been visually
  confirmed correct at 5/42/100/999 via a fabricated-data probe
  (`exchange/13-s5c-visual-review.md` §1) — since the real account this
  plugin was built against never has more than a handful of unread
  notifications, so it never exercised the pill live. If you touch this
  geometry, re-run a similar fabricated-data visual pass rather than trusting
  the live account to ever produce a large count.

- **`internal.login` never refreshes once known — a mid-session `gh` account
  switch leaves F6's owner pills using the stale identity until a restart.**
  (`exchange/23-s11-delta-review.md` F3, S12's binding disposition: accepted
  as a note, not fixed.) `internal.login` can be set two ways
  (`Service.qml`'s `handleProbeResult` on a successful probe, and S12's own
  F2 fix — `handleDashboardExit`'s opportunistic capture off a dashboard
  response's `viewer.login`) but both are guarded to only ever set it FROM
  empty (`if (login) internal.login = login` / `if (mapped.login &&
  !internal.login)`) — deliberately, so a stray/wrong value never clobbers
  an already-known-good login. The consequence, traced through the actual
  F2 fix rather than assumed: if the authenticated `gh` identity changes
  mid-session (`gh auth login` as a different user, out of this project's
  read-only threat model but plausible as an operator action), every
  subsequent probe success AND every subsequent dashboard response's own
  `viewer.login` is silently ignored by both capture sites — `internal.login`
  stays pinned to the pre-switch identity for the rest of the session, and
  Inbox/PR/issue rows' `isExternal`/`owner` marking (case-insensitive
  compare against the stale login, `Model.js:93-98`) misclassifies exactly
  as `exchange/23` originally flagged: rows now owned by the new account
  wrongly show an owner pill, rows matching the *old* login wrongly show
  none. **This is unchanged by the F2 fix, by design** — F2 solves "never
  learned at all", not "learned once, now wrong"; solving the latter would
  mean trusting a live re-derivation over the probe's own authoritative
  value, reopening exactly the "re-mapping storm" risk the guard exists to
  avoid. Narrow, cosmetic-only (no crash, no wrong data fetched, `gh` itself
  is still the authenticated identity actually used for every real API
  call), self-corrects on the next shell/plugin restart. Mirrors the
  already-accepted "ETag never resets on an auth-state transition" note in
  `exchange/11-s5a-security-review.md` F4 — same severity class.

## Workflow traps (each one cost real time)

- **Dev workflow is rsync-based, not edit-in-place, to spare the live bar a
  flash per save.** Every file save under `~/.config/omarchy/plugins/`
  triggers a full plugin reload (the shell runs `inotifywait -r` over that
  tree), tearing down and rebuilding every bar widget — visible as a flash
  on the user's actual desktop. The canonical working repo lives at
  `~/git/omarchy-github-status-plugin/plugin/` (a real git checkout);
  install a test round with:

  ```bash
  rsync -a --delete --exclude .git ~/git/omarchy-github-status-plugin/plugin/ \
    ~/.config/omarchy/plugins/halmylyseas.github-status/
  ```

  one flash per test round, not per save. Post-release, the installed
  folder *is* the canonical clone (see "Releasing an update" below) —
  `.git/` is exempt from the reload watch, so commits there are silent, but
  doc/code edits are not.

- **A structural QML edit (new file, bar-widget change) needs `omarchy
  restart shell`.** Hot reload never re-creates a registered widget
  component, and a file added after the first scan fails with `File name
  case mismatch` even though it exists on disk. Don't debug a widget that
  "ignores" an edit before restarting.

- **Every `omarchy restart shell` needs the mandatory idle-revive
  afterward**, or `omarchy.idle`'s idle monitor stays silently dead (no
  screensaver, no lock — `omarchy-shell idle status` looks healthy anyway):

  ```bash
  omarchy toggle idle stay-awake
  sleep 5
  omarchy toggle idle allow-idle
  ```

  The `sleep 5` between the two matters — the CLI only touches a flag file
  the idle service watches asynchronously, and a rapid create+delete loses
  the delete. Verify Ristretto (the user's production plugin) survived:
  `omarchy-shell halmylyseas.ristretto __probe__` → `Function not found.`
  means it's still loaded.

- **`qmllint` needs an import root containing a `qs` entry** and is not on
  `PATH`:

  ```bash
  mkdir -p /tmp/qmlroot && ln -sfn /usr/share/omarchy/shell /tmp/qmlroot/qs
  /usr/lib/qt6/bin/qmllint -I /tmp/qmlroot -I /usr/share/omarchy/shell Service.qml BarWidget.qml Panel.qml SectionHeader.qml
  ```

  Expected clean baseline for this codebase (matches the marketplace-
  validated Ristretto's own lint output under the same invocation): one
  `signal-handler-parameters` warning per `onExited: function(exitCode,
  exitStatus)` handler (3, one per `Process` in `Service.qml`),
  `missing-property` on `bar.*`/`Style.*`/`Color.*` (qmllint can't resolve
  the dynamically-built singleton sub-trees across the generic-`QObject`
  injection boundary), and "Unqualified access" inside nested `component`
  blocks lacking `pragma ComponentBehavior: Bound` (same shape
  `agents/Panel.qml` ships with). Zero errors is the bar; new warning
  *classes* beyond these three are worth investigating, not the counts.

- **Liveness is the IPC probe, not the plugin list.** `omarchy-shell
  halmylyseas.github-status __probe__` → `Function not found.` means loaded;
  `Target not found.` means not. `omarchy plugin list --json`'s `active`
  field is not a reliable signal.

- **Never pass the GitHub octicon (a Nerd-Font PUA glyph, U+F09B) through a
  bash heredoc or a plain exact-match edit tool without verifying the
  bytes landed.** This bit twice during development, and neither time
  through a heredoc specifically — a plain `Write` of `text: ""` silently
  produced an *empty* string where the glyph belonged (dropped, not
  mismatched), in both `BarWidget.qml` and `Panel.qml`. PUA glyphs render as
  invisible/blank boxes in most terminal fonts, so an empty string and a
  present-but-unrenderable glyph are visually identical — qmllint has no
  opinion on glyph correctness either. The only check that caught it was a
  byte-level audit after every write:

  ```bash
  python3 -c "print([hex(ord(c)) for c in open('BarWidget.qml', encoding='utf-8').read() if ord(c) > 0xe000])"
  ```

  should list `0xf09b` at least twice in `BarWidget.qml` (bar icon; none in
  the pill itself) and once in `Panel.qml` (hero icon). Run this after any
  edit that touches those lines.

- **The repo is the installed folder — no symlink inside it, and no
  symlinked plugin directory at all.** `omarchy plugin validate` hard-
  rejects a symlinked plugin directory (`build-catalog.mjs:383-385`'s
  submission-time check has a live-time analog). The canonical checkout
  lives at `~/.config/omarchy/plugins/halmylyseas.github-status/`; any
  working-copy convenience symlink points *at* it, never the other way
  round.

- **Never `omarchy plugin clone` a first-party plugin** — it replaces the
  built-in. Read `/usr/share/omarchy/shell/` freely for reference (safe,
  encouraged); never write there — every update destroys it, and it's
  outside this project's remit entirely (`CLAUDE.md` hard rule 4).

## Testing

- `./test/all` runs both suites and exits non-zero on any failure:
  - `node test/model.test.js` — every `Model.js` export, pure-function
    tests, no Quickshell/QML involved. Includes adversarial input (control
    characters, oversized fields, malformed/partial GraphQL envelopes,
    fabricated 500–5000-item arrays to exercise the list caps) and the
    live-observed byte shapes of `gh`'s 200/304 header blocks.
  - `bash test/scripts.test.sh` — runs `scripts/*` for real, with
    `test/mocks/gh` shadowing the real `gh` binary on `PATH` (same pattern
    as `ssupt.bluetooth-audio`'s precedent). Covers `fetch-dashboard`
    against a fixture, `fetch-notifications`'s three ETag states (none /
    matching-304 / non-matching-fresh), and `probe-auth`'s four exit codes.
- **State-machine logic (per-source status tracking, arm-time timer
  intervals, the probe watchdog) lives entirely in `Service.qml` — QML, not
  Node-testable.** This project's verification method for that layer is a
  standalone `qs -p <probe>.qml` instance: a throwaway Quickshell process
  loading the real `Service.qml` via a `Loader` against a stub `shell`
  object, with `Connections` logging every public-property change to a
  file (never a pipe — pipes block-buffer and can swallow output). This
  never touches the live shell, never touches `~/.config/omarchy`, and
  makes real (read-only) `gh` calls against the authenticated account when
  exercising success paths. For a UI-only visual pass without a real
  Quickshell bar, a second harness pattern symlinks `Commons`/`Ui` from
  `/usr/share/omarchy/shell/` into a throwaway directory next to the probe
  config so `import qs.Commons`/`import qs.Ui` resolve, then drives the
  real `BarWidget.qml`/`Panel.qml` against a fully fabricated stub service
  (fake unread counts, fake degradation states, fake full-caps data) to
  exercise UI states the real account never produces — screenshots via a
  spawned `grim -g <geometry>` cropped to just the plugin's own bar slot +
  popup, never full-screen (avoids capturing the rest of the live desktop).

## Releasing an update

The marketplace lists an exact validated commit, not a branch — this
plugin's own submission mechanics are documented at
`exchange/05-marketplace.md` §2 if that doc is present; the durable
procedure (mirroring Ristretto's, which has actually shipped an update
through it) is:

1. Bump `version` in `manifest.json`, commit, push `master`.
2. Re-run `./test/all`, `omarchy plugin validate .`, and qmllint on a clean
   checkout before the release commit — not the rsynced/live copy.
3. Open a **Plugin verification** issue on
   `HANCORE-linux/omarchy-plugin-marketplace` (template `verify-plugin.yml`),
   choosing *Verify and publish a newer upstream commit*, and supply the
   plugin ID (`halmylyseas.github-status`), the repository root URL, and the
   full 40-character SHA of the pushed `HEAD`.
4. Validation and the Automated Security Baseline re-run against that exact
   commit (`SECURITY.md`'s "exact-SHA binding" — a later push invalidates
   the recorded validation); a maintainer's `approved-and-verified` replaces
   the listed snapshot.

Until that lands, the listing shows *Update unverified* against a newer
`master` — harmless, but **do not push to `master` mid-review of a pending
submission or verification issue**, since approval is bound to the commit
that was actually validated. Editing an open issue (not creating a new one)
re-runs the bot's checks — never open a second `[Plugin]:`/verification
issue for the same plugin.
