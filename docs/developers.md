# Developer notes

The design record for this plugin, for a new contributor. The README
covers using it; `CLAUDE.md` carries the hard rules; `docs/threat-model.md`
carries the security model.

## Architecture

| File | Role |
|---|---|
| `manifest.json` | Kinds `["service", "bar-widget"]`, `keepLoaded: true`. `entryPoints.service` is `Service.qml`, `entryPoints.barWidget` is `BarWidget.qml`. |
| `Service.qml` | All state and every `gh` `Process`: the ghPath resolver, the auth probe, the dashboard poller, the notifications poller. **Instantiated exactly once, machine-wide**, by `shell.ensureService()` the first time any bar widget or panel resolves it. |
| `BarWidget.qml` | The bar-slot entry point (one instance per monitor). Resolves the singleton via `shell.serviceFor("halmylyseas.github-status")`, always null-guarded — the bar paints before the service resolves. Owns the button + icon/count-pill, and hosts `Panel.qml` through an eager `Loader` (`active: true`). |
| `Panel.qml` | The popup: Hero, search, then five independently-foldable sections (Inbox, Review requests, My open PRs, My open issues, Repositories). Each session opens with every section folded; state is local only. During an active search, matching sections temporarily expand and zero-match sections fold, then clearing restores the manual layout. Receives `bar`, `settings`, `anchorItem`, `hostWidget` from `BarWidget.injectPanel()` — it resolves `service` itself via the same `shell.serviceFor()` call. |
| `Model.js` | Pure ES5 logic: `gh` JSON → UI-shape mapping functions, the URL allowlist, the failure classifier, field/list caps. No Quickshell imports, so plain Node can `require()` it (`test/model.test.js`). |
| `SectionHeader.qml` | Shared section header: label, right-aligned count/`"N of T"`/`"…"` pill, optional `extra` slot (the My open issues Subscribed chip), click-to-fold. |

### Injection contract

`BarWidget.qml` loads `Panel.qml` eagerly (`active: true`) and calls
`injectPanel()` on every load and every change to `bar`/`settings`, handing
over `bar`, `settings`, `anchorItem` (for `KeyboardPanel` positioning), and
`hostWidget`. `Panel.qml` resolves `service` itself the same way rather than
as a prop — both null-guard every `svc` read, since it may not have resolved
yet, or the shell may destroy/recreate it if the registry transiently
reports the plugin disabled at startup.

### Settings sources

`Service.qml` picks its settings source by capability, not host version:
`hasLegacyShellConfig` binds `settingsEntry` live to
`Model.entryFor(shell.shellConfig, id)`; `scopedHost` instead watches `shell.json` (see
below). Either way the four derived settings (`dashboardIntervalSec`,
`notificationsIntervalSec`, `repoLimit`, `issuesFilter`) clamp to manifest defaults when
`settingsEntry` is null, never a live `Timer.interval` binding (see "Process contract").
`settingsSource` and `settingsDiagnostic` report which path is active and why.

## Host compatibility

Supports Omarchy 4.0.1 or later. 4.0.1/4.0.2 inject the host shell directly
(`hasLegacyShellConfig`); 4.0.3 introduced a capability-scoped `PluginShellApi` facade
instead (`scopedHost`, `shellConfig` undefined). The facade supports
`shell.serviceFor(id)` and `shell.updateEntryInline(id, settings)` scoped to this
plugin's own id, but its `barConfig` copy only refreshes on a
plugin-list/widget-registry change, never an inline write — so `Service.qml` instead
watches `configPath` (`~/.config/omarchy/shell.json`, capped 1 MiB), keeping only its
own entry (`Model.ownEntryFromConfigText`). Startup never writes. Since
`updateEntryInline` replaces the whole entry, `setIssuesFilter` re-reads `shell.json`
with a blocking `FileView` right before a scoped write, closing the window between the
last watched reload and the write, and refuses to write (and logs why) whenever the
fresh entry is null rather than drop every sibling setting; `settingsDiagnostic` names
the exact cause, logged once per change, never per poll.
`test/probe/run-scoped-settings` drives the settings path through the installed facade
with a host-style write callback; the host's own write behavior is pinned lexically by
`test/host-contract.mjs`. Both run in `test/all` and CI.

