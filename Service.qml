// Service.qml -- data layer for halmylyseas.github-status.
//
// A singleton (per omarchy-shell's `service` kind, exchange/03-shell-api.md
// §3): instantiated once machine-wide by shell.ensureService(), cached in
// shell._services[id]. Owns every subprocess, timer, and piece of mutable
// state; BarWidget.qml/Panel.qml (S3) only ever bind to the read-only
// properties below and call refresh()/openUrl() -- they own no state of
// their own (the "split rule", 03-shell-api.md §3).
//
// Public API is the frozen contract from exchange/06-design.md's "Service
// public API" section -- property names/types/semantics are load-bearing
// for S3, which is coding against them concurrently. See "internal" below
// for everything that backs it.
//
// Security invariants enforced here (exchange/06-design.md "Security
// invariants", CLAUDE.md hard rules):
//   - Every `gh` invocation is a read-only GET/graphql `query` (scripts/*,
//     built by S1, are the only place the actual `gh` command line lives).
//   - No disk cache, no FileView -- every list below lives in QML memory
//     only and is lost on shell restart (accepted per 06-design.md).
//   - Every Process command array is a fixed constant PLUS at most two
//     variable argv elements: the plugin's own absolute script path
//     (resolved from this component's own URL, never user/remote input)
//     and, for fetch-notifications only, the previously-seen ETag (remote-
//     derived, but passed as a single separate argv element via bash -lc's
//     "$0"/"$1" positional-parameter mechanism -- never interpolated into
//     the -lc string itself). See "process command construction" below for
//     the mechanism and exchange/08-s2-service.md for the live probe that
//     verified it.
//   - openUrl() allowlists to Model.isSafeGithubUrl() and always spawns via
//     Quickshell.execDetached's array form (no shell).
//
// S6 fix pass (exchange/14-s6-fixes.md, applying exchange/11-s5a-security-
// review.md and exchange/12-s5b-correctness-review.md):
//   - probeProc now has the same 30s watchdog shape as the two pollers
//     (S5b Finding 1 -- previously a hung `gh api user` inside the auth
//     probe permanently stuck the service at "loading" with no recovery).
//   - Per-source health is now tracked internally (probe/dashboard/
//     notifications), each with its own status/lastSync/rate-limit state.
//     The public `status`/`lastSyncMs`/`rateLimitedUntil` properties are
//     *derived* (worst-of / max / whichever source is rate-limited) rather
//     than being written directly by whichever poller happened to finish
//     last (S5b Finding 2 -- this used to cause status flapping/masking
//     between the two independently-cadenced pollers).
//   - dashboardTimer/notificationsTimer's `interval` is assigned
//     imperatively at arm time (component completion, each time the timer
//     starts running, and at the top of each onTriggered), never bound
//     live to the settings properties (S5b Finding 3 -- a live-bound
//     interval silently discarded the in-progress countdown on any
//     settings edit).
//   - A partial GraphQL envelope (usable `data` for some sections
//     alongside `errors` for others) now keeps whichever sections parsed
//     instead of discarding the whole fetch (S5b Finding 4) -- see
//     Model.mapDashboard's per-section null contract.
//
// S8 delta pass (exchange/19-feedback-delta-spec.md, on top of 06-design.md):
//   - `myIssues` added as a public property, same replace-on-success/
//     keep-last-good-on-failure lifecycle as `openPRs` (F3).
//   - `repos` is now Model.sortRepos(internal.repos, repoSort) THEN sliced
//     by repoLimit -- internal.repos itself stays in raw query order; the
//     sort is applied at read time so a live repoSort change reorders
//     immediately (F1). `repoSort` + `setRepoSort(mode)` are new public
//     API: the setter persists through Model.mergedSettings (see its own
//     header comment for the "updateEntryInline replaces the whole entry"
//     trap this avoids), never a raw `{repoSort: mode}` write.
//   - probe-auth's stdout (the authenticated login, not a secret) is now
//     captured into `internal.login` and threaded into
//     Model.mapNotifications so notification rows can derive `isExternal`/
//     `owner` (F6) -- the REST notifications payload has no `viewer`-shaped
//     field to read a login from itself.
//
// S13 delta pass (exchange/26-feedback2-delta-spec.md, on top of the S8/S12
// passes above):
//   - G2: `comments(last: 1)` added to openPRs/myIssues/reviewRequests nodes
//     -- Model.mapOpenPRs/mapReviewRequests/mapMyIssues now also produce
//     `lastCommenter`/`lastCommentAt` per row (Model.lastComment()).
//   - G4: `myIssues` is now Model.filterIssues(internal.myIssues,
//     issuesFilter) -- filtered at READ time, same "sort/slice at read time,
//     store raw at fetch time" shape repos already uses for repoSort/
//     repoLimit (see the S8 note above). `issuesFilter`/`setIssuesFilter()`
//     are new public API, mirroring `repoSort`/`setRepoSort()` exactly
//     (validation, mergedSettings persistence, immediate apply via the same
//     live-binding-over-_settingsEntry mechanism). `myIssuesAllCount`
//     exposes the pre-filter length so the UI can show "Focus (3) / All
//     (9)"-style affordances.
//
// S12 fix pass (exchange/23-s11-delta-review.md, applying the PM's binding
// fix decisions in exchange/24-s12-release.md):
//   - F1: `dashboardLastSyncMs`/`notificationsLastSyncMs` added as public,
//     per-source sync markers (`lastSyncMs` above stays the blended one, for
//     the hero only) -- Panel.qml gates each SectionHeader's "…"-vs-
//     confirmed-"0" pill on the ONE source that actually backs that
//     section, not the two independently-timed pollers' Math.max.
//   - F2: `internal.login` can now be learned two ways instead of one --
//     (a) opportunistically off any dashboard response's own viewer.login
//     (handleDashboardExit), (b) reProbeTimer is kept alive
//     (maybeRearmReProbeForLogin) after a non-auth probe failure/watchdog
//     timeout specifically to keep retrying login capture, decoupled from
//     whether the pollers are already running.
//   - F3: accepted as a note, not fixed -- see docs/developers.md's
//     "Accepted risks".
//
// S18 delta pass (exchange/33-feedback3-delta-spec.md, H1/H3 -- H2 was a
// Panel.qml-only fix, see that file's own header comment):
//   - H3: `repoSort`/`setRepoSort()` and the read-time
//     `Model.sortRepos(internal.repos, repoSort)` call are REMOVED --
//     `repos` (below) is now a plain slice of `internal.repos` (itself
//     always in raw query order, GraphQL PUSHED_AT desc) by `repoLimit`,
//     no sort layer left. A `repoSort` key surviving in an existing user's
//     shell.json entry (pre-1.3) is harmless: nothing here reads it
//     anymore, and Model.mergedSettings's "current entry plus one changed
//     key" merge shape (still used by setIssuesFilter) preserves whatever
//     stale keys are already present rather than stripping them -- see
//     docs/developers.md.
//   - H1: `issuesFilter`/`setIssuesFilter()` themselves are UNCHANGED --
//     H1 only reshaped Panel.qml's Focus/All ButtonGroup into a single
//     "Subscribed" toggle chip; this file's contract and persistence
//     shape are exactly what S13 shipped.
import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

