import QtQuick
import Quickshell
import Quickshell.Io

// Instantiates the REAL installed PluginShellApi facade plus the REAL
// Service.qml/BarWidget.qml, driving the settings state machine against an
// isolated temp HOME's own shell.json. Prints one "PROBE_RESULT {...}" line.
ShellRoot {
  id: root

  property string pluginDir: Quickshell.env("GHS_PLUGIN_DIR")
  property string ghPathOverride: Quickshell.env("GHS_GHPATH")
  property string configFilePath: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
  readonly property string pluginId: "halmylyseas.github-status"

  property var checks: []
  property bool done: false
  property int elapsedMs: 0

  property var service: null
  property var barWidget: null
  property var shellApi: null
  property var updateSettingsCalls: []
  property int _settingsEntryChangeCount: 0
  property var currentEntry: ({
    id: pluginId, dashboardIntervalSec: 300, notificationsIntervalSec: 120,
    repoLimit: 5, issuesFilter: "all", sibling: "kept"
  })

  function check(name, pass) { root.checks = root.checks.concat([{ name: name, pass: !!pass }]) }
  function panel() { return root.barWidget ? root.barWidget._debugPanelItem : null }

  // Every property/method BarIconButton/KeyboardPanel read off `bar` --
  // matches test/probe/ui-probe.qml's own stub surface.
  QtObject {
    id: stubBar
    property color foreground: "#e6e6e6"
    property color urgent: "#ff5555"
    property color barForeground: "#e6e6e6"
    property string fontFamily: "monospace"
    property string position: "top"
    property bool vertical: false
    property int barSize: 26
    property bool foregroundAnimationEnabled: true
    property var shell: root.shellApi
    property var activePopout: null
    function showTooltip(target, text) {}
    function hideTooltip(target) {}
    function requestPopout(owner) { stubBar.activePopout = owner }
    function releasePopout(owner) { if (stubBar.activePopout === owner) stubBar.activePopout = null }
    function moduleWidgets(name) { return root.barWidget ? [root.barWidget] : [] }
    function registerClickTarget(target) {}
    function unregisterClickTarget(target) {}
  }

  FileView { id: configWriter; path: root.configFilePath; preload: false; atomicWrites: true; blockWrites: true }
  Process { id: removeConfigProc; command: ["/usr/bin/rm", "-f", root.configFilePath] }

  // Blocking re-read of the mock's own invocation log, same "set path
  // twice" pattern Service.qml uses for a fresh read -- counts fetch calls
  // around a settings write to prove no spurious poll fired.
  FileView { id: mockLogFile; preload: false; blockLoading: true; printErrors: false }
  function mockLogFetchCount() {
    mockLogFile.path = ""
    mockLogFile.path = Quickshell.env("GH_MOCK_LOG") || ""
    var text = mockLogFile.text() || ""
    var matches = text.match(/ARGV: api (graphql|-i notifications)/g)
    return matches ? matches.length : 0
  }

  function writeEntry(entry) {
    var doc = { version: 1, bar: { layout: { left: [], center: [], right: entry ? [entry] : [] } }, plugins: [] }
    configWriter.setText(JSON.stringify(doc))
  }

  function writeRaw(text) { configWriter.setText(text) }

  // Mirrors the host's own updateEntryInline whole-entry replace: {id} plus
  // every non-id key handed to it (shell.qml's updateEntryInline, ~line
  // 1078). Persists into the temp shell.json the same way the host would.
  function initApi() {
    var component = Qt.createComponent("/usr/share/omarchy/shell/services/PluginShellApi.qml")
    var item = component.createObject(root, { pluginId: root.pluginId })
    root.shellApi = item
    item.barConfig = { layout: { left: [], center: [], right: [root.currentEntry] } }
    item._serviceLookup = function (id) { return id === root.pluginId ? root.service : null }
    item._updateSettings = function (id, settings) {
      if (id !== root.pluginId) return false
      var next = { id: id }
      for (var key in settings) if (key !== "id") next[key] = settings[key]
      // The host skips a no-op write -- mirror that so it neither persists
      // nor counts as a call.
      if (JSON.stringify(next) === JSON.stringify(root.currentEntry)) return false
      root.currentEntry = next
      root.updateSettingsCalls = root.updateSettingsCalls.concat([next])
      root.writeEntry(next)
      return true
    }
    root.writeEntry(root.currentEntry)
    root.makeService()
    barLoader.active = true
  }

  function makeService() {
    var component = Qt.createComponent("file://" + root.pluginDir + "/Service.qml")
    var s = component.createObject(root)
    if (root.ghPathOverride) s.ghPath = root.ghPathOverride
    s.ghPathTimeoutMs = 1500
    s.ghVersionTimeoutMs = 1500
    s.probeTimeoutMs = 1500
    s.dashboardTimeoutMs = 1500
    s.notificationsTimeoutMs = 1500
    s.reProbeMs = 800
    s.shell = root.shellApi
    s.settingsEntryChanged.connect(function () { root._settingsEntryChangeCount++ })
    root.service = s
    return s
  }

  Loader {
    id: barLoader
    active: false
    source: "file://" + root.pluginDir + "/BarWidget.qml"
    onLoaded: {
      root.barWidget = item
      item.bar = stubBar
      item.settings = ({})
      settleTimer.start()
    }
  }

  property var _afterBusy: null
  Timer {
    id: busyDrainTimer
    interval: 100
    repeat: true
    onTriggered: {
      root.elapsedMs += interval
      if (!root.service || !root.service._anyProcRunning) {
        busyDrainTimer.stop()
        var cb = root._afterBusy
        root._afterBusy = null
        if (cb) cb()
      } else if (root.elapsedMs > 20000) {
        busyDrainTimer.stop()
        root.finish("process queue did not settle within 20s")
      }
    }
  }
  function _drainThen(cb) { root.elapsedMs = 0; root._afterBusy = cb; busyDrainTimer.start() }

  // Generic poll-until helper, same shape as test/probe/ui-probe.qml's own.
  function _waitUntil(predicate, timeoutMs, cb) {
    var waited = 0
    var timer = Qt.createQmlObject('import QtQuick; Timer { interval: 50; repeat: true }', root)
    timer.triggered.connect(function () {
      waited += 50
      if (predicate()) { timer.stop(); timer.destroy(); cb(false) }
      else if (waited > timeoutMs) { timer.stop(); timer.destroy(); cb(true) }
    })
    timer.start()
  }

  Timer { id: settleTimer; interval: 200; repeat: false; onTriggered: root._drainThen(root.beginExercise) }

  Component.onCompleted: root.initApi()

  function beginExercise() {
    // Marks where startup ends and the exercise begins -- the runner counts
    // "settings applied" lines logged before this, which must be exactly 1.
    console.log("PROBE_PHASE startup-done")
    check("scoped host", root.service.scopedHost === true)
    check("initial non-default values",
      root.service.dashboardIntervalSec === 300 && root.service.notificationsIntervalSec === 120
      && root.service.repoLimit === 5 && root.service.issuesFilter === "all")
    check("no write at boot", root.updateSettingsCalls.length === 0)

    var p = root.panel()
    if (!p) { check("real panel loaded", false); finish("no panel instance"); return }

    p.setIssuesFilter("focus")
    var toggled = root.currentEntry
    check("toggle merges siblings",
      toggled.issuesFilter === "focus" && toggled.dashboardIntervalSec === 300
      && toggled.notificationsIntervalSec === 120 && toggled.repoLimit === 5 && toggled.sibling === "kept")

    root._waitUntil(function () { return root.service.issuesFilter === "focus" }, 4000, function (timedOut) {
      check("service follows persisted write",
        !timedOut && root.service.issuesFilter === "focus" && root.service.dashboardIntervalSec === 300)
      check("panel follows service", p.issuesFilter === "focus")
      root.externalEdit(p)
    })
  }

  function externalEdit(p) {
    root.writeEntry({
      id: root.pluginId, dashboardIntervalSec: 300, notificationsIntervalSec: 120,
      repoLimit: 7, issuesFilter: "focus", sibling: "kept"
    })
    root._waitUntil(function () { return root.service.repoLimit === 7 }, 4000, function (timedOut) {
      check("external edit propagates", !timedOut && root.service.repoLimit === 7)
      // The facade snapshot is a copy refreshed only by the host's own
      // syncPluginApis(), never by an inline write -- it must still read
      // the very first seeded value even after two real-entry updates.
      check("facade snapshot stays stale", root.shellApi.barConfig.layout.right[0].repoLimit === 5)
      root.unrelatedWrite(p)
    })
  }

  // Writes a sibling entry while ours stays byte-identical, then a second
  // write that does change ours -- the combined count must advance by
  // exactly one, proving the unrelated reload alone caused no change.
  function unrelatedWrite(p) {
    var ownEntry = {
      id: root.pluginId, dashboardIntervalSec: 300, notificationsIntervalSec: 120,
      repoLimit: 7, issuesFilter: "focus", sibling: "kept"
    }
    var before = root._settingsEntryChangeCount
    var doc = {
      version: 1,
      bar: { layout: { left: [{ id: "acme.other", foo: 1 }], center: [], right: [ownEntry] } },
      plugins: []
    }
    configWriter.setText(JSON.stringify(doc))
    // Settle so the two writes cannot coalesce into one reload; a wrongly
    // firing unrelated reload then shows up as a second increment.
    root._waitUntil(function () { return false }, 700, function () {
      var afterUnrelated = root._settingsEntryChangeCount
      root.writeEntry({
        id: root.pluginId, dashboardIntervalSec: 300, notificationsIntervalSec: 120,
        repoLimit: 8, issuesFilter: "focus", sibling: "kept"
      })
      root._waitUntil(function () { return root.service.repoLimit === 8 }, 4000, function (timedOut) {
        check("unrelated config write leaves settings untouched",
          !timedOut && afterUnrelated === before && root._settingsEntryChangeCount === before + 1)
        root.freshWriteMerge(p)
      })
    })
  }

  // A synchronous blocking write, then the setter call in the very same JS
  // turn -- before the watcher could ever reload -- proves the write reads
  // the file as it is now rather than the last watched snapshot.
  function freshWriteMerge(p) {
    var callsBefore = root.updateSettingsCalls.length
    configWriter.setText(JSON.stringify({
      version: 1,
      bar: { layout: { left: [], center: [], right: [{
        id: root.pluginId, dashboardIntervalSec: 300, notificationsIntervalSec: 120,
        repoLimit: 9, issuesFilter: "focus", sibling: "kept"
      }] }, plugins: [] }
    }))
    var result = root.service.setIssuesFilter("all")
    var recorded = root.updateSettingsCalls[root.updateSettingsCalls.length - 1]
    check("write merges from fresh file",
      result === true && root.updateSettingsCalls.length === callsBefore + 1
      && !!recorded && recorded.repoLimit === 9 && recorded.issuesFilter === "all")
    root._waitUntil(function () {
      return root.service.repoLimit === 9 && root.service.issuesFilter === "all"
    }, 4000, function (timedOut) {
      root.intervalChangeRearms(p)
    })
  }

  // A settings write that changes dashboardIntervalSec must re-arm the
  // running timer's countdown at the new length immediately -- no fetch,
  // and both timers stay running throughout.
  function intervalChangeRearms(p) {
    var runningBefore = root.service._dashboardTimerRunning === true && root.service._notificationsTimerRunning === true
    var fetchesBefore = root.mockLogFetchCount()
    root.writeEntry({
      id: root.pluginId, dashboardIntervalSec: 600, notificationsIntervalSec: 120,
      repoLimit: 9, issuesFilter: "all", sibling: "kept"
    })
    root._waitUntil(function () {
      return root.service._dashboardTimerIntervalMs === 600000 && root.service._notificationsTimerIntervalMs === 120000
    }, 4000, function (timedOut) {
      // Give a spurious fetch a full second to show up before checking --
      // a re-armed countdown must not itself trigger one.
      root._waitUntil(function () { return false }, 1000, function () {
        var fetchesAfter = root.mockLogFetchCount()
        check("interval change re-arms the poller",
          !timedOut && runningBefore
          && root.service._dashboardTimerIntervalMs === 600000
          && root.service._notificationsTimerIntervalMs === 120000
          && root.service._dashboardTimerRunning === true
          && root.service._notificationsTimerRunning === true
          && fetchesAfter === fetchesBefore)
        root.invalidFile(p)
      })
    })
  }

  function invalidFile(p) {
    root.writeRaw("not valid json")
    root._waitUntil(function () { return root.service.settingsDiagnostic !== "" }, 4000, function (timedOut) {
      check("invalid file falls back to defaults with diagnostic",
        !timedOut && root.service.dashboardIntervalSec === 180 && root.service.notificationsIntervalSec === 60
        && root.service.repoLimit === 10 && root.service.issuesFilter === "focus"
        && root.service.settingsDiagnostic !== "")
      var before = root.updateSettingsCalls.length
      var result = root.service.setIssuesFilter("all")
      check("write refused while invalid", result === false && root.updateSettingsCalls.length === before)
      root.deleteFile(p)
    })
  }

  function deleteFile(p) {
    removeConfigProc.running = true
    root._waitUntil(function () { return root.service.settingsDiagnostic === "config load failed" }, 4000, function (timedOut) {
      check("deleted file falls back",
        !timedOut && root.service.settingsDiagnostic === "config load failed" && root.service.dashboardIntervalSec === 180)
      root.recreateFile(p)
    })
  }

  function recreateFile(p) {
    root.writeEntry({
      id: root.pluginId, dashboardIntervalSec: 240, notificationsIntervalSec: 90,
      repoLimit: 6, issuesFilter: "all", sibling: "kept"
    })
    root._waitUntil(function () { return root.service.dashboardIntervalSec === 240 }, 4000, function (timedOut) {
      check("recreated file restores",
        !timedOut && root.service.dashboardIntervalSec === 240 && root.service.settingsDiagnostic === "")
      root.recreateService()
    })
  }

  function recreateService() {
    var old = root.service
    root.service = null
    old.destroy()
    Qt.callLater(function () {
      var s2 = root.makeService()
      root._waitUntil(function () {
        return root.barWidget.svc === s2 && root.service.dashboardIntervalSec === 240
      }, 5000, function (timedOut) {
        var p2 = root.panel()
        check("service recreate followed by panel",
          !timedOut && root.barWidget.svc === s2 && !!p2 && p2.svc === s2 && p2.issuesFilter === "all")
        root.finish("")
      })
    })
  }

  function finish(note) {
    if (root.done) return
    root.done = true
    var failed = 0
    for (var i = 0; i < root.checks.length; i++) if (!root.checks[i].pass) failed++
    console.log("PROBE_RESULT " + JSON.stringify({ note: note || "", failed: failed, checks: root.checks }))
    Qt.quit()
  }

  Timer { interval: 25000; running: true; repeat: false; onTriggered: root.finish("probe harness overall timeout (25s)") }
}
