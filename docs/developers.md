# Developer notes

The design record for this plugin, for a contributor starting from a bare
clone. The README covers using it; `CLAUDE.md` carries the hard rules;
`docs/threat-model.md` carries the security model.

## Architecture

| File | Role |
|---|---|
| `manifest.json` | Kinds `["service", "bar-widget"]`, `keepLoaded: true`. `entryPoints.service` is `Service.qml`, `entryPoints.barWidget` is `BarWidget.qml`. |
| `Service.qml` | All state and every `gh` `Process`: the ghPath resolver, the auth probe, the dashboard poller, the notifications poller. **Instantiated exactly once, machine-wide**, by `shell.ensureService()` the first time any bar widget or panel resolves it. |
| `BarWidget.qml` | The bar-slot entry point (one instance per monitor). Resolves the singleton via `shell.serviceFor("halmylyseas.github-status")`, always null-guarded — the bar paints before the service resolves. Owns the button + icon/count-pill, and hosts `Panel.qml` through an eager `Loader` (`active: true`). |
| `Panel.qml` | The popup: Hero, search, then five independently-foldable sections (Inbox, Review requests, My open PRs, My open issues, Repositories). Each session opens with every section folded; state is local only. Receives `bar`, `settings`, `anchorItem`, `hostWidget` from `BarWidget.injectPanel()` — it resolves `service` itself via the same `shell.serviceFor()` call. |
| `Model.js` | Pure ES5 logic: `gh` JSON → UI-shape mapping functions, the URL allowlist, the failure classifier, field/list caps. No Quickshell imports, so plain Node can `require()` it (`test/model.test.js`). |
| `SectionHeader.qml` | Shared section header: label, right-aligned count/`"N of T"`/`"…"` pill, optional `extra` slot (the My open issues Subscribed chip), click-to-fold. |

### Injection contract

`BarWidget.qml` loads `Panel.qml` eagerly (`active: true`, not lazily on
first click) and calls `injectPanel()` on every load and on every change to
`bar`/`settings`, handing over `bar`, `settings`, `anchorItem` (the bar
button, for `KeyboardPanel` positioning), and `hostWidget`. `Panel.qml`
resolves `service` itself, the same way `BarWidget.qml` does, rather than
receiving it as a prop — both files independently null-guard every `svc`
read, since the service may not have resolved yet on first paint, and the
shell can destroy and recreate a plugin's service instance if the plugin
registry transiently reports it disabled at startup.

### `settings` vs. the service

The bar-widget `settings` object (`dashboardIntervalSec`,
`notificationsIntervalSec`, `repoLimit`, `issuesFilter`) belongs to the
shell's own `shell.json` entry for this plugin; `Service.qml` reads it
live off `shell.shellConfig` via `findEntry()`, with manifest defaults and
clamped ranges as fallback — never a live `Timer.interval` binding built
directly from one of these (see "Process contract" below).

## Process contract

**Every `gh` invocation is a direct Quickshell `Process` child** — no shell
wrapper anywhere on the CLI path. `gh` is mise-installed, not on
Quickshell's own PATH, so its absolute path is resolved once via a single
`bash -lc "type -P gh"` call (the only shell invocation anywhere in this
plugin, and the only form that always prints an executable's real path,
ignoring shell functions/aliases); every fetch after that spawns `gh`
itself as a fixed argv array plus at most a sanitised ETag as a separate
element — never interpolated into a shell string.

Five `Process` objects, one contract each (`Service.qml`):

| Process | Command | Deadline | Caps |
|---|---|---|---|
| `ghPathProc` | `["bash","-lc","type -P gh"]` | `ghPathTimeoutMs` (5s) | shared line/char caps |
| `ghVersionProc` | `[gh, "--version"]` | `ghVersionTimeoutMs` (5s) | shared line/char caps |
| `probeProc` | `[gh, "api", "user", "--jq", ".login"]` | `probeTimeoutMs` (30s) | shared line/char caps |
| `dashboardProc` | `[gh, "api", "graphql", "-f", "query="+Model.DASHBOARD_QUERY]` | `dashboardTimeoutMs` (30s) | `dashboardOutputCharsCap` (2MB, one JSON line) |
| `notificationsProc` | `[gh, "api", "-i", "notifications"[, "-H", "If-None-Match: <etag>"]]` | `notificationsTimeoutMs` (30s) | shared line/char caps |

**Watchdog pattern**: one `Timer` per process, interval assigned
imperatively at arm time (`_armProcess`), never a live `interval:` binding.
On firing: `signal(15)` (SIGTERM), then a 1s kill timer sends `signal(9)`
only if the process is still running **and** its `processId` still matches
the PID captured at its own `onStarted` — never escalate against a later
process the queue already started in its place.