Item {
  id: root

  // ------------------------------------------------ injected by the shell
  // shell.ensureService() (shell.qml:283-321) injects whichever of these
  // properties exist on the root Item after createObject(); declare only
  // the ones this service actually consults.
  property var shell: null
  property var manifest: null

  // ============================================================
  // Service public API -- exchange/06-design.md, frozen contract. Every
  // property here is DERIVED from the per-source state in `internal` below
  // -- none of them are assigned directly (see "Status state machine").
  // ============================================================

  // "ok" | "loading" | "no-gh" | "unauthenticated" | "offline" | "rate-limited"
  readonly property string status: computeStatus()
  // Bumped by ANY source's success, including a notifications 304 --
  // 06-design.md's contract is "last time we successfully synced with
  // GitHub", not "last time a specific poller succeeded". Used for the
  // panel's hero "Synced Xm ago" line -- NOT for per-section "…"-vs-
  // confirmed-"0" pill gating (see the two per-source properties below;
  // exchange/23-s11-delta-review.md F1).
  readonly property double lastSyncMs: Math.max(internal.dashboardLastSyncMs, internal.notifLastSyncMs)
  // exchange/23-s11-delta-review.md F1: per-source sync markers, exposed
  // publicly so Panel.qml can gate each SectionHeader's "…"-vs-confirmed-"0"
  // pill on the ONE source that actually backs that section, instead of the
  // blended `lastSyncMs` above. Both pollers fire on essentially every cold
  // start in the same JS tick (`triggeredOnStart: true` on both timers,
  // below) and race independently -- gating all five sections on whichever
  // one happens to finish first meant up to four sections could show a
  // false confirmed-"0" (their own backing arrays still at the untouched
  // `[]` startup default) the moment the OTHER poller's fetch won the race.
  // Inbox is the only section backed by the notifications poller; Review
  // requests/My PRs/My issues/Repo activity are all backed by the single
  // combined dashboard fetch.
  readonly property double dashboardLastSyncMs: internal.dashboardLastSyncMs
  readonly property double notificationsLastSyncMs: internal.notifLastSyncMs
  readonly property string rateLimitedUntil: pickRateLimitedUntil()
  readonly property bool busy: dashboardProc.running || notificationsProc.running

  readonly property var notifications: internal.notifications
  readonly property int unreadCount: internal.notifications.filter(function (n) {
    return n && n.unread === true
  }).length
  readonly property var reviewRequests: internal.reviewRequests
  readonly property var openPRs: internal.openPRs
  // exchange/19-feedback-delta-spec.md F3: same lifecycle/state handling as
  // openPRs -- per-source (well, per-dashboard-fetch) replace on success via
  // Model.mapDashboard's null-vs-[] contract, keep-last-good on failure.
  // exchange/26-feedback2-delta-spec.md G4: filtered per `issuesFilter` at
  // READ time (same "raw at fetch time, derived at read time" split repos
  // below uses for repoLimit) -- a live issuesFilter change re-filters
  // instantly with no new fetch. internal.myIssues itself always holds the
  // full, unfiltered last-good list.
  readonly property var myIssues: Model.filterIssues(internal.myIssues, root.issuesFilter)
  // G4: pre-filter count, so the UI can show "Focus (3) / All (9)"-style
  // affordances without needing internal.myIssues directly.
  readonly property int myIssuesAllCount: internal.myIssues.length
  // exchange/33-feedback3-delta-spec.md H3: sliced by repoLimit (a setting,
  // min 3/max 30) only -- the F1 sort layer (Model.sortRepos/repoSort) is
  // removed; internal.repos is always stored in raw query order (GraphQL
  // PUSHED_AT desc, scripts/fetch-dashboard's own ORDER BY), and repoLimit
  // is applied here on top of Model.js's own fixed CAP_REPOS=30 -- see
  // "Settings" below.
  readonly property var repos: internal.repos.slice(0, root.repoLimit)
  readonly property bool hasAttention:
    internal.openPRs.some(function (p) { return p && p.ciState === "failure" })
    || internal.reviewRequests.length > 0

  // Manual refresh: runs both fetches now. No-op while a fetch from either
  // poller is already in flight (03-shell-api.md §6 re-entrancy rule) --
  // the individual trigger functions also self-guard, so this is belt and
  // suspenders, not the only guard.
  function refresh() {
    // Deliberately checks the two Process.running values directly rather
    // than the cached `busy` property above: measured live against this
    // Quickshell version (0.3.1) that a computed `readonly property bool
    // busy: a || b` does not always re-evaluate synchronously within the
    // same JS call stack that flips `a`/`b` (it lags to the next event-loop
    // turn in some cases) -- see exchange/08-s2-service.md for the probe
    // that caught this. Reading the two Process.running values directly is
    // always accurate the instant they're set, so the no-op guard here
    // uses those, not the property a caller outside this file would read.
    if (dashboardProc.running || notificationsProc.running) {
      log("refresh() requested but already busy -- ignored")
      return
    }
    log("refresh() -- running both fetches now")
    triggerDashboardFetch()
    triggerNotificationsFetch()
  }

  // Validates against Model.isSafeGithubUrl (anchored to https://github.com/)
  // before spawning xdg-open as an argument array -- never a shell string,
  // so there is no injection surface even though `url` is remote-derived
  // (a notification/PR/repo URL built by Model.js's mappers).
  function openUrl(url) {
    if (!Model.isSafeGithubUrl(url)) {
      log("openUrl: rejected non-github.com url")
      return
    }
    Quickshell.execDetached(["xdg-open", url])
  }

  // G4 (exchange/26-feedback2-delta-spec.md): validates `mode` (anything
  // other than exactly "all" becomes "focus"), then persists it via
  // shell.updateEntryInline -- trap 10 (see Model.mergedSettings's own
  // header comment): that host call REPLACES the whole settings entry with
  // whatever keys it's handed, so this always builds the FULL next-state
  // object (current settings entry + the one changed key) rather than a
  // bare `{issuesFilter: mode}`, or every other persisted setting
  // (dashboardIntervalSec, notificationsIntervalSec, repoLimit) would be
  // silently dropped on every toggle. "Applies immediately":
  // `root.issuesFilter` below is a live binding over
  // `_settingsEntry`/`shellConfig`, so `myIssues` (filtered at read time,
  // above) re-evaluates the instant updateEntryInline reassigns
  // shell.shellConfig -- no separate internal state to keep in sync.
  function setIssuesFilter(mode) {
    var next = validIssuesFilter(mode)
    if (!shell || typeof shell.updateEntryInline !== "function") {
      log("setIssuesFilter: shell.updateEntryInline unavailable -- cannot persist")
      return
    }
    shell.updateEntryInline("halmylyseas.github-status", Model.mergedSettings(root._settingsEntry, "issuesFilter", next))
    log("issuesFilter set to " + next)
  }

  // ============================================================
  // Settings: shell.json entry for this plugin, manifest defaults as
  // fallback. Plain readonly bindings off shell.shellConfig (itself a live
  // QML property on the shell root, not a snapshot) -- reassigning
  // shellConfig anywhere upstream (mutateShellConfig, updateEntryInline,
  // config reload) re-evaluates every property below automatically. This
  // is the same "just bind, don't subscribe" pattern Ristretto's
  // Service.qml uses for sleepSeconds/dryRun (Service.qml:31-34).
  //
  // NOTE: this is the settings *value* itself, which is fine to keep live
  // -- what must NOT be a live binding is a Timer.interval built from it
  // (see dashboardTimer/notificationsTimer below, S5b Finding 3).
  // ============================================================

  readonly property var _shellConfig: shell ? shell.shellConfig : null
  readonly property var _settingsEntry: findEntry(_shellConfig, "halmylyseas.github-status")

  readonly property int dashboardIntervalSec:
    clampInt(settingInt(_settingsEntry, "dashboardIntervalSec", manifestDefault("dashboardIntervalSec", 180)), 60, 3600)
  readonly property int notificationsIntervalSec:
    clampInt(settingInt(_settingsEntry, "notificationsIntervalSec", manifestDefault("notificationsIntervalSec", 60)), 60, 600)
  readonly property int repoLimit:
    clampInt(settingInt(_settingsEntry, "repoLimit", manifestDefault("repoLimit", 10)), 3, 30)
  // G4: "focus" (default) or "all" -- validIssuesFilter() is the single
  // point that decides what counts as a legal value, so a hand-edited (or
  // stale) shell.json entry with a garbage/missing issuesFilter value falls
  // back to "focus" rather than crashing or showing an undefined mode.
  readonly property string issuesFilter:
    validIssuesFilter(settingStr(_settingsEntry, "issuesFilter", manifestDefault("issuesFilter", "focus")))

  // shell.json's bar-layout entries can be a bare string ("halmylyseas.
  // github-status") instead of an object ({id: "..."}) -- that form
  // renders fine but cannot carry settings at all (updateEntryInline only
  // matches object entries, 03-shell-api.md §11). Delayed so shellConfig
  // has time to move past its transient built-in-defaults state at boot
  // (Ristretto's Service.qml:370-379 precedent, same 15s delay).
  Timer {
    interval: 15000
    running: true
    repeat: false
    onTriggered: {
      if (root.findEntry(root._shellConfig, "halmylyseas.github-status") === null) {
        root.log("no config entry found for this plugin -- settings cannot persist, " +
            "manifest defaults are in effect (a string-form bar-layout entry has " +
            "this effect; it must be an object with an id key to hold settings)")
      }
    }
  }

  function findEntry(config, id) {
    if (!config) return null
    var layout = config.bar && config.bar.layout ? config.bar.layout : null
    var sections = ["left", "center", "right"]
    if (layout) {
      for (var s = 0; s < sections.length; s++) {
        var arr = layout[sections[s]] || []
        for (var i = 0; i < arr.length; i++) {
          if (arr[i] && arr[i].id === id) return arr[i]
        }
      }
    }
    var plugins = config.plugins || []
    for (var j = 0; j < plugins.length; j++) {
      if (plugins[j] && plugins[j].id === id) return plugins[j]
    }
    return null
  }

  function settingInt(entry, key, fallback) {
    if (!entry) return fallback
    var v = entry[key]
    if (v === undefined || v === null) return fallback
    var n = Number(v)
    return isNaN(n) ? fallback : n
  }

  function settingStr(entry, key, fallback) {
    if (!entry) return fallback
    var v = entry[key]
    if (v === undefined || v === null) return fallback
    return String(v)
  }

  function clampInt(v, lo, hi) {
    return Math.max(lo, Math.min(hi, v))
  }

  function validIssuesFilter(mode) {
    return mode === "all" ? "all" : "focus"
  }

  function manifestDefault(key, hardFallback) {
    if (root.manifest && root.manifest.barWidget && root.manifest.barWidget.defaults
        && root.manifest.barWidget.defaults[key] !== undefined) {
      return root.manifest.barWidget.defaults[key]
    }
    return hardFallback
  }

  // ============================================================
  // Plugin-dir resolution: the one and only place any script path is
  // computed. Never remote/user input -- Qt.resolvedUrl(".") resolves
  // against THIS component's own file:// URL, which is fixed at install
  // time (the plugin's own directory).
  // ============================================================

  readonly property string pluginDir: resolvePluginDir()

  function resolvePluginDir() {
    var s = String(Qt.resolvedUrl("."))
    if (s.indexOf("file://") === 0) s = s.slice("file://".length)
    try { s = decodeURIComponent(s) } catch (e) { /* leave as-is */ }
    if (s.length > 1 && s.charAt(s.length - 1) === "/") s = s.slice(0, -1)
    return s
  }

  // ============================================================
  // Internal state -- everything the public API above is derived from.
  // Kept in one QtObject so it reads unambiguously as "not part of the
  // contract" next to the readonly properties above.
  //
  // Per-source tracking (S5b Finding 2): the auth probe, the dashboard
  // poller, and the notifications poller each own their own status/sync/
  // rate-limit state. Nothing here is touched by more than one of
  // handleProbeResult/handleDashboardExit/handleNotificationsExit (plus
  // their matching watchdogs).
  // ============================================================

  QtObject {
    id: internal
    property string probeStatus: "loading"
    property string dashboardStatus: "loading"
    property string notifStatus: "loading"

    property double dashboardLastSyncMs: 0
    property double notifLastSyncMs: 0

    property double dashboardRateLimitedUntilMs: 0
    property string dashboardRateLimitedUntil: ""
    property double notifRateLimitedUntilMs: 0
    property string notifRateLimitedUntil: ""
    property double probeRateLimitedUntilMs: 0
    property string probeRateLimitedUntil: ""

    property var notifications: []
    property var reviewRequests: []
    property var openPRs: []
    property var repos: []
    property var myIssues: []

    property string notificationsEtag: ""

    // The authenticated account's own login, learned once from
    // scripts/probe-auth's stdout on a successful probe (exchange/19-
    // feedback-delta-spec.md F6). Not a secret -- GitHub usernames are
    // public, same rationale probe-auth's own header comment gives for
    // printing it at all. Threaded into Model.mapNotifications (the REST
    // notifications payload has no `viewer`-shaped field to read a login
    // from, unlike the GraphQL dashboard envelope, which carries its own
    // `viewer.login` end to end through Model.mapDashboard already).
    property string login: ""

    // Gate on the two pollers below. False at startup and while the
    // service does not yet have a *resolved* auth signal, or has lost one
    // mid-session (06-design.md: "Slow re-probe (5 min) in the first two
    // states; no fast retry loops" / "normal pollers stopped"). Once true,
    // stays true unless the OVERALL derived status becomes no-gh/
    // unauthenticated again (see the root Item's onStatusChanged below) --
    // offline/rate-limited never touch this flag, matching the original
    // ladder ("keep polling on the normal cadence" for both).
    property bool pollersActive: false

    // Tracks the last value `status` was logged at, so the onStatusChanged
    // handler below can log "X -> Y" without needing the change signal to
    // carry the previous value itself.
    property string lastLoggedStatus: "loading"

    // Set true by a watchdog immediately before it force-stops a hung
    // Process; the resulting onExited is then a kill artifact, not a real
    // response, so the exit handler skips re-processing it (the watchdog
    // itself already called the failure handler once, synchronously).
    property bool dashWatchdogFired: false
    property bool notifWatchdogFired: false
    property bool probeWatchdogFired: false
  }

  // ============================================================
  // Status state machine
  // ============================================================

  function log(message) {
    console.log("qml: github-status " + message)
  }

  // Severity ladder, most severe first (exchange/12-s5b-correctness-
  // review.md F2's exact ordering). worstOf picks whichever of the two
  // inputs is more severe (lower index); an unrecognized string is treated
  // as "loading" (a status this file never actually assigns is not worth
  // crashing over).
  function worstOf(a, b) {
    var order = ["no-gh", "unauthenticated", "rate-limited", "offline", "loading", "ok"]
    var ai = order.indexOf(a); if (ai < 0) ai = order.indexOf("loading")
    var bi = order.indexOf(b); if (bi < 0) bi = order.indexOf("loading")
    return ai <= bi ? a : b
  }

  // The public `status` is the worst-of across whichever sources currently
  // matter. Deliberately excludes probeStatus once the pollers are engaged
  // (internal.pollersActive === true): the probe's only job is the initial
  // "is gh even usable" gate, run once (plus on every re-probe while
  // blocked). Without this exclusion, a single probe result classified as
  // e.g. "offline" (the F1 watchdog fix, when `gh api user` hangs) would
  // permanently drag the overall status down even after both real pollers
  // go on to succeed -- see exchange/14-s6-fixes.md for the reasoning.
  // Once pollers are active, the real, continuously-refreshed signal is
  // whatever the dashboard/notifications pollers themselves report, which
  // will independently re-discover no-gh/unauthenticated/rate-limited/
  // offline for real if any of those conditions actually recur.
  function computeStatus() {
    if (!internal.pollersActive) {
      return worstOf(worstOf(internal.probeStatus, internal.dashboardStatus), internal.notifStatus)
    }
    return worstOf(internal.dashboardStatus, internal.notifStatus)
  }

  // rateLimitedUntil only ever reflects a source that is CURRENTLY
  // rate-limited (never a stale value left over from a source that has
  // since recovered) -- if more than one source happens to be rate-limited
  // at once, show whichever resets soonest.
  function pickRateLimitedUntil() {
    var candidates = []
    if (internal.dashboardStatus === "rate-limited") {
      candidates.push({ until: internal.dashboardRateLimitedUntil, ms: internal.dashboardRateLimitedUntilMs })
    }
    if (internal.notifStatus === "rate-limited") {
      candidates.push({ until: internal.notifRateLimitedUntil, ms: internal.notifRateLimitedUntilMs })
    }
    if (!internal.pollersActive && internal.probeStatus === "rate-limited") {
      candidates.push({ until: internal.probeRateLimitedUntil, ms: internal.probeRateLimitedUntilMs })
    }
    if (candidates.length === 0) return ""
    candidates.sort(function (a, b) { return a.ms - b.ms })
    return candidates[0].until
  }

  // The one place the derived `status` is observed and acted on: logs
  // every real transition, and stops both pollers + arms the re-probe
  // cycle whenever the WORST current source is no-gh/unauthenticated --
  // whether that came from the initial probe or from a poller discovering
  // it mid-session (e.g. a token revoked while already running).
  onStatusChanged: {
    log("status: " + internal.lastLoggedStatus + " -> " + status)
    internal.lastLoggedStatus = status
    if (status === "no-gh" || status === "unauthenticated") {
      internal.pollersActive = false
      reProbeTimer.restart()
    }
  }

  function setProbeStatus(s) { internal.probeStatus = s }
  function setDashboardStatus(s) { internal.dashboardStatus = s }
  function setNotifStatus(s) { internal.notifStatus = s }

  // cls is one of Model.classifyFailure's tags: "no-gh" | "http-304" |
  // "unauthenticated" | "rate-limited" | "offline" | "error". "http-304"
  // is handled by callers before this is reached (it's success, not
  // failure). "error" (an unclassified failure -- classifyFailure's own
  // fallback bucket) is deliberately mapped to "offline" rather than left
  // unmapped: the Service API's status enum has no "error" member, and
  // treating an unrecognized failure shape as an outage (keep last-good
  // data, keep retrying on the normal cadence) fails safer than either
  // silently doing nothing or freezing polling on a state with no defined
  // recovery path. Flagged as a deliberate mapping, not a spec gap, in
  // exchange/08-s2-service.md.
  function mapClassifiedStatus(cls) {
    switch (cls) {
      case "no-gh": return "no-gh"
      case "unauthenticated": return "unauthenticated"
      case "rate-limited": return "rate-limited"
      case "offline": return "offline"
      default: return "offline"
    }
  }

  // source is "probe" | "dashboard" | "notifications". Records the
  // rate-limit reset time (if this classifies as rate-limited) against
  // ONLY that source, then updates that source's own status -- a
  // rate-limited dashboard poller never touches the notifications poller's
  // state or vice versa (S5b Finding 2's "pause only the affected poller").
  function handleFetchFailure(source, cls, rawText) {
    var mapped = mapClassifiedStatus(cls)
    if (mapped === "rate-limited") {
      var untilMs = parseRateLimitReset(rawText)
      if (!untilMs) untilMs = Date.now() + 60 * 60 * 1000  // fallback: +60min
      var label = formatHHMM(untilMs)
      if (source === "dashboard") {
        internal.dashboardRateLimitedUntilMs = untilMs
        internal.dashboardRateLimitedUntil = label
      } else if (source === "notifications") {
        internal.notifRateLimitedUntilMs = untilMs
        internal.notifRateLimitedUntil = label
      } else if (source === "probe") {
        internal.probeRateLimitedUntilMs = untilMs
        internal.probeRateLimitedUntil = label
      }
      log(source + " rate-limited, resuming at " + label)
    }
    if (source === "dashboard") setDashboardStatus(mapped)
    else if (source === "notifications") setNotifStatus(mapped)
    else if (source === "probe") setProbeStatus(mapped)
  }

  // source is "probe" | "dashboard" | "notifications". Clears that
  // source's own rate-limit state and bumps its own lastSyncMs (probe has
  // no lastSyncMs of its own -- it isn't a data sync).
  function onFetchSuccess(source) {
    var now = Date.now()
    if (source === "dashboard") {
      internal.dashboardLastSyncMs = now
      internal.dashboardRateLimitedUntil = ""
      internal.dashboardRateLimitedUntilMs = 0
      setDashboardStatus("ok")
    } else if (source === "notifications") {
      internal.notifLastSyncMs = now
      internal.notifRateLimitedUntil = ""
      internal.notifRateLimitedUntilMs = 0
      setNotifStatus("ok")
    } else if (source === "probe") {
      internal.probeRateLimitedUntil = ""
      internal.probeRateLimitedUntilMs = 0
      setProbeStatus("ok")
    }
  }

  // Best-effort extraction of GitHub's X-Ratelimit-Reset (unix epoch
  // seconds) out of whatever text is available -- present on the raw -i
  // header block for fetch-notifications (headers arrive even on a 403),
  // essentially never present for fetch-dashboard (plain `gh api graphql`,
  // no -i, so a 403 there has no headers at all -- the +60min fallback in
  // handleFetchFailure is what actually fires for that path). Never
  // throws; returns 0 (== "not parseable") on no match.
  function parseRateLimitReset(text) {
    var t = String(text || "")
    var m = /X-Ratelimit-Reset:\s*"?(\d+)"?/i.exec(t)
    if (!m) return 0
    var epochSec = parseInt(m[1], 10)
    if (isNaN(epochSec) || epochSec <= 0) return 0
    return epochSec * 1000
  }

  function pad2(n) { return (n < 10 ? "0" : "") + n }
  function formatHHMM(ms) {
    var d = new Date(ms)
    return pad2(d.getHours()) + ":" + pad2(d.getMinutes())
  }

  // Truncates a JSON value to a short, log-safe preview -- used only for
  // GraphQL's own `errors` array (server-authored error text about the
  // query itself, not attacker-controlled remote content), capped
  // defensively so a pathological error payload can't bloat the log.
  function briefJson(v) {
    try { return JSON.stringify(v).slice(0, 500) } catch (e) { return String(v).slice(0, 500) }
  }

  // ============================================================
  // Auth probe (scripts/probe-auth): run once at startup, and again every
  // 5 minutes while the derived status is no-gh/unauthenticated
  // (06-design.md degradation ladder). Exit codes are the stable contract
  // documented in scripts/probe-auth's own header (0 ok / 3 no-gh /
  // 4 unauthenticated / 5 other -- classify further via
  // Model.classifyFailure).
  //
  // probeWatchdog (S5b Finding 1): a hung `gh api user` used to leave
  // probeProc.running permanently true, making startProbe()'s own
  // re-entrancy guard silently no-op every future re-probe (including
  // reProbeTimer's every-5-minute attempts) forever -- the plugin never
  // recovered without a manual shell/plugin restart. This mirrors
  // dashWatchdog/notifWatchdog exactly: force-stop after 30s and treat it
  // as a real (if inconclusive) result, never a wedge. Classified as
  // "offline", not "no-gh" -- a hang is network-shaped (DNS/TCP not
  // resolving/connecting), not "the binary is missing", and "offline"
  // does not block polling, so the pollers get a chance to try for
  // themselves as soon as the watchdog fires.
  // ============================================================

  function startProbe() {
    if (probeProc.running) return
    probeWatchdog.restart()
    probeProc.running = true
  }

  Process {
    id: probeProc
    command: ["bash", "-lc", 'exec "$0"', root.pluginDir + "/scripts/probe-auth"]
    // StdioCollector has no byte ceiling (Quickshell doesn't expose one) --
    // accepted risk (exchange/11-s5a-security-review.md F5): bounded in
    // practice by `gh api user`'s own tiny response shape and this file's
    // 30s watchdog, not by an explicit size limit here.
    stdout: StdioCollector { id: probeOut; waitForEnd: true }
    stderr: StdioCollector { id: probeErr; waitForEnd: true }
    onExited: function (exitCode, exitStatus) {
      probeWatchdog.stop()
      if (internal.probeWatchdogFired) { internal.probeWatchdogFired = false; return }
      root.handleProbeResult(exitCode, probeOut.text, probeErr.text)
    }
  }

  function handleProbeResult(exitCode, stdoutText, stderrText) {
    if (exitCode === 0) {
      // exchange/19-feedback-delta-spec.md F6: probe-auth prints the
      // authenticated login (not a secret -- see its own header comment) on
      // stdout on success. Trimmed defensively (a trailing newline is the
      // only thing ever actually present) -- Model.mapNotifications treats
      // a missing/empty login as "never external" rather than throwing, so
      // a malformed capture here degrades gracefully, not fatally.
      var login = String(stdoutText || "").replace(/^\s+|\s+$/g, "")
      if (login) internal.login = login
      log("probe-auth: authenticated" + (login ? " as " + login : ""))
      onFetchSuccess("probe")
      internal.pollersActive = true
      return
    }
    if (exitCode === 3) { setProbeStatus("no-gh"); reProbeTimer.restart(); return }
    if (exitCode === 4) { setProbeStatus("unauthenticated"); reProbeTimer.restart(); return }
    // exit 5: probe-auth's own coarse "some other failure" bucket --
    // classify precisely from stderr, but this alone must never block
    // polling (only a confirmed no-gh/unauthenticated does that).
    var cls = Model.classifyFailure(stderrText, exitCode)
    handleFetchFailure("probe", cls, stderrText)
    if (internal.probeStatus === "no-gh" || internal.probeStatus === "unauthenticated") {
      reProbeTimer.restart()
    } else {
      internal.pollersActive = true
      maybeRearmReProbeForLogin()
    }
  }

  // exchange/23-s11-delta-review.md F2: a probe failure classified as
  // offline/rate-limited/error (i.e. NOT no-gh/unauthenticated -- those
  // branches above already restart reProbeTimer for their own reason, to
  // unblock the pollers) used to leave internal.login unset for the rest of
  // the session with nothing left to ever retry capturing it, since
  // reProbeTimer's only other restart sites are the no-gh/unauthenticated
  // branches. The ordinary trigger is exactly the boring case -- network
  // not up yet at shell startup/resume-from-suspend, so probe-auth's very
  // first attempt times out into probeWatchdog or fails with a transient
  // "offline"/"error" classification -- not a rare edge case. This keeps
  // the slow (5min) re-probe cadence alive purely to retry learning the
  // login, without re-blocking the pollers (already set active by the
  // caller before this runs): once internal.login is non-empty, this is a
  // no-op forever, including via the opportunistic dashboard-response
  // capture in handleDashboardExit, which is the more common way login
  // actually ends up populated once the pollers are running.
  function maybeRearmReProbeForLogin() {
    if (!internal.login) reProbeTimer.restart()
  }

  Timer {
    id: reProbeTimer
    interval: 300000  // 5 min, per the degradation ladder's "slow re-probe"
    repeat: false
    onTriggered: root.startProbe()
  }

  Timer {
    id: probeWatchdog
    interval: 30000
    repeat: false
    onTriggered: {
      if (probeProc.running) {
        root.log("auth probe watchdog: exceeded 30s, killing")
        internal.probeWatchdogFired = true
        probeProc.running = false
        root.handleFetchFailure("probe", "offline", "watchdog: auth probe exceeded 30s")
        // Never block polling on an inconclusive/timed-out probe alone --
        // let the real pollers discover the true state for themselves.
        internal.pollersActive = true
        // exchange/23-s11-delta-review.md F2: same reasoning as
        // maybeRearmReProbeForLogin's own comment -- a hung probe (this
        // watchdog's whole reason for existing) is exactly the scenario
        // where the login never gets learned otherwise.
        root.maybeRearmReProbeForLogin()
      }
    }
  }

  // ============================================================
  // Dashboard fetch (scripts/fetch-dashboard -- combined GraphQL query):
  // openPRs + reviewRequests + repos in one call. Never blanks the UI on
  // failure -- internal.openPRs/reviewRequests/repos are only ever
  // reassigned when Model.mapDashboard says that specific section actually
  // parsed (03-shell-api.md §6 "keep stale data visible on failure";
  // exchange/12-s5b-correctness-review.md Finding 4 for the per-section
  // partial-success case).
  // ============================================================

  Timer {
    id: dashboardTimer
    // Placeholder only -- reassigned imperatively at arm time below (S5b
    // Finding 3: a live binding here silently discards the in-progress
    // countdown on any settings edit). A settings change takes effect at
    // the next natural cycle boundary (onTriggered) or the next time this
    // timer starts running (onRunningChanged), never mid-countdown.
    interval: 180000
    running: internal.pollersActive
    repeat: true
    triggeredOnStart: true
    onRunningChanged: if (running) interval = Math.max(60, root.dashboardIntervalSec) * 1000
    onTriggered: {
      interval = Math.max(60, root.dashboardIntervalSec) * 1000
      root.triggerDashboardFetch()
    }
  }

  function triggerDashboardFetch() {
    if (dashboardProc.running) return
    if (root.status === "no-gh" || root.status === "unauthenticated") return
    if (internal.dashboardStatus === "rate-limited" && Date.now() < internal.dashboardRateLimitedUntilMs) return
    dashWatchdog.restart()
    dashboardProc.running = true
  }

  Process {
    id: dashboardProc
    // Fixed at build time: the only variable argv element is pluginDir,
    // which is resolved from this component's own file:// URL, never from
    // remote/user input.
    command: ["bash", "-lc", 'exec "$0"', root.pluginDir + "/scripts/fetch-dashboard"]
    // StdioCollector has no byte ceiling (Quickshell doesn't expose one) --
    // accepted risk (exchange/11-s5a-security-review.md F5): bounded in
    // practice by the GraphQL query's own first:20/first:20/first:10 caps,
    // gh-side timeouts, and this file's 30s watchdog, not by an explicit
    // size limit here.
    stdout: StdioCollector { id: dashOut; waitForEnd: true }
    stderr: StdioCollector { id: dashErr; waitForEnd: true }
    onExited: function (exitCode, exitStatus) {
      dashWatchdog.stop()
      if (internal.dashWatchdogFired) { internal.dashWatchdogFired = false; return }
      root.handleDashboardExit(exitCode, dashOut.text, dashErr.text)
    }
  }

  function handleDashboardExit(exitCode, rawOut, rawErr) {
    if (exitCode === 0) {
      var parsed = null
      try { parsed = JSON.parse(rawOut) } catch (e) { parsed = null }
      var mapped = parsed ? Model.mapDashboard(parsed) : { openPRs: null, reviewRequests: null, repos: null, myIssues: null, login: "" }
      var gotSomething = mapped.openPRs !== null || mapped.reviewRequests !== null || mapped.repos !== null || mapped.myIssues !== null
      if (gotSomething) {
        if (mapped.openPRs !== null) internal.openPRs = mapped.openPRs
        if (mapped.reviewRequests !== null) internal.reviewRequests = mapped.reviewRequests
        if (mapped.repos !== null) internal.repos = mapped.repos
        if (mapped.myIssues !== null) internal.myIssues = mapped.myIssues
        // exchange/23-s11-delta-review.md F2 (part a): opportunistic login
        // capture. Every dashboard response carries viewer.login whenever
        // any viewer-scoped section resolved -- a free, no-extra-call way
        // to learn internal.login if the auth probe itself never got the
        // chance to (its own first attempt failed non-auth, or hung into
        // probeWatchdog -- see handleProbeResult/probeWatchdog's
        // maybeRearmReProbeForLogin calls for the other half of this fix).
        // Only ever sets FROM empty -- never overwrites an already-known
        // login (the probe's own value, once learned, stays authoritative;
        // exchange/23 F3 is the accepted-risk note on stale logins across a
        // mid-session `gh` account switch, documented in developers.md).
        if (mapped.login && !internal.login) {
          internal.login = mapped.login
          log("login learned opportunistically from dashboard response: " + internal.login)
          // Re-map isExternal on whatever notifications are already held in
          // memory, once, so already-fetched inbox rows don't have to wait
          // out a full notificationsIntervalSec poll to gain a correct
          // owner pill. Cheap: internal.notifications is the already-mapped
          // list (Service.qml never retains the raw REST body past
          // handleNotificationsExit), and every item already carries its
          // own `owner` field independent of login -- see
          // Model.remapNotificationsExternal's own header comment.
          if (internal.notifications.length > 0) {
            internal.notifications = Model.remapNotificationsExternal(internal.notifications, internal.login)
          }
        }
        if (parsed && parsed.errors) {
          log("dashboard fetch: partial GraphQL errors -- kept the section(s) that parsed, "
            + "discarded the rest: " + briefJson(parsed.errors))
        }
        onFetchSuccess("dashboard")
      } else {
        log("dashboard fetch: no usable data in JSON envelope -- keeping last-good data")
        handleFetchFailure("dashboard", "error",
          rawErr || (parsed && parsed.errors ? briefJson(parsed.errors) : "unparseable/empty JSON"))
      }
      return
    }
    var cls = Model.classifyFailure(rawErr, exitCode)
    handleFetchFailure("dashboard", cls, rawErr)
  }

  Timer {
    id: dashWatchdog
    interval: 30000
    repeat: false
    onTriggered: {
      if (dashboardProc.running) {
        root.log("dashboard fetch watchdog: exceeded 30s, killing")
        internal.dashWatchdogFired = true
        dashboardProc.running = false
        root.handleFetchFailure("dashboard", "offline", "watchdog: dashboard fetch exceeded 30s")
      }
    }
  }

  // ============================================================
  // Notifications fetch (scripts/fetch-notifications [etag]): conditional
  // GET, ETag round-tripped. gh exits non-zero with "HTTP 304" on a
  // genuine no-change response (04-github-data.md §2, live-observed) --
  // that specific shape is success (bump lastSyncMs), not a failure.
  // Headers (including a possibly-refreshed ETag) arrive on stdout even on
  // a 304, per S1's byte-level capture (exchange/07-s1-scaffold.md).
  // ============================================================

  Timer {
    id: notificationsTimer
    // Placeholder only -- see dashboardTimer's comment above (S5b
    // Finding 3); same assign-at-arm pattern.
    interval: 60000
    running: internal.pollersActive
    repeat: true
    triggeredOnStart: true
    onRunningChanged: if (running) interval = Math.max(60, root.notificationsIntervalSec) * 1000
    onTriggered: {
      interval = Math.max(60, root.notificationsIntervalSec) * 1000
      root.triggerNotificationsFetch()
    }
  }

  function triggerNotificationsFetch() {
    if (notificationsProc.running) return
    if (root.status === "no-gh" || root.status === "unauthenticated") return
    if (internal.notifStatus === "rate-limited" && Date.now() < internal.notifRateLimitedUntilMs) return
    // The ETag is the one remote-derived value in this whole service. It
    // is passed as its own argv element ($1), never interpolated into the
    // -lc string -- see the header comment and exchange/08-s2-service.md
    // for the live probe that verified bash -lc's "$0"/"$1" positional-
    // parameter mechanism actually behaves this way against this system's
    // bash.
    notificationsProc.command = ["bash", "-lc", 'exec "$0" "$1"',
      root.pluginDir + "/scripts/fetch-notifications", internal.notificationsEtag]
    notifWatchdog.restart()
    notificationsProc.running = true
  }

  Process {
    id: notificationsProc
    // StdioCollector has no byte ceiling (Quickshell doesn't expose one) --
    // accepted risk (exchange/11-s5a-security-review.md F5): bounded in
    // practice by fetch-notifications never passing --paginate (one
    // default-sized REST page only), gh-side timeouts, and this file's 30s
    // watchdog, not by an explicit size limit here.
    stdout: StdioCollector { id: notifOut; waitForEnd: true }
    stderr: StdioCollector { id: notifErr; waitForEnd: true }
    onExited: function (exitCode, exitStatus) {
      notifWatchdog.stop()
      if (internal.notifWatchdogFired) { internal.notifWatchdogFired = false; return }
      root.handleNotificationsExit(exitCode, notifOut.text, notifErr.text)
    }
  }

  function handleNotificationsExit(exitCode, rawOut, rawErr) {
    if (exitCode === 0) {
      var parsed = Model.parseHeadersAndBody(rawOut)
      if (parsed.etag) internal.notificationsEtag = parsed.etag
      if (parsed.body !== null) {
        internal.notifications = Model.mapNotifications(parsed.body, internal.login)
      }
      onFetchSuccess("notifications")
      return
    }
    var cls = Model.classifyFailure(rawErr, exitCode)
    if (cls === "http-304") {
      // No-change: still refresh the etag if gh printed a new header block
      // (it shouldn't differ on a 304, but nothing forbids it) and count
      // this as a successful sync -- 06-design.md is explicit that a 304
      // is "no change", not an error.
      var parsed304 = Model.parseHeadersAndBody(rawOut)
      if (parsed304.etag) internal.notificationsEtag = parsed304.etag
      log("notifications: no change (304)")
      onFetchSuccess("notifications")
      return
    }
    handleFetchFailure("notifications", cls, rawOut + "\n" + rawErr)
  }

  Timer {
    id: notifWatchdog
    interval: 30000
    repeat: false
    onTriggered: {
      if (notificationsProc.running) {
        root.log("notifications fetch watchdog: exceeded 30s, killing")
        internal.notifWatchdogFired = true
        notificationsProc.running = false
        root.handleFetchFailure("notifications", "offline", "watchdog: notifications fetch exceeded 30s")
      }
    }
  }

  // ============================================================
  Component.onCompleted: {
    log("service ready (pluginDir=" + root.pluginDir
      + " dashboardIntervalSec=" + root.dashboardIntervalSec
      + " notificationsIntervalSec=" + root.notificationsIntervalSec
      + " repoLimit=" + root.repoLimit
      + " issuesFilter=" + root.issuesFilter + ")")
    startProbe()
  }
}
