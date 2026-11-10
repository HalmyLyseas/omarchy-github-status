# Threat model

Scope: `halmylyseas.github-status`, an Omarchy shell plugin driven entirely
by the user's local `gh` CLI. See `CONTRIBUTING.md` for the hard rules this model
assumes are enforced, and `docs/developers.md` for architecture detail.

## Assets

- **The user's GitHub credential.** Entered once into `gh` outside this
  plugin's control; this plugin never reads, logs, stores, or has any
  visibility into it.
- **GitHub data confidentiality on screen.** Notifications, PR/issue/repo
  titles, commit headlines, and login names are rendered in the bar/panel;
  they must never leak into a place a shoulder-surfer or screen-share
  wouldn't expect (never logged in full to disk, never sent anywhere but
  the user's own screen and, on click, github.com in the browser).
- **Truthfulness of the status/attention icon.** The bar glyph's urgent
  recolor and the panel's status ladder (`ok`/`loading`/`no-gh`/
  `unauthenticated`/`offline`/`rate-limited`/`api-error`) must never claim a
  state GitHub itself does not actually report: a GitHub-side error (an
  HTTP 5xx, an exit-0 malformed body, or the plugin's own output cap
  cutting off a real response) is shown as a GitHub API error, with the
  HTTP status or a `"response too large"` detail when known — never
  folded into `offline`. The reverse also holds: a watchdog timeout means
  `gh` never actually answered, so it is reported as `offline`, never as
  a GitHub-side API error.

## Trust boundaries and their guard

| Boundary | Guarded by |
|---|---|
| `gh` stdout/stderr | `Model.js`'s bounded parsers (`FIELD_CAP_*`/list caps) and `classifyFailure()`/`parseHeadersAndBody()` before any value reaches a `Service.qml` property; every `Text{}` sink is `textFormat: Text.PlainText` (enforced by `test/qml-sinks.test.js`), so a hostile title/headline can never be interpreted as rich text. |
| Persisted plugin settings (`shell.json`) | `Service.qml`'s own clamps (`dashboardIntervalSec`/`notificationsIntervalSec`/`repoLimit` ranges, `issuesFilter` enum) and `Model.mergedSettings()` — replaces only this plugin's own entry, never another plugin's; refused outright when no valid entry is loaded (see next row), never written with a partial guess. |
| Search-field clipboard paste | Native shortcut, dedicated Paste key and middle-click/primary-selection routes are intercepted. `PasteJob.qml` runs `/usr/bin/wl-paste` as a direct child, caps the retained text at 4,096 characters, enforces a 1.5 s deadline with TERM→KILL, sweeps `wl-paste`'s direct children with `pkill -P` before signalling the parent, and is cancelled on panel close. Control characters (0x00-0x1F, 0x7F-0x9F) are stripped, and the query is capped at 100 characters before it reaches the filter. |
| Scoped read of `~/.config/omarchy/shell.json` | On a host without a live `shell.shellConfig` (`scopedHost`), `Service.qml` opens a watched, non-preloading `FileView` on this file, read-only. The `FileView` reads the whole file regardless of size; `Model.ownEntryFromConfigText()` then rejects the text after reading if it exceeds 1 MiB, so the cap bounds what is parsed and retained, not the read itself. Below that cap it parses the text and retains only this plugin's own entry (a JSON round-tripped copy); anything else is discarded. This plugin never writes this file — the host writes it, via `updateEntryInline()`. |
| Omarchy shell internals (`bar.shell.*`) | `serviceFor(id)` (read) and `updateEntryInline()` (the plugin's one write, replacing only its own `shell.json` entry) are undocumented, unversioned surface; `BarWidget.qml` null-guards every `svc` read since the service may not have resolved yet or may be destroyed/recreated by the shell. On a scoped host this surface is a capability-scoped facade limited to this plugin's own id, not the host shell itself. |

## What the plugin cannot do

- It never sees a GitHub credential, a webhook payload, or anything outside
  what the user's own already-authenticated `gh` CLI is willing to return.
- It cannot mutate anything on GitHub: every call is `gh api` GET or
  `gh api graphql` with a fixed, non-mutating query (`CONTRIBUTING.md` rule 2).
- It cannot modify anything under `/usr/share/omarchy/` (rule 5). Its one
  write into Omarchy shell internals is its own `shell.json` entry, via
  `bar.shell.updateEntryInline()`; everything else it only reads/reacts to.
- It cannot open anything but a `https://github.com/...` URL, and never
  through a shell (rule 4).

## Residual risks

- **A clipboard provider can still fill the kernel pipe before the cap
  kills it.** `PasteJob.qml` bounds what the plugin retains and how long it
  waits, but the provider controls its write rate; the cap is not a
  producer-side bandwidth guarantee.
- **`StdioCollector`/`SplitParser` buffer a line in full until its
  newline.** A `gh` process emitting an unterminated stream has that output
  buffered by Quickshell itself before this plugin's own caps
  (`finiteOutputChars`/`dashboardOutputCharsCap`) see a byte. Accepted:
  the source is the user's own authenticated `gh` CLI talking to GitHub's
  API, not an untrusted process.
- **The mise shim, not `gh` itself, is `Service.qml`'s direct child during
  path resolution.** `resolveGhPath()`'s one shell invocation
  (`bash -lc "type -P gh"`) is a login shell resolving PATH through mise;
  every fetch *after* that point spawns the resolved absolute `gh` path
  directly, with no shell in between. Accepted because the command line is
  fixed (no remote/user data) and only the resulting path is read. A login
  shell sources the user's profile before `type -P`; that profile is part
  of the trusted local environment, exactly as it is for any login shell.
- **Login changes require a response carrying `viewer.login`.** The auth
  probe and dashboard apply a normalized login and remap completed rows,
  but if every response after a local `gh auth switch` omits
  `viewer.login`, the plugin cannot observe the switch and keeps the
  last-known identity. `gh` itself remains the authenticated identity for
  every API call.

## Out of scope

- Compromise of the `gh` CLI itself, the user's GitHub account, or the
  Omarchy shell process.
- Supply-chain integrity of the installed `gh` binary or the `omarchy`
  shell package — this plugin trusts what is already installed and
  authenticated on the machine.
- Physical or local access, kernel-level attacks, or anything not reachable
  through this plugin's own `gh`-argv, settings, or URL-open surface.

## CI as part of this boundary

`.github/**` is exempt from the repo's own comment-hygiene scan
(`test/comment-hygiene.test.js`) and, by extension, from `CONTRIBUTING.md` rule
4's package-manager-literal restriction: workflow files are CI-only
infrastructure, never installed on or executed by an end user's machine,
and legitimately need `pacman`-shaped commands to build a disposable test
container. `README.md` and `docs/developers.md` remain prose-only `.md`
files with no command literals of their own.