**Failed-start semantics**: a `Process` whose binary can't be found flips
`running` to `false` **without ever emitting `exited`**. Every `Process`
has an `onRunningChanged` that schedules a `Qt.callLater` check, guarded by
a per-kind generation counter (bumped on every arm, stamped by the real
`onExited`) so a stale deferred check can never misfire against a newer,
still-running process — this synthesizes exit code 127 exactly when a real
`exited` never came.

**Output caps**: one shared `_appendBoundedOutput` helper backs all five
processes' buffers. Arrays are always **replaced**, never `.push()`ed, so
QML bindings notice. On breach, the line is capped so the total lands at
the limit, `signal(15)` is sent, and an overflow counter increments.

## Status ladder and re-probe rules

`status` is `"ok" | "loading" | "no-gh" | "unauthenticated" | "offline" |
"rate-limited"`, computed by `worstOf()` over a fixed severity order
(`no-gh > unauthenticated > rate-limited > offline > loading > ok`). Three
independent sources feed it: the auth probe, the dashboard poller, and the
notifications poller, each with their own `*Status`/`*LastSyncMs`/
`*RateLimitedUntilMs`. Once `internal.pollersActive` is true, `probeStatus`
is excluded from `computeStatus()` — its only job is the initial "is `gh`
even usable" gate, and once the real pollers are running their own signal
is authoritative.

On any transition to `no-gh`/`unauthenticated`, both pollers stop
(`pollersActive = false`) and `reProbeTimer` (5 min, probe-shortenable)
arms. `handleProbeResult`'s success path clears a stale
`no-gh`/`unauthenticated` poller status back to `"loading"` — without this,
mid-session recovery (`gh` reappearing, re-authenticating) would deadlock
on a status nothing will ever update, since nothing re-evaluates a blocked
poller's own status once it is set.

## Partial-dashboard accounting

`Model.mapDashboard` returns each of `openPRs`/`reviewRequests`/`repos`/
`myIssues` as either a mapped array (however many nodes — `[]` is a
legitimate "nothing here") or `null` ("did not resolve, don't replace").
`handleDashboardExit` reassigns only the sections that came back non-null,
sets `dashboardPartial` when some (not all) parsed, and only routes to the
full-failure path when **every** section is null. Real `gh` exits 1 on a
GraphQL `errors` response while stdout still carries the full envelope, so
a non-zero exit whose stdout parses to an object with an object `data`
takes this same path. Each section's real
GraphQL `totalCount`/`issueCount` rides alongside it, `null` exactly when
that section is — this is what lets `SectionHeader`'s pill read `"N of T"`
once the real total exceeds the rendered/capped window.

A genuine notifications HTTP 304 (no-change) is success, not failure: the
ETag is refreshed if a new one appears, `lastSyncMs` bumps, but
`internal.notifications` is deliberately **not** reassigned (no signal
fires) — the conditional-request contract that makes an unchanged inbox
cost near-nothing.

`Service.lastSyncMs` (`Model.oldestSync`) is the OLDEST of the two
sources' own sync markers, not the freshest, so the hero's "Synced X ago"
is always a lower bound on every section's real freshness.

## CLI version pin

`Model.SUPPORTED_GH_MAJORS` lists the gh CLI major versions this plugin
has actually been tested against, matched on the leading major segment
only (`2.98.0` and `2.0.0` both count as pinned). `ghVersionProc` reads
`gh --version` once per gh path resolution into `Service.ghVersion`/
`ghVersionSupported` (`""`/`null` until known). An unsupported result adds
a dim, non-severe line to `Panel.qml`'s status hint — never blocks the
pollers or changes `status`, since this is a display concern, not an
auth/connectivity one. `test/cli-contract.mjs` fails loudly if the real
installed CLI ever drifts to an unpinned major.

## Security invariants

- **Read-only GitHub, always.** Only `gh api` GET and `gh api graphql`
  queries; never a mutation (`CLAUDE.md` rule 2).
- **URL allowlist + array-form exec.** `Model.isSafeGithubUrl()` requires
  the `^https://github\.com/` prefix, rejects any control character or
  whitespace right after it, and caps overall length; `Service.qml.openUrl`
  checks that, then calls `Quickshell.execDetached(["xdg-open", url])` — an
  argv array, never a shell string.
