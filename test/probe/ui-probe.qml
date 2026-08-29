import QtQuick
import Quickshell
import Quickshell.Io

// Instantiates the REAL BarWidget.qml (which eagerly loads Panel.qml) against
// a stub bar/shell, and the REAL Service.qml against the mock `gh`. Drives
// one env-selected scenario and prints one "PROBE_RESULT {...}" line.
ShellRoot {
  id: probeRoot

  property string pluginDir: Quickshell.env("GHS_PLUGIN_DIR")
  property string ghPathOverride: Quickshell.env("GHS_GHPATH")
  property string scenario: Quickshell.env("GHS_UI_SCENARIO") || ""
  property string xdgOpenLog: Quickshell.env("GHS_XDGOPEN_LOG")
  property bool done: false
  property int elapsedMs: 0

  property var barWidget: null
  property var svc: null

  function panel() { return barWidget ? barWidget._debugPanelItem : null }

  // Answers both roles a real `shell` plays here: BarWidget/Panel's
  // `bar.shell.serviceFor(id)`, and Service.qml's own injected
  // `shell.shellConfig`/`shell.updateEntryInline`.
  QtObject {
    id: stubShell
    property var svcInstance: null
    property var shellConfig: []
    property var updateEntryInlineCalls: []
    function serviceFor(id) { return id === "halmylyseas.github-status" ? stubShell.svcInstance : null }
    function updateEntryInline(id, entry) {
      stubShell.updateEntryInlineCalls = stubShell.updateEntryInlineCalls.concat([{ id: id, entry: entry }])
    }
  }

  // Every property/method BarIconButton/KeyboardPanel read off `bar` -- a
  // name missing here is a TypeError the moment the real widget touches it.
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
    property var shell: stubShell
    property var activePopout: null
    property var clickTargets: []
    property var tooltipCalls: []
    function showTooltip(target, text) { stubBar.tooltipCalls = stubBar.tooltipCalls.concat([text]) }
    function hideTooltip(target) {}
    function requestPopout(owner) { stubBar.activePopout = owner }
    function releasePopout(owner) { if (stubBar.activePopout === owner) stubBar.activePopout = null }
    function moduleWidgets(name) { return probeRoot.barWidget ? [probeRoot.barWidget] : [] }
    function registerClickTarget(target) {}
    function unregisterClickTarget(target) {}
  }

  Loader {
    id: svcLoader
    active: true
    source: "file://" + probeRoot.pluginDir + "/Service.qml"
    onLoaded: {
      probeRoot.svc = item
      stubShell.svcInstance = item
      item.shell = stubShell
      probeRoot._armService(item)
      barLoader.active = true
    }
  }

  // Shared between the initial load and the lifecycle scenario's second
  // instance -- same timeout/interval shortenings test/probe/service-probe.qml
  // already applies, so the probe doesn't sit through real 30s watchdogs.
  function _armService(item) {
    if (probeRoot.ghPathOverride) item.ghPath = probeRoot.ghPathOverride
    item.ghPathTimeoutMs = 1500
    item.probeTimeoutMs = 1500
    item.dashboardTimeoutMs = 1500
    item.notificationsTimeoutMs = 1500
    item.reProbeMs = 800
  }

  Loader {
    id: barLoader
    active: false
    source: "file://" + probeRoot.pluginDir + "/BarWidget.qml"
    onLoaded: {
      probeRoot.barWidget = item
      item.bar = stubBar
      item.settings = ({})
      settleTimer.start()
    }
  }

  Timer {
    id: settleTimer
    interval: 200
    repeat: false
    onTriggered: probeRoot._drainThen(probeRoot.runScenario)
  }

  property var _afterBusy: null

  Timer {
    id: busyDrainTimer
    interval: 100
    repeat: true
    onTriggered: {
      probeRoot.elapsedMs += interval
      if (!probeRoot.svc._anyProcRunning) {
        busyDrainTimer.stop()
        var cb = probeRoot._afterBusy
        probeRoot._afterBusy = null
        if (cb) cb()
      } else if (probeRoot.elapsedMs > 20000) {
        busyDrainTimer.stop()
        probeRoot.finish("process queue did not settle within 20s")
      }
    }
  }

  function _drainThen(cb) {
    elapsedMs = 0
    _afterBusy = cb
    busyDrainTimer.start()
  }

  // Generic poll-until helper: calls `check()` every 50ms until it returns
  // true or `timeoutMs` elapses, then calls `cb(timedOut)`.
  function _waitUntil(check, timeoutMs, cb) {
    var waited = 0
    var timer = Qt.createQmlObject(
      'import QtQuick; Timer { interval: 50; repeat: true }', probeRoot)
    timer.triggered.connect(function() {
      waited += 50
      if (check()) {
        timer.stop(); timer.destroy()
        cb(false)
      } else if (waited > timeoutMs) {
        timer.stop(); timer.destroy()
        cb(true)
      }
    })
    timer.start()
  }

  // Depth-first search for a descendant whose `propName` matches
  // `propValue` -- how a SectionHeader is identified by its `text` label
  // from outside, since a QML Item has no id reachable across files.
  function findByProp(item, propName, propValue) {
    if (!item) return null
    if (propName in item && item[propName] === propValue) return item
    var kids = item.children || []
    for (var i = 0; i < kids.length; i++) {
      var found = findByProp(kids[i], propName, propValue)
      if (found) return found
    }
    return null
  }

  // Every section is `Column { SectionHeader {...}; Column { visible:
  // !collapsed; Repeater {...} } }` -- given the header, its parent's
  // second child is the row-list Column.
  function sectionRows(header) {
    if (!header || !header.parent || !header.parent.children || header.parent.children.length < 2) return null
    return header.parent.children[1]
  }
  function sectionRepeater(header) {
    var rows = sectionRows(header)
    if (!rows || !rows.children) return null
    // A Repeater reparents its delegates as siblings of itself, so it isn't
    // reliably at a fixed index once it has 1+ delegates -- find it by its
    // own `count`/`model` properties instead.
    for (var i = 0; i < rows.children.length; i++) {
      var c = rows.children[i]
      if (c && c.count !== undefined && c.model !== undefined) return c
    }
    return null
  }

  function runScenario() {
    if (scenario === "ok") scenarioOk()
    else if (scenario === "degraded") scenarioDegraded()
    else if (scenario === "partial") scenarioPartial()
    else if (scenario === "search") scenarioSearch()
    else if (scenario === "fold") scenarioFold()
    else if (scenario === "lifecycle") scenarioLifecycle()
    else if (scenario === "openitem") scenarioOpenItem()
    else finish("unknown GHS_UI_SCENARIO: " + scenario)
  }

  // (1) ok: every section renders (Repeater counts match the fixture after
  // caps/filters), pills read "N of T" where totalCount/issueCount exceeds
  // the rendered count, and the bar's derived properties read correctly.
  function scenarioOk() {
    var p = panel()
    if (!p) { finish("no panel instance"); return }
    var content = p._debugContentItem
    var inboxHeader = findByProp(content, "text", "INBOX")
    var reviewHeader = findByProp(content, "text", "REVIEW REQUESTS")
    var prHeader = findByProp(content, "text", "MY OPEN PULL REQUESTS")
    var issuesHeader = findByProp(content, "text", "MY OPEN ISSUES")
    var reposHeader = findByProp(content, "text", "REPOSITORIES")
    function count(h) { var r = sectionRepeater(h); return r ? r.count : null }
    finish("", {
      status: svc.status,
      inboxLength: p.filteredNotifications.length,
      reviewLength: p.filteredReviewRequests.length,
      prLength: p.filteredOpenPRs.length,
      issuesLength: p.filteredMyIssues.length,
      reposLength: p.filteredRepos.length,
      inboxRepeaterCount: count(inboxHeader),
      reviewRepeaterCount: count(reviewHeader),
      prRepeaterCount: count(prHeader),
      issuesRepeaterCount: count(issuesHeader),
      reposRepeaterCount: count(reposHeader),
      reviewPill: reviewHeader ? reviewHeader.pillLabel : null,
      prPill: prHeader ? prHeader.pillLabel : null,
      issuesPill: issuesHeader ? issuesHeader.pillLabel : null,
      reposPill: reposHeader ? reposHeader.pillLabel : null,
      unreadCount: barWidget.unreadCount,
      hasAttention: barWidget.hasAttention,
      tooltipSummary: barWidget.tooltipSummary
    })
  }

  // (2) degraded ladder: whichever GH_MOCK_MODE/ghPath run-ui chose, read
  // the resulting statusHint/statusHintSevere/heroMeta off the real Panel.
  function scenarioDegraded() {
    var p = panel()
    if (!p) { finish("no panel instance"); return }
    finish("", {
      status: svc.status,
      statusHint: p.statusHint,
      statusHintSevere: p.statusHintSevere,
      heroMeta: p.heroMeta
    })
  }

  // (3) partial: hero meta gains "· partial", the status hint gains a line.
  function scenarioPartial() {
    var p = panel()
    if (!p) { finish("no panel instance"); return }
    finish("", {
      dashboardPartial: svc.dashboardPartial,
      heroMeta: p.heroMeta,
      statusHint: p.statusHint
    })
  }

  // (4) search: root.searchQuery narrows every filtered list; a rendered
  // pill follows the narrowed count and drops "N of T" while active.
  function scenarioSearch() {
    var p = panel()
    if (!p) { finish("no panel instance"); return }
    var content = p._debugContentItem
    var reposHeader = findByProp(content, "text", "REPOSITORIES")
    var beforeReposLength = p.filteredRepos.length
    var beforePill = reposHeader ? reposHeader.pillLabel : null
    p.searchQuery = "vandal"
    finish("", {
      beforeReposLength: beforeReposLength,
      beforePill: beforePill,
      afterReposLength: p.filteredRepos.length,
      afterIssuesLength: p.filteredMyIssues.length,
      afterOpenPRsLength: p.filteredOpenPRs.length,
      afterPill: reposHeader ? reposHeader.pillLabel : null
    })
  }

  // (5) fold: root.openPRsCollapsed hides the section's row-list Column --
  // proven against the actual rendered tree, not just the backing boolean.
  function scenarioFold() {
    var p = panel()
    if (!p) { finish("no panel instance"); return }
    var content = p._debugContentItem
    var header = findByProp(content, "text", "MY OPEN PULL REQUESTS")
    var rows = sectionRows(header)
    var visibleBefore = rows ? rows.visible : null
    p.openPRsCollapsed = true
    var visibleAfterCollapse = rows ? rows.visible : null
    p.openPRsCollapsed = false
    var visibleAfterExpand = rows ? rows.visible : null
    finish("", {
      foundRows: rows !== null,
      visibleBefore: visibleBefore,
      visibleAfterCollapse: visibleAfterCollapse,
      visibleAfterExpand: visibleAfterExpand
    })
  }

  // (6) svc -> null -> new instance: BarWidget/Panel are never destroyed --
  // `svc` is a live reactive read of shell.serviceFor(id), so this proves
  // that degrading to null and back to a fresh instance never throws.
  property bool _lcSvcWasNonNull: false
  property bool _lcHeroWasLoadingWhileNull: false

  function scenarioLifecycle() {
    _lcSvcWasNonNull = barWidget.svc !== null
    stubShell.svcInstance = null
    svcLoader.active = false
    _waitUntil(function() { return barWidget.svc === null }, 5000, function(timedOut) {
      if (timedOut) { finish("svc did not go null within 5s"); return }
      var p = panel()
      _lcHeroWasLoadingWhileNull = p ? (p.heroMeta === "Loading…") : false
      svcLoader2.active = true
    })
  }

  Loader {
    id: svcLoader2
    active: false
    source: "file://" + probeRoot.pluginDir + "/Service.qml"
    onLoaded: probeRoot._lifecyclePhase2(item)
  }

  function _lifecyclePhase2(svc2) {
    probeRoot._armService(svc2)
    stubShell.svcInstance = svc2
    _waitUntil(function() { return barWidget.svc === svc2 }, 5000, function(timedOut) {
      finish(timedOut ? "svc did not pick up the new instance within 5s" : "", {
        svcWasNonNullBeforeDestroy: _lcSvcWasNonNull,
        heroMetaWasLoadingWhileNull: _lcHeroWasLoadingWhileNull,
        svcNowIsNewInstance: barWidget.svc === svc2
      })
    })
  }

  // (7) openItem allowlist: a non-github URL is refused before it ever
  // reaches xdg-open -- the mock (PATH-shadowed) logs nothing.
  function scenarioOpenItem() {
    var p = panel()
    if (!p) { finish("no panel instance"); return }
    p.openItem("https://evil.example.com/x")
    readLogTimer.start()
  }

  Timer {
    id: readLogTimer
    interval: 400
    repeat: false
    onTriggered: catLogProc.running = true
  }

  Process {
    id: catLogProc
    command: ["cat", probeRoot.xdgOpenLog]
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: probeRoot.finish("", { xdgOpenLogEmpty: text.trim().length === 0 })
    }
  }

  function finish(note, extra) {
    if (done) return
    done = true
    var summary = { scenario: scenario, note: note }
    for (var key in (extra || {})) summary[key] = extra[key]
    console.log("PROBE_RESULT " + JSON.stringify(summary))
    Qt.quit()
  }

  Timer {
    interval: 25000
    running: true
    repeat: false
    onTriggered: probeRoot.finish("probe harness overall timeout (25s)")
  }
}
