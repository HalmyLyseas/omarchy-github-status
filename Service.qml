// Service.qml -- data layer for halmylyseas.github-status. A singleton,
// instantiated once machine-wide by shell.ensureService(); see
// docs/developers.md "Architecture"/"Process contract" for the full shape.
import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

Item {
  id: root

  // ------------------------------------------------ injected by the shell
  property var shell: null
  property var manifest: null

  // ============================================================
  // Service public API. Every property is DERIVED from `internal` below.
  // ============================================================

  // "ok" | "loading" | "no-gh" | "unauthenticated" | "offline" | "rate-limited"
  readonly property string status: computeStatus()
  // "last time we successfully synced with GitHub" -- bumped by any
  // source's success, including a notifications 304.
  readonly property double lastSyncMs: Math.max(internal.dashboardLastSyncMs, internal.notifLastSyncMs)
  // Per-source sync markers so Panel.qml can gate each SectionHeader's
  // "..."-vs-confirmed-"0" pill on the one source that actually backs it.
  readonly property double dashboardLastSyncMs: internal.dashboardLastSyncMs
  readonly property double notificationsLastSyncMs: internal.notifLastSyncMs
  // Set when the last-applied dashboard fetch parsed some but not all
  // sections -- surfaced on the panel's "Synced * partial" hero line.
  readonly property bool dashboardPartial: internal.dashboardPartial
  readonly property string rateLimitedUntil: pickRateLimitedUntil()
  // Debug-only: raw epoch-ms companions to rateLimitedUntil's formatted
  // string, so a probe can poll "has the window actually passed" precisely.
  readonly property double _dashboardRateLimitedUntilMs: internal.dashboardRateLimitedUntilMs
  readonly property double _notificationsRateLimitedUntilMs: internal.notifRateLimitedUntilMs
  // Debug-only: per-source status, so a probe can tell one source recovered
  // while the other is still blocked (only notifications' -i output carries
  // a real X-Ratelimit-Reset; the others fall back to a +60min window).
  readonly property string _dashboardStatus: internal.dashboardStatus
  readonly property string _notifStatus: internal.notifStatus
  readonly property bool busy: dashboardProc.running || notificationsProc.running
  // Debug-only: lets a probe poll for "every process settled", including
  // the two that `busy` above deliberately excludes (ghpath/probe).
  readonly property bool _anyProcRunning: ghPathProc.running || probeProc.running || dashboardProc.running || notificationsProc.running

  readonly property var notifications: internal.notifications
  readonly property int unreadCount: internal.notifications.filter(function (n) {
    return n && n.unread === true
  }).length
  readonly property var reviewRequests: internal.reviewRequests
  readonly property var openPRs: internal.openPRs
  readonly property var myIssues: Model.filterIssues(internal.myIssues, root.issuesFilter)
  readonly property int myIssuesAllCount: internal.myIssues.length
  readonly property var repos: internal.repos.slice(0, root.repoLimit)
  // The source's real GraphQL totalCount/issueCount for each section --
  // 0 until the first successful dashboard fetch lands one, same "not real
  // yet" default the section arrays themselves start with.
  readonly property int openPRsTotal: internal.openPRsTotal
  readonly property int reviewRequestsTotal: internal.reviewRequestsTotal
  readonly property int reposTotal: internal.reposTotal
  readonly property int myIssuesTotal: internal.myIssuesTotal
  readonly property bool hasAttention:
    internal.openPRs.some(function (p) { return p && p.ciState === "failure" })
    || internal.reviewRequests.length > 0

  // Runs both fetches now; a no-op while either is already in flight. While
  // blocked on no-gh, re-resolves ghPath immediately instead of waiting out
  // the 5-minute re-probe.
  function refresh() {
    if (root.status === "no-gh") {
      log("refresh(): no-gh -- re-resolving gh path immediately")
      forceResolveGhPath()
      return
    }
    if (dashboardProc.running || notificationsProc.running) {
      log("refresh() requested but already busy -- ignored")
      return
    }
    log("refresh() -- running both fetches now")
    triggerDashboardFetch()
    triggerNotificationsFetch()
  }

  // Allowlisted to https://github.com/... and spawned as an argument array
  // (no shell) -- url is remote-derived (a notification/PR/repo link).
  function openUrl(url) {
    if (!Model.isSafeGithubUrl(url)) {
      log("openUrl: rejected non-github.com url")
      return
    }
    Quickshell.execDetached(["xdg-open", url])
  }

  // Persists issuesFilter via shell.updateEntryInline, which REPLACES the
  // whole settings entry -- Model.mergedSettings builds current-plus-one-key
  // so every other setting survives the write.
  function setIssuesFilter(mode) {
    var next = validIssuesFilter(mode)
    if (!shell || typeof shell.updateEntryInline !== "function") {
      log("setIssuesFilter: shell.updateEntryInline unavailable -- cannot persist")
      return
    }
    shell.updateEntryInline("halmylyseas.github-status", Model.mergedSettings(root._settingsEntry, "issuesFilter", next))
    log("issuesFilter set to " + next)
  }

  // Settings: shell.json entry for this plugin, manifest defaults as
  // fallback. Live bindings off shell.shellConfig are fine here; a
  // Timer.interval built from one of these must NOT be live (see below).

  readonly property var _shellConfig: shell ? shell.shellConfig : null
  readonly property var _settingsEntry: findEntry(_shellConfig, "halmylyseas.github-status")

  readonly property int dashboardIntervalSec:
    clampInt(settingInt(_settingsEntry, "dashboardIntervalSec", manifestDefault("dashboardIntervalSec", 180)), 60, 3600)
  readonly property int notificationsIntervalSec:
    clampInt(settingInt(_settingsEntry, "notificationsIntervalSec", manifestDefault("notificationsIntervalSec", 60)), 60, 600)
  readonly property int repoLimit:
    clampInt(settingInt(_settingsEntry, "repoLimit", manifestDefault("repoLimit", 10)), 3, 30)
  readonly property string issuesFilter:
    validIssuesFilter(settingStr(_settingsEntry, "issuesFilter", manifestDefault("issuesFilter", "focus")))

  // A bar-layout entry can be a bare string instead of an object -- that
  // form renders fine but cannot carry settings. Delayed so shellConfig has
  // time to move past its transient built-in-defaults state at boot.
  Timer {
    interval: 15000
    running: true
    repeat: false
    onTriggered: {
      if (root.findEntry(root._shellConfig, "halmylyseas.github-status") === null) {
        root.log("no config entry found for this plugin -- settings cannot persist, manifest defaults are in effect")
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
  // Plugin-dir resolution -- never remote/user input, fixed at install time.
  // ============================================================

  readonly property string pluginDir: resolvePluginDir()

  function resolvePluginDir() {
    var s = String(Qt.resolvedUrl("."))
    if (s.indexOf("file://") === 0) s = s.slice("file://".length)
    try { s = decodeURIComponent(s) } catch (e) { /* leave as-is */ }
    if (s.length > 1 && s.charAt(s.length - 1) === "/") s = s.slice(0, -1)
    return s
  }

  // gh path resolution + per-process plumbing. `ghPath` resolves once at
  // startup, or is set directly by a test/probe. Every *TimeoutMs/output-cap
  // property below is plain (not readonly) so a probe can shorten it.

  property string ghPath: ""
  property int ghPathTimeoutMs: 5000
  property int probeTimeoutMs: 30000
  property int dashboardTimeoutMs: 30000
  property int notificationsTimeoutMs: 30000
  // Generic per-process caps (probe/notifications/ghpath); dashboard's own
  // response is one JSON line, so it gets a much larger char budget instead
  // of a line-count budget.
  property int finiteOutputLines: 20000
  property int finiteOutputChars: 262144
  property int dashboardOutputCharsCap: 2097152

  property var _ghPathLines: []
  property var _ghPathErrorLines: []
  property int _ghPathOutputLines: 0
  property int _ghPathOutputChars: 0
  property bool _ghPathOverflowed: false
  property int _ghPathOverflowCount: 0
  property bool _ghPathWatchdogFired: false
  property int _ghPathWatchdogFiredCount: 0
  property int _ghPathFailedStartCount: 0
  property int _ghPathArmedPid: 0
  property int _ghPathGen: 0
  property int _ghPathExitedGen: -1

  property var _probeLines: []
  property var _probeErrorLines: []
  property int _probeOutputLines: 0
  property int _probeOutputChars: 0
  property bool _probeOverflowed: false
  property int _probeOverflowCount: 0
  property bool _probeWatchdogFired: false
  property int _probeWatchdogFiredCount: 0
  property int _probeFailedStartCount: 0
  property int _probeArmedPid: 0
  property int _probeGen: 0
  property int _probeExitedGen: -1

  property var _dashboardLines: []
  property var _dashboardErrorLines: []
  property int _dashboardOutputLines: 0
  property int _dashboardOutputChars: 0
  property bool _dashboardOverflowed: false
  property int _dashboardOverflowCount: 0
  property bool _dashboardWatchdogFired: false
  property int _dashboardWatchdogFiredCount: 0
  property int _dashboardFailedStartCount: 0
  property int _dashboardArmedPid: 0
  property int _dashboardGen: 0
  property int _dashboardExitedGen: -1

  property var _notificationsLines: []
  property var _notificationsErrorLines: []
  property int _notificationsOutputLines: 0
  property int _notificationsOutputChars: 0
  property bool _notificationsOverflowed: false
  property int _notificationsOverflowCount: 0
  property bool _notificationsWatchdogFired: false
  property int _notificationsWatchdogFiredCount: 0
  property int _notificationsFailedStartCount: 0
  property int _notificationsArmedPid: 0
  property int _notificationsGen: 0
  property int _notificationsExitedGen: -1

  function _procForKind(kind) {
    if (kind === "ghPath") return ghPathProc
    if (kind === "probe") return probeProc
    if (kind === "dashboard") return dashboardProc
    return notificationsProc
  }

  function _watchdogTimer(kind) {
    if (kind === "ghPath") return ghPathWatchdog
    if (kind === "probe") return probeWatchdog
    if (kind === "dashboard") return dashWatchdog
    return notifWatchdog
  }

  function _killTimer(kind) {
    if (kind === "ghPath") return ghPathKillTimer
    if (kind === "probe") return probeKillTimer
    if (kind === "dashboard") return dashKillTimer
    return notifKillTimer
  }

  function _timeoutMsFor(kind) {
    if (kind === "ghPath") return root.ghPathTimeoutMs
    if (kind === "probe") return root.probeTimeoutMs
    if (kind === "dashboard") return root.dashboardTimeoutMs
    return root.notificationsTimeoutMs
  }

  function _capCharsFor(kind) {
    return kind === "dashboard" ? root.dashboardOutputCharsCap : root.finiteOutputChars
  }

  function _resetBoundedOutput(kind) {
    root["_" + kind + "Lines"] = []
    root["_" + kind + "ErrorLines"] = []
    root["_" + kind + "OutputLines"] = 0
    root["_" + kind + "OutputChars"] = 0
    root["_" + kind + "Overflowed"] = false
  }

  // Arrays are always replaced (never .push()ed) so bindings notice. A
  // breach caps the total at the limit and SIGTERMs the process.
  function _appendBoundedOutput(kind, line, errorStream) {
    if (root["_" + kind + "Overflowed"]) return
    var outLinesKey = "_" + kind + "OutputLines"
    var outCharsKey = "_" + kind + "OutputChars"
    var charsCap = _capCharsFor(kind)
    var atCap = root[outLinesKey] >= root.finiteOutputLines || root[outCharsKey] >= charsCap
    if (!atCap) {
      var value = String(line || "")
      var remaining = charsCap - root[outCharsKey]
      if (value.length >= remaining) { value = value.slice(0, remaining); atCap = true }
      var linesKey = errorStream ? "_" + kind + "ErrorLines" : "_" + kind + "Lines"
      root[linesKey] = root[linesKey].concat([value])
      root[outLinesKey] = root[outLinesKey] + 1
      root[outCharsKey] = root[outCharsKey] + value.length
      if (root[outLinesKey] >= root.finiteOutputLines) atCap = true
    }
    if (atCap) {
      root["_" + kind + "Overflowed"] = true
      root["_" + kind + "OverflowCount"] = root["_" + kind + "OverflowCount"] + 1
      var proc = _procForKind(kind)
      if (proc.running) proc.signal(15)
    }
  }

  function _armProcess(kind) {
    root["_" + kind + "Gen"] = root["_" + kind + "Gen"] + 1
    _resetBoundedOutput(kind)
    var wd = _watchdogTimer(kind)
    wd.interval = _timeoutMsFor(kind)
    wd.restart()
    _procForKind(kind).running = true
  }

  // Shared by every process's real onExited and its synthetic failed-start
  // path. exitStatus === 1 (killed by signal) folds into a nonzero exit
  // code regardless of exitCode, so a signalled child never reads as success.
  function _finalizeProcess(kind, exitCode, exitStatus, missingBinary) {
    _watchdogTimer(kind).stop()
    _killTimer(kind).stop()
    var effExitCode, rawOut, rawErr
    if (missingBinary) {
      root["_" + kind + "FailedStartCount"] = root["_" + kind + "FailedStartCount"] + 1
      effExitCode = 127; rawOut = ""; rawErr = "gh binary missing (removed?)"
    } else if (root["_" + kind + "WatchdogFired"]) {
      root["_" + kind + "WatchdogFired"] = false
      effExitCode = 124; rawOut = ""; rawErr = "timed out"
    } else if (root["_" + kind + "Overflowed"]) {
      effExitCode = 137; rawOut = ""; rawErr = "output limit exceeded"
    } else {
      rawOut = root["_" + kind + "Lines"].join("\n")
      rawErr = root["_" + kind + "ErrorLines"].join("\n")
      effExitCode = (exitStatus === 1 && exitCode === 0) ? 1 : exitCode
    }
    _resetBoundedOutput(kind)
    _dispatchExit(kind, effExitCode, rawOut, rawErr)
  }

  function _dispatchExit(kind, exitCode, rawOut, rawErr) {
    if (kind === "ghPath") { root.handleGhPathExit(exitCode, rawOut, rawErr); return }
    if (kind === "probe") { root.handleProbeResult(exitCode, rawOut, rawErr); return }
    if (kind === "dashboard") { root.handleDashboardExit(exitCode, rawOut, rawErr); return }
    root.handleNotificationsExit(exitCode, rawOut, rawErr)
  }

  function resolveGhPath() {
    if (root.ghPath) { startProbe(); return }
    forceResolveGhPath()
  }

  function forceResolveGhPath() {
    if (ghPathProc.running) return
    ghPathProc.command = ["bash", "-lc", "command -v gh"]
    _armProcess("ghPath")
  }

  function handleGhPathExit(exitCode, rawOut, rawErr) {
    if (exitCode === 0) {
      var resolved = String(rawOut || "").split("\n")[0].replace(/^\s+|\s+$/g, "")
      if (resolved) {
        root.ghPath = resolved
        log("gh resolved at " + resolved)
        startProbe()
        return
      }
    }
    log("gh not found on PATH: " + (rawErr || "empty result"))
    setProbeStatus("no-gh")
    reProbeTimer.restart()
  }

  Timer {
    id: ghPathWatchdog
    repeat: false
    onTriggered: {
      if (ghPathProc.running) {
        root.log("gh path resolution watchdog: exceeded " + ghPathWatchdog.interval + "ms, killing")
        root._ghPathWatchdogFired = true
        root._ghPathWatchdogFiredCount = root._ghPathWatchdogFiredCount + 1
        ghPathProc.signal(15)
        ghPathKillTimer.restart()
      }
    }
  }

  Timer {
    id: ghPathKillTimer
    interval: 1000
    repeat: false
    onTriggered: {
      if (ghPathProc.running && ghPathProc.processId === root._ghPathArmedPid) ghPathProc.signal(9)
    }
  }

  Process {
    id: ghPathProc
    command: []
    running: false
    onStarted: { root._ghPathArmedPid = processId }
    // A Process whose binary can't be found flips `running` false without
    // ever emitting `exited` -- Qt.callLater defers this check so a normal
    // exit's own synchronous `exited` handler runs first.
    onRunningChanged: {
      if (!running) {
        var gen = root._ghPathGen
        Qt.callLater(function () {
          if (root._ghPathGen === gen && root._ghPathExitedGen !== gen) {
            root._ghPathExitedGen = gen
            root._finalizeProcess("ghPath", 127, 0, true)
          }
        })
      }
    }
    stdout: SplitParser { onRead: function (line) { root._appendBoundedOutput("ghPath", line, false) } }
    stderr: SplitParser { onRead: function (line) { root._appendBoundedOutput("ghPath", line, true) } }
    onExited: function (exitCode, exitStatus) {
      root._ghPathExitedGen = root._ghPathGen
      root._finalizeProcess("ghPath", exitCode, exitStatus, false)
    }
  }

  // Internal state the public API above derives from -- the auth probe,
  // dashboard poller, and notifications poller each own their own
  // status/sync/rate-limit state.

  QtObject {
    id: internal
    property string probeStatus: "loading"
    property string dashboardStatus: "loading"
    property string notifStatus: "loading"

    property double dashboardLastSyncMs: 0
    property double notifLastSyncMs: 0
    property bool dashboardPartial: false

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
    // Paired with the four lists above -- only ever updated together
    // with the section whose total it is (see handleDashboardExit).
    property int reviewRequestsTotal: 0
    property int openPRsTotal: 0
    property int reposTotal: 0
    property int myIssuesTotal: 0

    property string notificationsEtag: ""

    // The authenticated account's own login -- not a secret, GitHub
    // usernames are public. Learned from the probe's stdout, or
    // opportunistically off a dashboard response's viewer.login.
    property string login: ""

    // Gate on the two pollers. False at startup and while the service has
    // no resolved auth signal, or has lost one mid-session. Stays true
    // unless the derived status becomes no-gh/unauthenticated again.
    property bool pollersActive: false

    property string lastLoggedStatus: "loading"
  }

  // ============================================================
  // Status state machine
  // ============================================================

  function log(message) {
    console.log("qml: github-status " + message)
  }

  // Severity ladder, most severe first. worstOf picks whichever input is
  // more severe; an unrecognized string is treated as "loading".
  function worstOf(a, b) {
    var order = ["no-gh", "unauthenticated", "rate-limited", "offline", "loading", "ok"]
    var ai = order.indexOf(a); if (ai < 0) ai = order.indexOf("loading")
    var bi = order.indexOf(b); if (bi < 0) bi = order.indexOf("loading")
    return ai <= bi ? a : b
  }

  // Excludes probeStatus once the pollers are engaged -- the probe's only
  // job is the initial "is gh even usable" gate. Once pollers are active,
  // the real signal is whatever they themselves report.
  function computeStatus() {
    if (!internal.pollersActive) {
      return worstOf(worstOf(internal.probeStatus, internal.dashboardStatus), internal.notifStatus)
    }
    return worstOf(internal.dashboardStatus, internal.notifStatus)
  }

  // Never a stale value left over from a source that has since recovered --
  // if more than one source is rate-limited, show whichever resets soonest.
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

  // Logs every real transition; stops both pollers + arms the re-probe
  // cycle whenever the worst current source is no-gh/unauthenticated.
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
  // rate-limit reset (if applicable) against only that source, then
  // updates that source's own status.
  function handleFetchFailure(source, cls, rawText) {
    var mapped = mapClassifiedStatus(cls)
    if (mapped === "rate-limited") {
      var untilMs = parseRateLimitReset(rawText)
      if (!untilMs) untilMs = Date.now() + 60 * 60 * 1000
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

  // Best-effort extraction of X-Ratelimit-Reset (unix epoch seconds) from
  // whatever text is available. Never throws; 0 means "not parseable".
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

  function briefJson(v) {
    try { return JSON.stringify(v).slice(0, 500) } catch (e) { return String(v).slice(0, 500) }
  }

  // Auth probe: `gh api user --jq .login`, direct child. Run once at
  // startup, and again every 5 minutes while status is no-gh/unauthenticated.

  function startProbe() {
    if (probeProc.running) return
    if (!root.ghPath) { resolveGhPath(); return }
    probeProc.command = [root.ghPath, "api", "user", "--jq", ".login"]
    _armProcess("probe")
  }

  Timer {
    id: probeWatchdog
    repeat: false
    onTriggered: {
      if (probeProc.running) {
        root.log("auth probe watchdog: exceeded " + probeWatchdog.interval + "ms, killing")
        root._probeWatchdogFired = true
        root._probeWatchdogFiredCount = root._probeWatchdogFiredCount + 1
        probeProc.signal(15)
        probeKillTimer.restart()
      }
    }
  }

  Timer {
    id: probeKillTimer
    interval: 1000
    repeat: false
    onTriggered: {
      if (probeProc.running && probeProc.processId === root._probeArmedPid) probeProc.signal(9)
    }
  }

  Process {
    id: probeProc
    command: []
    running: false
    onStarted: { root._probeArmedPid = processId }
    onRunningChanged: {
      if (!running) {
        var gen = root._probeGen
        Qt.callLater(function () {
          if (root._probeGen === gen && root._probeExitedGen !== gen) {
            root._probeExitedGen = gen
            root._finalizeProcess("probe", 127, 0, true)
          }
        })
      }
    }
    stdout: SplitParser { onRead: function (line) { root._appendBoundedOutput("probe", line, false) } }
    stderr: SplitParser { onRead: function (line) { root._appendBoundedOutput("probe", line, true) } }
    onExited: function (exitCode, exitStatus) {
      root._probeExitedGen = root._probeGen
      root._finalizeProcess("probe", exitCode, exitStatus, false)
    }
  }

  // exitCode/rawOut/rawErr already reflect a real exit, a watchdog timeout
  // (124), an output overflow (137), or a missing binary (127) --
  // classifyFailure's own exitCode===127 check turns that into "no-gh".
  function handleProbeResult(exitCode, rawOut, rawErr) {
    if (exitCode === 0) {
      var login = String(rawOut || "").replace(/^\s+|\s+$/g, "")
      if (login) internal.login = login
      log("probe: authenticated" + (login ? " as " + login : ""))
      onFetchSuccess("probe")
      // Mid-session recovery: a poller that previously recorded
      // no-gh/unauthenticated must not keep blocking forever once a fresh
      // probe proves gh is back and authenticated.
      if (internal.dashboardStatus === "no-gh" || internal.dashboardStatus === "unauthenticated") {
        internal.dashboardStatus = "loading"
      }
      if (internal.notifStatus === "no-gh" || internal.notifStatus === "unauthenticated") {
        internal.notifStatus = "loading"
      }
      internal.pollersActive = true
      triggerDashboardFetch()
      triggerNotificationsFetch()
      return
    }
    var cls = Model.classifyFailure(rawErr, exitCode)
    if (cls === "no-gh" || cls === "unauthenticated") {
      setProbeStatus(cls)
      reProbeTimer.restart()
      return
    }
    handleFetchFailure("probe", cls, rawErr)
    internal.pollersActive = true
    maybeRearmReProbeForLogin()
    ensureReProbeWhileBlocked()
  }

  // As long as the derived status is no-gh/unauthenticated, the pollers
  // refuse to fetch -- guarantee a re-probe is always scheduled while
  // blocked (restart() is harmless when already armed).
  function ensureReProbeWhileBlocked() {
    if (status === "no-gh" || status === "unauthenticated") reProbeTimer.restart()
  }

  // Keeps the slow re-probe cadence alive purely to retry learning the
  // login (e.g. after a probe timeout), without re-blocking the pollers.
  function maybeRearmReProbeForLogin() {
    if (!internal.login) reProbeTimer.restart()
  }

  // Fixed in production (never reassigned after startup) -- live-bound only
  // so a probe can shorten it before first use, same as the *TimeoutMs above.
  property int reProbeMs: 300000

  Timer {
    id: reProbeTimer
    interval: root.reProbeMs
    repeat: false
    onTriggered: root.reProbeNow()
  }

  // no-gh re-resolves ghPath (the binary may have appeared/moved);
  // unauthenticated just retries the probe against the same ghPath.
  function reProbeNow() {
    if (root.status === "no-gh") { forceResolveGhPath(); return }
    startProbe()
  }

  // Dashboard fetch: one combined GraphQL query, direct `gh` child. Never
  // blanks the UI on failure -- a section is only reassigned when
  // Model.mapDashboard says it actually parsed.

  Timer {
    id: dashboardTimer
    // Placeholder only -- reassigned imperatively at arm time below (a
    // live-bound interval would discard an in-progress countdown on any
    // settings edit).
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
    if (!root.ghPath) return
    dashboardProc.command = [root.ghPath, "api", "graphql", "-f", "query=" + Model.DASHBOARD_QUERY]
    _armProcess("dashboard")
  }

  Timer {
    id: dashWatchdog
    repeat: false
    onTriggered: {
      if (dashboardProc.running) {
        root.log("dashboard fetch watchdog: exceeded " + dashWatchdog.interval + "ms, killing")
        root._dashboardWatchdogFired = true
        root._dashboardWatchdogFiredCount = root._dashboardWatchdogFiredCount + 1
        dashboardProc.signal(15)
        dashKillTimer.restart()
      }
    }
  }

  Timer {
    id: dashKillTimer
    interval: 1000
    repeat: false
    onTriggered: {
      if (dashboardProc.running && dashboardProc.processId === root._dashboardArmedPid) dashboardProc.signal(9)
    }
  }

  Process {
    id: dashboardProc
    command: []
    running: false
    onStarted: { root._dashboardArmedPid = processId }
    onRunningChanged: {
      if (!running) {
        var gen = root._dashboardGen
        Qt.callLater(function () {
          if (root._dashboardGen === gen && root._dashboardExitedGen !== gen) {
            root._dashboardExitedGen = gen
            root._finalizeProcess("dashboard", 127, 0, true)
          }
        })
      }
    }
    stdout: SplitParser { onRead: function (line) { root._appendBoundedOutput("dashboard", line, false) } }
    stderr: SplitParser { onRead: function (line) { root._appendBoundedOutput("dashboard", line, true) } }
    onExited: function (exitCode, exitStatus) {
      root._dashboardExitedGen = root._dashboardGen
      root._finalizeProcess("dashboard", exitCode, exitStatus, false)
    }
  }

  function _captureLoginFromDashboard(login) {
    if (!login || internal.login) return
    internal.login = login
    log("login learned opportunistically from dashboard response: " + internal.login)
    if (internal.notifications.length > 0) {
      internal.notifications = Model.remapNotificationsExternal(internal.notifications, internal.login)
    }
  }

  // Counts parsed vs. null sections. All parsed -> ok. Some parsed (plus
  // GraphQL `errors`) -> keep the parsed sections, advance sync time, flag
  // dashboardPartial, log the errors. None parsed -> failure as before.
  function handleDashboardExit(exitCode, rawOut, rawErr) {
    if (exitCode === 0) {
      var parsed = null
      try { parsed = JSON.parse(rawOut) } catch (e) { parsed = null }
      var mapped = parsed ? Model.mapDashboard(parsed) : { openPRs: null, reviewRequests: null, repos: null, myIssues: null, login: "" }
      var sections = [mapped.openPRs, mapped.reviewRequests, mapped.repos, mapped.myIssues]
      var parsedCount = sections.filter(function (s) { return s !== null }).length
      if (parsedCount === 0) {
        log("dashboard fetch: no usable data in JSON envelope -- keeping last-good data")
        handleFetchFailure("dashboard", "error",
          rawErr || (parsed && parsed.errors ? briefJson(parsed.errors) : "unparseable/empty JSON"))
        return
      }
      if (mapped.openPRs !== null) { internal.openPRs = mapped.openPRs; internal.openPRsTotal = mapped.openPRsTotal }
      if (mapped.reviewRequests !== null) { internal.reviewRequests = mapped.reviewRequests; internal.reviewRequestsTotal = mapped.reviewRequestsTotal }
      if (mapped.repos !== null) { internal.repos = mapped.repos; internal.reposTotal = mapped.reposTotal }
      if (mapped.myIssues !== null) { internal.myIssues = mapped.myIssues; internal.myIssuesTotal = mapped.myIssuesTotal }
      _captureLoginFromDashboard(mapped.login)
      internal.dashboardPartial = parsedCount < sections.length
      if (internal.dashboardPartial) {
        log("dashboard fetch: partial GraphQL errors -- kept the section(s) that parsed: "
          + briefJson(parsed && parsed.errors))
      }
      onFetchSuccess("dashboard")
      return
    }
    var cls = Model.classifyFailure(rawErr, exitCode)
    handleFetchFailure("dashboard", cls, rawErr)
  }

  // Notifications fetch: conditional GET, ETag round-tripped, direct `gh`
  // child. A genuine 304 (no-change) is success, not failure.

  Timer {
    id: notificationsTimer
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
    if (!root.ghPath) return
    var etag = Model.sanitizeEtag(internal.notificationsEtag)
    var cmd = [root.ghPath, "api", "-i", "notifications"]
    if (etag) cmd = cmd.concat(["-H", "If-None-Match: " + etag])
    notificationsProc.command = cmd
    _armProcess("notifications")
  }

  Timer {
    id: notifWatchdog
    repeat: false
    onTriggered: {
      if (notificationsProc.running) {
        root.log("notifications fetch watchdog: exceeded " + notifWatchdog.interval + "ms, killing")
        root._notificationsWatchdogFired = true
        root._notificationsWatchdogFiredCount = root._notificationsWatchdogFiredCount + 1
        notificationsProc.signal(15)
        notifKillTimer.restart()
      }
    }
  }

  Timer {
    id: notifKillTimer
    interval: 1000
    repeat: false
    onTriggered: {
      if (notificationsProc.running && notificationsProc.processId === root._notificationsArmedPid) notificationsProc.signal(9)
    }
  }

  Process {
    id: notificationsProc
    command: []
    running: false
    onStarted: { root._notificationsArmedPid = processId }
    onRunningChanged: {
      if (!running) {
        var gen = root._notificationsGen
        Qt.callLater(function () {
          if (root._notificationsGen === gen && root._notificationsExitedGen !== gen) {
            root._notificationsExitedGen = gen
            root._finalizeProcess("notifications", 127, 0, true)
          }
        })
      }
    }
    stdout: SplitParser { onRead: function (line) { root._appendBoundedOutput("notifications", line, false) } }
    stderr: SplitParser { onRead: function (line) { root._appendBoundedOutput("notifications", line, true) } }
    onExited: function (exitCode, exitStatus) {
      root._notificationsExitedGen = root._notificationsGen
      root._finalizeProcess("notifications", exitCode, exitStatus, false)
    }
  }

  // An exit-0 response is only trusted with a 200 status and an array
  // body -- anything else is a failure that keeps the last-good data.
  function handleNotificationsExit(exitCode, rawOut, rawErr) {
    if (exitCode === 0) {
      var parsed = Model.parseHeadersAndBody(rawOut)
      if (parsed.etag) internal.notificationsEtag = Model.sanitizeEtag(parsed.etag)
      if (Model.isNotificationsBodyValid(parsed)) {
        internal.notifications = Model.mapNotifications(parsed.body, internal.login)
        onFetchSuccess("notifications")
      } else {
        log("notifications: exit 0 but not a valid 200+array body (status=" + parsed.status + ") -- keeping last-good data")
        handleFetchFailure("notifications", "error", "malformed 200 response or unexpected status " + parsed.status)
      }
      return
    }
    var cls = Model.classifyFailure(rawErr, exitCode)
    if (cls === "http-304") {
      var parsed304 = Model.parseHeadersAndBody(rawOut)
      if (parsed304.etag) internal.notificationsEtag = Model.sanitizeEtag(parsed304.etag)
      log("notifications: no change (304)")
      onFetchSuccess("notifications")
      return
    }
    handleFetchFailure("notifications", cls, rawOut + "\n" + rawErr)
  }

  // ============================================================
  Timer {
    id: startupTimer
    interval: 0
    running: true
    repeat: false
    onTriggered: root.resolveGhPath()
  }

  Component.onCompleted: {
    log("service ready (pluginDir=" + root.pluginDir
      + " dashboardIntervalSec=" + root.dashboardIntervalSec
      + " notificationsIntervalSec=" + root.notificationsIntervalSec
      + " repoLimit=" + root.repoLimit
      + " issuesFilter=" + root.issuesFilter + ")")
  }
}