- **`Text.PlainText` on every remote-derived `Text{}` sink** (enforced by
  `test/qml-sinks.test.js`, which scans every `.qml` file's `Text{}` bodies)
  — a hostile relay/title/headline can never be interpreted as rich text.
  `SafeToolTip` in `Panel.qml` is a drop-in `PanelToolTip` replacement that
  forces this, since the first-party tooltip does not.
- **No disk cache of GitHub data.** Every list lives in QML memory only.
  The one thing this plugin writes to disk is its own settings entry, via
  `bar.shell.updateEntryInline()`, which **replaces** the whole entry —
  `Model.mergedSettings()` always builds current-plus-one-changed-key so a
  single-setting write can never clobber the others.

## Accepted risks

- **`StdioCollector`/`SplitParser` buffer a line in full until its
  newline** — an adversarial response with no newline would be buffered by
  Quickshell itself before this plugin's own char caps see a byte. Accepted:
  the source is the user's own authenticated `gh` CLI.
- **`internal.login` never refreshes once known** — a mid-session `gh`
  account switch leaves isExternal/owner pills using the stale identity
  until a restart. Cosmetic only; every real API call still uses whichever
  identity `gh` itself is actually authenticated as.
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
specific reviewed commit — so `master` is release-only; day-to-day work
happens on a feature/hardening branch and only merges to `master` when
ready to ship.

## Testing

`bash test/all` runs, in order:

- `test/model.test.js` (Node) — every `Model.js` export, pure-function
  tests: adversarial input (control characters, oversized fields,
  malformed/partial GraphQL envelopes, huge arrays to exercise list caps)
  plus real captured `gh` output shapes.
- `test/qml-sinks.test.js` (Node) — scans every `.qml` file at the plugin
  root for a `Text{}` sink missing `textFormat: Text.PlainText`.
- `test/comment-hygiene.test.js` (Node) — scans every shipped file
  (`git ls-files`, `.github/**` exempt) for a comment run longer than 3
  lines or a forbidden project-log token; kept clean by the same rule
  this file's own prose follows.
- `test/cli-contract.mjs` (Node, read-only) — runs the real local `gh`:
  `--version`'s major must be in `Model.SUPPORTED_GH_MAJORS` (never
  skipped, even without auth); `gh auth status` and `gh api user --jq
  .login` only run when actually signed in. Skips cleanly (exit 0 +
  `SKIP:`) when `gh` is absent or unauthenticated — CI has the CLI but no
  credentials.
- `test/probe/run` — a `qs -n -p` instance loading the real `Service.qml`
  against `test/mocks/gh` (a PATH/absolute-path-shadowed mock driven
  entirely by argv), driving the full status ladder: ok, unauthenticated
  recovery, no-gh recovery, mid-session binary removal/recovery, offline,
  rate-limited (with a real reset-header round-trip), a hung `gh` (watchdog
  fires), a flooding `gh` (output cap fires), a partial GraphQL envelope,
  a malformed notifications 200 body, and an unpinned `gh --version` major
  (`ghVersionSupported=false`, status unaffected). Asserts no orphaned mock
  process, qs exit 0, and no engine errors in the log.
- `test/probe/run-ui` — a second `qs -n -p` instance loading the real
  `BarWidget.qml` (which eagerly loads `Panel.qml`) against a stub
  `bar`/`shell`, plus the real `Service.qml` against the same mock `gh`.
  Covers rendered section counts vs. the fixture, `"N of T"` pills, the
  degraded ladder (including the non-severe "untested gh version" hint),
  the partial-dashboard surface, live search narrowing, fold/unfold against
  the actual rendered tree, the `svc` null→new-instance lifecycle (zero
  TypeErrors), and the `openUrl` allowlist (a non-github URL never reaches
  the PATH-shadowed `xdg-open` mock).
- `omarchy plugin validate .` and qmllint on every `.qml` file must show 0
  errors before a commit that touches QML.

## CI

`.github/workflows/test.yml` runs qmllint (0 errors, at least 5 `.qml`
files) and `omarchy-plugin-validate` first, then the Node unit tests and
`test/cli-contract.mjs`, on `archlinux:latest`, then both probe suites
under `cage` with a headless wlroots backend. The `omarchy` package is
never installed there — only its `usr/share/omarchy/shell` and
`usr/share/omarchy/bin` subtrees are extracted from the downloaded package
(`-Swdd`, skipping dependency resolution so the extraction glob matches
exactly one archive). `test/ci-local [--no-cage]` mirrors the same steps
on a dev box.

## Releasing

Creating the public GitHub repository is a human step. Marketplace
submission — the `HANCORE-linux/omarchy-plugin-marketplace` issue, six
required headings, the AI-agent-clause attestation — needs explicit human
approval and is never filed by an agent. Updates after listing go through a
**Plugin verification** issue (template `verify-plugin.yml`, "Verify and
publish a newer upstream commit") naming the plugin ID
(`halmylyseas.github-status`), the repository URL, and the full 40-character
SHA of the pushed `master` `HEAD`. Do not push to `master` mid-review of a
pending submission or verification issue — approval is bound to the exact
commit that was validated. Editing an open issue (never opening a second
one) re-runs the bot's checks. The GitHub Actions workflow only starts
running once `master` is actually pushed (a `push`/`pull_request` trigger
needs a public remote) — `test/ci-local` is the pre-push proof; check the
Actions tab is green shortly after the first push.

## Credits

Author: HalmyLyseas.