## Process contract

**Every `gh` invocation is a direct Quickshell `Process` child** — never a shell
wrapper. `gh` is mise-installed, off Quickshell's PATH, so its path resolves once via
`bash -lc "type -P gh"` (the only shell call anywhere, chosen since it prints an
executable's real path, ignoring shell functions/aliases); every fetch after spawns `gh`
as a fixed argv array plus at most a sanitised ETag — never interpolated into a shell
string.

Five `Process` objects, one contract each (`Service.qml`):

| Process | Command | Deadline | Caps |
|---|---|---|---|
| `ghPathProc` | `["bash","-lc","type -P gh"]` | `ghPathTimeoutMs` (5s) | shared line/char caps |
| `ghVersionProc` | `[gh, "--version"]` | `ghVersionTimeoutMs` (5s) | shared line/char caps |
| `probeProc` | `[gh, "api", "user", "--jq", ".login"]` | `probeTimeoutMs` (30s) | shared line/char caps |
| `dashboardProc` | `[gh, "api", "graphql", "-f", "query="+Model.DASHBOARD_QUERY]` | `dashboardTimeoutMs` (30s) | `dashboardOutputCharsCap` (2MB, one JSON line) |
| `notificationsProc` | `[gh, "api", "-i", "notifications"[, "-H", "If-None-Match: <etag>"]]` | `notificationsTimeoutMs` (30s) | shared line/char caps |

**Watchdog pattern**: one `Timer` per process, interval assigned imperatively at arm
time (`_armProcess`), never a live `interval:` binding. On firing: `signal(15)`, then a
1s kill timer sends `signal(9)` only if the process is still running **and** its
`processId` matches the PID captured at `onStarted` — never escalate against a later
process.

**Failed-start semantics**: a `Process` whose binary can't be found flips `running` to
`false` **without ever emitting `exited`**. Every `Process` has an `onRunningChanged`
scheduling a `Qt.callLater` check, guarded by a per-kind generation counter (bumped on
arm, stamped by `onExited`) so a stale check never misfires against a newer process —
synthesizing exit code 127 when `exited` never came.

**Output caps**: one shared `_appendBoundedOutput` helper backs all five processes'
buffers, always **replaced** (never `.push()`ed) so bindings notice; a breach caps the
line to the limit, sends `signal(15)`, and increments an overflow counter.

## Status ladder and re-probe rules

`status` is `"ok" | "loading" | "no-gh" | "unauthenticated" | "offline" |
"rate-limited"`, computed by `worstOf()` over a fixed severity order
(`no-gh > unauthenticated > rate-limited > offline > loading > ok`).
Three independent sources feed it — the auth probe, the dashboard and
notifications pollers — each with its own `*Status`/`*LastSyncMs`/
`*RateLimitedUntilMs`. Once `internal.pollersActive` is true, `probeStatus`
is excluded: its only job is the initial "is `gh` usable" gate, and the
real pollers' own signal is authoritative after. On any transition to
`no-gh`/`unauthenticated`, both pollers stop (`pollersActive = false`)
and `reProbeTimer` (5 min, probe-shortenable) arms; `handleProbeResult`'s
success path clears a stale poller status back to `"loading"` — without
this, mid-session recovery (`gh` reappearing, re-authenticating) would
deadlock on a status nothing re-evaluates once set.

## Partial-dashboard accounting

`Model.mapDashboard` returns each of `openPRs`/`reviewRequests`/`repos`/ `myIssues` as
either a mapped array (`[]` is legitimately "nothing here") or `null` ("did not resolve,
don't replace"). `handleDashboardExit` reassigns only non-null sections, sets
`dashboardPartial` when some (not all) parsed, and treats it as full failure only when
**every** section is null — including a non-zero `gh` exit whose stdout still parses to
an object with object `data` (real GraphQL `errors` exit 1 but keep the full envelope).
Each section's real GraphQL `totalCount`/`issueCount` rides alongside it, `null` exactly
when that section is, letting `SectionHeader`'s pill read `"N of T"` past the
rendered/capped window. A genuine notifications HTTP 304 is success, not failure: the
ETag refreshes if a new one appears and `lastSyncMs` bumps, but `internal.notifications`
is deliberately **not** reassigned — conditional requests make an unchanged inbox cost
near-nothing. `Service.lastSyncMs` (`Model.oldestSync`) is the OLDEST of the two
sources' own sync markers, not the freshest, so the hero's "Synced X ago" is a lower
bound on every section's real freshness.

## CLI version pin

`Model.SUPPORTED_GH_MAJORS` lists the gh CLI major versions this plugin has been tested
against (matched on the leading segment: `2.98.0`/`2.0.0` both pin). `ghVersionProc`
reads `gh --version` once per path resolution into
`Service.ghVersion`/`ghVersionSupported`, adding a dim, non-severe status hint on an
unsupported result — never blocking pollers or `status`. `test/cli-contract.mjs` fails
loudly on an unpinned major.

## Security invariants

- **Read-only GitHub, always.** Only `gh api` GET and `gh api graphql`
  queries; never a mutation (`CLAUDE.md` rule 2).
- **URL allowlist + array-form exec.** `Model.isSafeGithubUrl()` requires
  the `^https://github\.com/` prefix, rejects a control character or
  whitespace right after it, and caps length; `Service.qml.openUrl` checks
  that before `Quickshell.execDetached(["xdg-open", url])` runs it.
- **`Text.PlainText` on every remote-derived `Text{}` sink** (enforced by
  `test/qml-sinks.test.js`, see "Testing" below) — a hostile relay/title/
  headline can never render as rich text. `SafeToolTip` in `Panel.qml` is
  a drop-in `PanelToolTip` replacement that forces this.
- **No disk cache of GitHub data.** Every list lives in QML memory only.
  The one thing this plugin writes to disk is its own settings entry via
  `bar.shell.updateEntryInline()`, which **replaces** the whole entry —
  `Model.mergedSettings()` merges from the loaded `settingsEntry`, and a
  null entry gets the write refused, not risked (see "Host compatibility").

## Accepted risks

- **The 1 MiB `shell.json` cap applies after the full read.** The
  `FileView` already holds the whole file in memory before
  `Model.ownEntryFromConfigText` rejects an oversized one, so a
  same-user process placing a huge file there costs memory once, not
  disk or a crash.
- **`StdioCollector`/`SplitParser` buffer a line in full until its
  newline**, before this plugin's own char caps see a byte — accepted,
  since the source is the user's own authenticated `gh` CLI.
- **`internal.login` never refreshes once known** — a mid-session `gh`
  account switch leaves isExternal/owner pills stale until a restart.
  Cosmetic only; every real API call uses `gh`'s actual identity.
- **One `IpcHandler` per monitor** (`Panel.qml` owns it) — a benign
  "Handler was registered but will not be used" warning per extra monitor.

## Dev workflow

Every save under `~/.config/omarchy/plugins/` reloads the whole bar, so
develop in a separate clone and deploy in one burst:

```bash
git -C ~/.config/omarchy/plugins/halmylyseas.github-status pull <work-clone> <branch>
omarchy restart shell   # required after structural / new-file changes
omarchy-shell halmylyseas.github-status __probe__   # "Function not found." = loaded
```

Installs and updates track the installed folder's branch **HEAD**, not a
specific reviewed commit — so `master` is release-only; work happens on a
feature/hardening branch and lands on `master` only when ready to ship.

## Testing

`bash test/all` runs, in order:

- `test/model.test.js` (Node) — every `Model.js` export, pure-function
  tests: adversarial input (control characters, oversized fields,
  malformed/partial GraphQL envelopes, list caps) plus real `gh` shapes.
- `test/qml-sinks.test.js` (Node) — scans every `.qml` file at the plugin
  root for a `Text{}` sink missing `textFormat: Text.PlainText`.
- `test/comment-hygiene.test.js` (Node) — scans every shipped file
  (`git ls-files`, `.github/**` exempt) for a comment run longer than 3
  lines or a forbidden project-log token.
- `test/cli-contract.mjs` (Node, read-only) — runs the real local `gh`:
  `--version`'s major must be in `Model.SUPPORTED_GH_MAJORS`; auth-gated
  checks run only when signed in, skipping cleanly (`SKIP:`) otherwise.
- `test/host-contract.mjs` (Node, read-only) — fails loudly if the
  installed `PluginShellApi.qml` gains `shellConfig`, drops
  `serviceFor`/`updateEntryInline`, or the host stops whole-entry-replacing.
- `test/probe/run` — a `qs -n -p` instance loading the real `Service.qml`
  against `test/mocks/gh` (argv-driven), covering the full status ladder:
  ok, unauthenticated/no-gh recovery, mid-session binary removal, offline,
  rate-limited (real reset-header round-trip), a hung `gh`, a flooding
  `gh`, a partial GraphQL envelope, a malformed notifications body, and an
  unpinned `gh --version` major. Asserts no orphaned process, qs exit 0.
- `test/probe/run-ui` — a second `qs -n -p` instance loading the real
  `BarWidget.qml`/`Panel.qml` against a stub `bar`/`shell`, plus the real
  `Service.qml` against the same mock `gh`. Covers rendered section
  counts, `"N of T"` pills, the degraded ladder, the partial-dashboard
  surface, search narrowing, fold/unfold, the `svc` null→new-instance
  lifecycle, and item navigation (rejected URLs stay open; a safe handoff
  closes the popup).
- `test/probe/run-scoped-settings` — a third `qs -n -p` instance driving
  the real `PluginShellApi.qml`/`BarWidget.qml`/`Panel.qml` against a temp
  `shell.json`: seeded values, no boot write, the toggle round trip
  preserving siblings, and malformed/deleted config.
- `omarchy plugin validate .` and qmllint on every `.qml` file must show 0
  errors before a commit that touches QML.

## CI

`.github/workflows/test.yml` runs qmllint (0 errors, at least 5 `.qml` files) and
`omarchy-plugin-validate` first, then the Node unit tests (including
`test/cli-contract.mjs`/`test/host-contract.mjs`) on `archlinux:latest`, then all three
probe suites under `cage` with a headless wlroots backend. The `omarchy` package itself
is never installed — only its `usr/share/omarchy/shell`/`usr/share/omarchy/bin` subtrees
are extracted (`-Swdd`, skipping dependency resolution) via an architecture-specific
glob (`omarchy-[0-9]*-*.pkg.tar.zst`) matching exactly one archive;
`test/ci-local [--no-cage]` mirrors the same steps.

## Releasing

Creating the public GitHub repository is a human step. Marketplace submission — the
`omacom/omarchy-plugin-marketplace` issue, six required headings, the AI-agent-clause
attestation — needs explicit human approval, never filed by an agent. Updates go through
a **Plugin verification** issue (template `verify-plugin.yml`) naming the plugin ID, the
repository URL, and the full 40-character SHA of the pushed `master` `HEAD`. Do not push
to `master` mid-review — approval is bound to the exact commit validated; editing the
open issue (never a second one) re-runs the bot's checks. Actions only runs once
`master` is pushed (needs a public remote) — `test/ci-local` is the pre-push proof;
check Actions is green shortly after.

## Credits

Author: HalmyLyseas.
