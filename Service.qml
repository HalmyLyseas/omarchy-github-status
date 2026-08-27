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
  // Service public API -- exchange/06-design.md, frozen contract.
  // ============================================================

  // "ok" | "loading" | "no-gh" | "unauthenticated" | "offline" | "rate-limited"
  readonly property string status: internal.status
  readonly property double lastSyncMs: internal.lastSyncMs        // 0 until first success
  readonly property string rateLimitedUntil: internal.rateLimitedUntil  // "" or "HH:MM"
  readonly property bool busy: dashboardProc.running || notificationsProc.running

  readonly property var notifications: internal.notifications
  readonly property int unreadCount: internal.notifications.filter(function (n) {
    return n && n.unread === true
  }).length
  readonly property var reviewRequests: internal.reviewRequests
  readonly property var openPRs: internal.openPRs
  // repoLimit (a setting, min 3/max 30) is applied here, on top of
  // Model.js's own fixed CAP_REPOS=30 -- see "Settings" below.
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

  // ============================================================
  // Settings: shell.json entry for this plugin, manifest defaults as
  // fallback. Plain readonly bindings off shell.shellConfig (itself a live
  // QML property on the shell root, not a snapshot) -- reassigning
  // shellConfig anywhere upstream (mutateShellConfig, updateEntryInline,
  // config reload) re-evaluates every property below automatically. This
  // is the same "just bind, don't subscribe" pattern Ristretto's
  // Service.qml uses for sleepSeconds/dryRun (Service.qml:31-34).
  // ============================================================

  readonly property var _shellConfig: shell ? shell.shellConfig : null
  readonly property var _settingsEntry: findEntry(_shellConfig, "halmylyseas.github-status")

  readonly property int dashboardIntervalSec:
    clampInt(settingInt(_settingsEntry, "dashboardIntervalSec", manifestDefault("dashboardIntervalSec", 180)), 60, 3600)
  readonly property int notificationsIntervalSec:
    clampInt(settingInt(_settingsEntry, "notificationsIntervalSec", manifestDefault("notificationsIntervalSec", 60)), 60, 600)
  readonly property int repoLimit:
    clampInt(settingInt(_settingsEntry, "repoLimit", manifestDefault("repoLimit", 10)), 3, 30)

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

  function clampInt(v, lo, hi) {
    return Math.max(lo, Math.min(hi, v))
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
  // ============================================================

  QtObject {
    id: internal
    property string status: "loading"
    property double lastSyncMs: 0
    property string rateLimitedUntil: ""
    property double rateLimitedUntilMs: 0

    property var notifications: []
    property var reviewRequests: []
    property var openPRs: []
    property var repos: []

    property string notificationsEtag: ""

    // Gate on the two pollers below. False at startup and while status is
    // no-gh/unauthenticated (06-design.md: "Slow re-probe (5 min) in the
    // first two states; no fast retry loops" / "normal pollers stopped").
    // True for every other state, including offline/rate-limited: those
    // two keep polling on the normal cadence (offline) or on the normal
    // cadence but skipping the fetch until rateLimitedUntilMs passes
    // (rate-limited) -- see triggerDashboardFetch/triggerNotificationsFetch.
    property bool pollersActive: false

    // Set true by a watchdog immediately before it force-stops a hung
    // Process; the resulting onExited is then a kill artifact, not a real
    // response, so the exit handler skips re-processing it (the watchdog
    // itself already called handleFetchFailure once, synchronously).
    property bool dashWatchdogFired: false
    property bool notifWatchdogFired: false
  }

  // ============================================================
  // Status state machine
  // ============================================================

  function log(message) {
    console.log("qml: github-status " + message)
  }

  function setStatus(newStatus) {
    if (internal.status === newStatus) return
    log("status: " + internal.status + " -> " + newStatus)
    internal.status = newStatus
    if (newStatus === "no-gh" || newStatus === "unauthenticated") {
      internal.pollersActive = false
      reProbeTimer.restart()
    }
  }

  function onFetchSuccess() {
    internal.lastSyncMs = Date.now()
    internal.rateLimitedUntil = ""
    internal.rateLimitedUntilMs = 0
    setStatus("ok")
  }

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

  function handleFetchFailure(cls, rawText) {
    var mapped = mapClassifiedStatus(cls)
    if (mapped === "rate-limited") {
      var untilMs = parseRateLimitReset(rawText)
      if (!untilMs) untilMs = Date.now() + 60 * 60 * 1000  // fallback: +60min
      internal.rateLimitedUntilMs = untilMs
      internal.rateLimitedUntil = formatHHMM(untilMs)
      log("rate-limited, resuming at " + internal.rateLimitedUntil)
    }
    setStatus(mapped)
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

  // ============================================================
  // Auth probe (scripts/probe-auth): run once at startup, and again every
  // 5 minutes while status is no-gh/unauthenticated (06-design.md
  // degradation ladder). Exit codes are the stable contract documented in
  // scripts/probe-auth's own header (0 ok / 3 no-gh / 4 unauthenticated /
  // 5 other -- classify further via Model.classifyFailure).
  // ============================================================

  function startProbe() {
    if (probeProc.running) return
    probeProc.running = true
  }

  Process {
    id: probeProc
    command: ["bash", "-lc", 'exec "$0"', root.pluginDir + "/scripts/probe-auth"]
    stdout: StdioCollector { id: probeOut; waitForEnd: true }
    stderr: StdioCollector { id: probeErr; waitForEnd: true }
    onExited: function (exitCode, exitStatus) {
      root.handleProbeResult(exitCode, probeErr.text)
    }
  }

  function handleProbeResult(exitCode, stderrText) {
    if (exitCode === 0) {
      log("probe-auth: authenticated")
      if (internal.status === "no-gh" || internal.status === "unauthenticated") {
        internal.status = "loading"
      }
      internal.pollersActive = true
      return
    }
    if (exitCode === 3) { setStatus("no-gh"); return }
    if (exitCode === 4) { setStatus("unauthenticated"); return }
    // exit 5: probe-auth's own coarse "some other failure" bucket --
    // classify precisely from stderr, but this alone must never block
    // polling (only a confirmed no-gh/unauthenticated does that).
    var cls = Model.classifyFailure(stderrText, exitCode)
    handleFetchFailure(cls, stderrText)
    if (internal.status !== "no-gh" && internal.status !== "unauthenticated") {
      internal.pollersActive = true
    }
  }

  Timer {
    id: reProbeTimer
    interval: 300000  // 5 min, per the degradation ladder's "slow re-probe"
    repeat: false
    onTriggered: root.startProbe()
  }

  // ============================================================
  // Dashboard fetch (scripts/fetch-dashboard -- combined GraphQL query):
  // openPRs + reviewRequests + repos in one call. Never blanks the UI on
  // failure -- internal.openPRs/reviewRequests/repos are only ever
  // reassigned on a successful parse (03-shell-api.md §6 "keep stale data
  // visible on failure").
  // ============================================================

  Timer {
    id: dashboardTimer
    interval: Math.max(60, root.dashboardIntervalSec) * 1000
    running: internal.pollersActive
    repeat: true
    triggeredOnStart: true
    onTriggered: root.triggerDashboardFetch()
  }

  function triggerDashboardFetch() {
    if (dashboardProc.running) return
    if (internal.status === "no-gh" || internal.status === "unauthenticated") return
    if (internal.status === "rate-limited" && Date.now() < internal.rateLimitedUntilMs) return
    dashWatchdog.restart()
    dashboardProc.running = true
  }

  Process {
    id: dashboardProc
    // Fixed at build time: the only variable argv element is pluginDir,
    // which is resolved from this component's own file:// URL, never from
    // remote/user input.
    command: ["bash", "-lc", 'exec "$0"', root.pluginDir + "/scripts/fetch-dashboard"]
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
      if (parsed && !parsed.errors) {
        var mapped = Model.mapDashboard(parsed)
        internal.openPRs = mapped.openPRs
        internal.reviewRequests = mapped.reviewRequests
        internal.repos = mapped.repos
        onFetchSuccess()
      } else {
        log("dashboard fetch: malformed/errors JSON envelope -- keeping last-good data")
        handleFetchFailure("error", rawErr || (parsed ? JSON.stringify(parsed.errors) : "unparseable JSON"))
      }
      return
    }
    var cls = Model.classifyFailure(rawErr, exitCode)
    handleFetchFailure(cls, rawErr)
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
        root.handleFetchFailure("offline", "watchdog: dashboard fetch exceeded 30s")
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
    interval: Math.max(60, root.notificationsIntervalSec) * 1000
    running: internal.pollersActive
    repeat: true
    triggeredOnStart: true
    onTriggered: root.triggerNotificationsFetch()
  }

  function triggerNotificationsFetch() {
    if (notificationsProc.running) return
    if (internal.status === "no-gh" || internal.status === "unauthenticated") return
    if (internal.status === "rate-limited" && Date.now() < internal.rateLimitedUntilMs) return
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
        internal.notifications = Model.mapNotifications(parsed.body)
      }
      onFetchSuccess()
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
      onFetchSuccess()
      return
    }
    handleFetchFailure(cls, rawOut + "\n" + rawErr)
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
        root.handleFetchFailure("offline", "watchdog: notifications fetch exceeded 30s")
      }
    }
  }

  // ============================================================
  Component.onCompleted: {
    log("service ready (pluginDir=" + root.pluginDir
      + " dashboardIntervalSec=" + root.dashboardIntervalSec
      + " notificationsIntervalSec=" + root.notificationsIntervalSec
      + " repoLimit=" + root.repoLimit + ")")
    startProbe()
  }
}
