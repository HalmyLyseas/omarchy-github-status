import QtQuick
import Quickshell
import Quickshell.Io

// Loads the real Service.qml, waits for its process queue to settle, drives
// one env-selected scenario, and prints a single "PROBE_RESULT {...}" line.
// Recovery scenarios drive their own helper Processes, not the bash harness.
ShellRoot {
  id: probeRoot

  property var service: null
  property bool done: false
  property int elapsedMs: 0

  property string pluginDir: Quickshell.env("GHS_PLUGIN_DIR")
  property string ghPathOverride: Quickshell.env("GHS_GHPATH")
  property string scenario: Quickshell.env("GHS_SCENARIO") || ""
  property string modeFile: Quickshell.env("GHS_MODE_FILE")
  property string newMode: Quickshell.env("GHS_NEW_MODE")
  property string linkPath: Quickshell.env("GHS_LINK_PATH")
  property string mockPath: Quickshell.env("GHS_MOCK_PATH")

  // Legacy-shaped stub shell: a live full shellConfig with a real own
  // entry, pinning every scenario onto the pre-scoped-facade settings path
  // so `dashboardIntervalSec`/`settingsSource` reflect it, not defaults.
  QtObject {
    id: shellStub
    property var shellConfig: ({
      version: 1,
      bar: { layout: { right: [
        { id: "halmylyseas.github-status", dashboardIntervalSec: 300 }
      ] } },
      plugins: []
    })
    function updateEntryInline(id, settings) { return false }
  }

  Loader {
    id: loader
    source: "file://" + probeRoot.pluginDir + "/Service.qml"
    active: true
    onLoaded: {
      probeRoot.service = item
      item.shell = shellStub
      // Short boot grace so a legacy-entry loss after settle logs promptly.
      item.settingsDiagnosticGraceMs = 300
      if (probeRoot.ghPathOverride) item.ghPath = probeRoot.ghPathOverride
      item.ghPathTimeoutMs = 1500
      item.ghVersionTimeoutMs = 1500
      item.probeTimeoutMs = 1500
      item.dashboardTimeoutMs = 1500
      item.notificationsTimeoutMs = 1500
      item.reProbeMs = probeRoot.scenario === "unauth-recover-refresh" ? 600000 : 800
      if (probeRoot.scenario === "flood") {
        item.dashboardOutputCharsCap = 2000
        item.finiteOutputChars = 2000
      }
      settleTimer.start()
    }
  }

  // Gives Service.qml's own deferred startup timer a moment to fire before
  // this probe starts polling for "settled" -- otherwise this can race the
  // same tick and see _anyProcRunning === false before anything even started.
  Timer {
    id: settleTimer
    interval: 150
    repeat: false
    onTriggered: probeRoot._drainThen(probeRoot.afterSettled)
  }

  property var _afterBusy: null

  Timer {
    id: busyDrainTimer
    interval: 50
    repeat: true
    onTriggered: {
      probeRoot.elapsedMs += interval
      if (!probeRoot.service._anyProcRunning) {
        busyDrainTimer.stop()
        var cb = probeRoot._afterBusy
        probeRoot._afterBusy = null
        if (cb) cb()
      } else if (probeRoot.elapsedMs > 15000) {
        busyDrainTimer.stop()
        probeRoot.finish("process queue did not settle within 15s")
      }
    }
  }

  function _drainThen(cb) {
    elapsedMs = 0
    _afterBusy = cb
    busyDrainTimer.start()
  }

  // Polls a predicate every 50ms until it's true or `maxMs` elapses, then
  // calls `cb` either way -- used for waiting out a status transition that
  // isn't tied to a process actually running (e.g. the shortened re-probe).
  function _waitUntil(maxMs, predicate, cb) {
    elapsedMs = 0
    waitUntilTimer.predicate = predicate
    waitUntilTimer.maxMs = maxMs
    waitUntilTimer.cb = cb
    waitUntilTimer.start()
  }

  Timer {
    id: waitUntilTimer
    interval: 50
    repeat: true
    property var predicate: null
    property var cb: null
    property int maxMs: 5000
    onTriggered: {
      probeRoot.elapsedMs += interval
      if (predicate()) {
        stop()
        var f = cb
        cb = null
        if (f) f()
      } else if (probeRoot.elapsedMs > maxMs) {
        stop()
        var f2 = cb
        cb = null
        if (f2) f2()
      }
    }
  }

  function afterSettled() {
    if (scenario === "etag-roundtrip") {
      service.refresh()
      _drainThen(finishNow)
    } else if (scenario === "unauth-recover" || scenario === "unauth-fresh-recover") {
      writeModeFile("ok", function () {
        _waitUntil(4000, function () { return service.status === "ok" }, finishNow)
      })
    } else if (scenario === "unauth-recover-refresh") {
      // reProbeMs is left long here -- recovery must come from refresh()
      // itself calling startProbe(), not from the re-probe timer firing.
      writeModeFile("ok", function () {
        service.refresh()
        _waitUntil(4000, function () { return service.status === "ok" }, finishNow)
      })
    } else if (scenario === "no-gh-recover") {
      // The mock's directory joins PATH once this process creates the
      // symlink -- bash's own `type -P gh` (real, not mocked) then
      // finds it on the next shortened reProbeMs cycle.
      createLink(function () {
        _waitUntil(4000, function () { return service.status === "ok" }, finishNow)
      })
    } else if (scenario === "removed-recover") {
      removeLink(function () {
        service.refresh()
        _drainThen(function () {
          createLink(function () {
            _waitUntil(4000, function () { return service.status === "ok" }, finishNow)
          })
        })
      })
    } else if (scenario === "legacy-entry-lost") {
      // A legacy host replaces its whole shellConfig; losing the own entry
      // after boot must surface as a diagnostic, not silence.
      _waitUntil(2000, function () { return service._legacyDiagnosticsArmed === true }, function () {
        shellStub.shellConfig = { version: 1, bar: { layout: { left: [], center: [], right: [] } }, plugins: [] }
        _waitUntil(2000, function () { return service.settingsDiagnostic === "missing own entry" }, finishNow)
      })
    } else if (scenario === "api-error") {
      // A poller that was ok flips to api-error on its own next cycle --
      // the mode file only takes effect on the fetch refresh() triggers.
      writeModeFile("api-error", function () {
        service.refresh()
        _waitUntil(4000, function () { return service.status === "api-error" }, finishNow)
      })
    } else if (scenario === "api-error-recover") {
      writeModeFile("api-error", function () {
        service.refresh()
        _waitUntil(4000, function () { return service.status === "api-error" }, function () {
          writeModeFile("ok", function () {
            service.refresh()
            _waitUntil(4000, function () { return service.status === "ok" }, finishNow)
          })
        })
      })
    } else if (scenario === "login-switch") {
      // The mode file only rewrites the dashboard branch's viewer.login --
      // refresh() picks it up on the next poll, same trigger as api-error.
      writeModeFile("login-switch", function () {
        service.refresh()
        _waitUntil(4000, function () { return service._login === "SomeoneElse" }, finishNow)
      })
    } else if (scenario === "rate-limited-resume") {
      // Only notifications' -i output carries a real X-Ratelimit-Reset
      // header -- dashboard/probe failures always fall back to a fixed
      // +60min window, so this scenario targets notifications specifically.
      _waitUntil(6000, function () {
        return service._notificationsRateLimitedUntilMs > 0 && Date.now() > service._notificationsRateLimitedUntilMs
      }, function () {
        service.refresh()
        _drainThen(finishNow)
      })
    } else {
      finishNow()
    }
  }

  Process {
    id: modeFileProc
    running: false
    property var onDone: null
    onExited: function () {
      var cb = onDone
      onDone = null
      if (cb) cb()
    }
  }

  function writeModeFile(mode, cb) {
    modeFileProc.onDone = cb
    modeFileProc.command = ["bash", "-c", 'printf %s "$1" > "$2"', "_", mode, modeFile]
    modeFileProc.running = true
  }

  function removeLink(cb) {
    modeFileProc.onDone = cb
    modeFileProc.command = ["rm", "-f", linkPath]
    modeFileProc.running = true
  }

  function createLink(cb) {
    modeFileProc.onDone = cb
    modeFileProc.command = ["ln", "-sfn", mockPath, linkPath]
    modeFileProc.running = true
  }

  function debugProp(name) {
    return (service && (name in service)) ? service[name] : null
  }

  function finishNow() { finish("") }

  function finish(note) {
    if (done) return
    done = true
    var summary = {
      status: service.status,
      hasAttention: service.hasAttention,
      unreadCount: service.unreadCount,
      openPRsLength: (service.openPRs || []).length,
      reviewRequestsLength: (service.reviewRequests || []).length,
      myIssuesLength: (service.myIssues || []).length,
      reposLength: (service.repos || []).length,
      // The fixture's totalCount/issueCount values are set above every
      // section's own cap/window, so the "ok" scenario's assertions in
      // test/probe/run exercise the real "N of T" gap, not a coincidence.
      openPRsTotal: service.openPRsTotal,
      reviewRequestsTotal: service.reviewRequestsTotal,
      myIssuesTotal: service.myIssuesTotal,
      reposTotal: service.reposTotal,
      rateLimitedUntil: service.rateLimitedUntil,
      apiErrorDetail: service.apiErrorDetail,
      statusSeverity: service.statusSeverity,
      dashboardPartial: service.dashboardPartial,
      ghPath: service.ghPath,
      ghVersion: service.ghVersion,
      dashboardIntervalSec: service.dashboardIntervalSec,
      settingsSource: service.settingsSource,
      settingsDiagnostic: service.settingsDiagnostic,
      ghVersionSupported: service.ghVersionSupported,
      dashboardStatus: debugProp("_dashboardStatus"),
      notifStatus: debugProp("_notifStatus"),
      _reProbeArmed: debugProp("_reProbeArmed"),
      login: debugProp("_login"),
      _dashboardTimerIntervalMs: debugProp("_dashboardTimerIntervalMs"),
      _notificationsTimerIntervalMs: debugProp("_notificationsTimerIntervalMs"),
      notificationsExternalCount: debugProp("_notificationsExternalCount"),
      note: note,
      _ghPathWatchdogFiredCount: debugProp("_ghPathWatchdogFiredCount"),
      _probeWatchdogFiredCount: debugProp("_probeWatchdogFiredCount"),
      _dashboardWatchdogFiredCount: debugProp("_dashboardWatchdogFiredCount"),
      _notificationsWatchdogFiredCount: debugProp("_notificationsWatchdogFiredCount"),
      _ghPathOverflowCount: debugProp("_ghPathOverflowCount"),
      _dashboardOverflowCount: debugProp("_dashboardOverflowCount"),
      _notificationsOverflowCount: debugProp("_notificationsOverflowCount"),
      _ghPathFailedStartCount: debugProp("_ghPathFailedStartCount"),
      _probeFailedStartCount: debugProp("_probeFailedStartCount"),
      _dashboardFailedStartCount: debugProp("_dashboardFailedStartCount"),
      _notificationsFailedStartCount: debugProp("_notificationsFailedStartCount"),
      _dashboardOutputChars: debugProp("_dashboardOutputChars")
    }
    console.log("PROBE_RESULT " + JSON.stringify(summary))
    Qt.quit()
  }

  // Whole-probe-run backstop.
  Timer {
    interval: 20000
    running: true
    repeat: false
    onTriggered: probeRoot.finish("probe harness overall timeout (20s)")
  }
}
