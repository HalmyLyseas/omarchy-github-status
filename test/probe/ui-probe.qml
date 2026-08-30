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
  property bool openItemRejectedStayedOpen: false
  property bool openItemClosedAfterValid: false

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
    item.ghVersionTimeoutMs = 1500
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
      heroMeta: p.heroMeta,
      ghVersion: svc.ghVersion,
      ghVersionSupported: svc.ghVersionSupported
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

  // (4) search: matching sections temporarily open while zero-match ones
  // stay folded; manual fold state survives the search and its clearing.
  function scenarioSearch() {
    var p = panel()
    if (!p) { finish("no panel instance"); return }
    p.open()
    _waitUntil(function() { return p.opened === true }, 3000, function(timedOut) {
      if (timedOut) { finish("panel did not open for search scenario"); return }
      verifySearchSession(p)
    })
  }

  function verifySearchSession(p) {
    var content = p._debugContentItem
    var sections = [
      { label: "INBOX", state: "inboxCollapsed", effective: "inboxEffectivelyCollapsed" },
      { label: "REVIEW REQUESTS", state: "reviewRequestsCollapsed", effective: "reviewRequestsEffectivelyCollapsed" },
      { label: "MY OPEN PULL REQUESTS", state: "openPRsCollapsed", effective: "openPRsEffectivelyCollapsed" },
      { label: "MY OPEN ISSUES", state: "myIssuesCollapsed", effective: "myIssuesEffectivelyCollapsed" },
      { label: "REPOSITORIES", state: "repoActivityCollapsed", effective: "repoActivityEffectivelyCollapsed" }
    ]
    var headers = []
    var rows = []
    var allInitiallyManualCollapsed = true
    var allInitiallyHidden = true
    for (var i = 0; i < sections.length; i++) {
      headers[i] = findByProp(content, "text", sections[i].label)
      rows[i] = sectionRows(headers[i])
      allInitiallyManualCollapsed = allInitiallyManualCollapsed && p[sections[i].state] === true
      allInitiallyHidden = allInitiallyHidden && rows[i] && rows[i].visible === false
    }
    var reposHeader = headers[4]
    var beforeReposLength = p.filteredRepos.length
    var beforePill = reposHeader ? reposHeader.pillLabel : null
    p.searchQuery = "vandal"
    _waitUntil(function() {
      return p.repoActivityEffectivelyCollapsed === false
        && p.myIssuesEffectivelyCollapsed === false
        && p.openPRsEffectivelyCollapsed === true
        && rows[4].visible === true
        && rows[3].visible === true
        && rows[2].visible === false
    }, 3000, function(timedOut) {
      if (timedOut) { finish("search did not apply the vandal match distribution"); return }
      var vandalHeadersAgree = true
      var vandalExpected = [true, true, true, false, false]
      for (var j = 0; j < sections.length; j++) {
        vandalHeadersAgree = vandalHeadersAgree
          && headers[j] && headers[j].collapsed === vandalExpected[j]
          && rows[j] && rows[j].visible === !vandalExpected[j]
      }
      var afterReposLength = p.filteredRepos.length
      var afterIssuesLength = p.filteredMyIssues.length
      var afterOpenPRsLength = p.filteredOpenPRs.length
      var afterPill = reposHeader ? reposHeader.pillLabel : null

      p.searchQuery = "nujabes"
      _waitUntil(function() {
        return p.openPRsEffectivelyCollapsed === false
          && rows[2].visible === true
          && rows[3].visible === true
          && rows[4].visible === true
          && rows[0].visible === false
          && rows[1].visible === false
      }, 3000, function(recomputeTimedOut) {
        if (recomputeTimedOut) { finish("search did not recompute for nujabes"); return }
        var recomputedDistribution = headers[2] && headers[2].collapsed === false
          && headers[3] && headers[3].collapsed === false
          && headers[4] && headers[4].collapsed === false
          && headers[0] && headers[0].collapsed === true
          && headers[1] && headers[1].collapsed === true

        // A click during active search changes only the preserved manual
        // layout. Inbox remains hidden because it has no matching rows.
        headers[0].toggled()
        var manualChangeStayedOverridden = p.inboxCollapsed === false
          && p.inboxEffectivelyCollapsed === true
          && rows[0].visible === false
        p.searchQuery = ""
        _waitUntil(function() {
          return p.searchActive === false && rows[0].visible === true
        }, 3000, function(clearTimedOut) {
          if (clearTimedOut) { finish("clearing search did not restore manual layout"); return }
          var restoredManualLayout = rows[0].visible === true
          for (var k = 1; k < sections.length; k++) {
            restoredManualLayout = restoredManualLayout
              && p[sections[k].state] === true
              && p[sections[k].effective] === true
              && rows[k].visible === false
          }
          finish("", {
            allInitiallyManualCollapsed: allInitiallyManualCollapsed,
            allInitiallyHidden: allInitiallyHidden,
            beforeReposLength: beforeReposLength,
            beforePill: beforePill,
            afterReposLength: afterReposLength,
            afterIssuesLength: afterIssuesLength,
            afterOpenPRsLength: afterOpenPRsLength,
            afterPill: afterPill,
            vandalHeadersAgree: vandalHeadersAgree,
            recomputedDistribution: recomputedDistribution,
            manualChangeStayedOverridden: manualChangeStayedOverridden,
            restoredManualLayout: restoredManualLayout
          })
        })
      })
    })
  }

  // (5) fold: every section opens folded, expands through its own header,
  // and returns to folded when the popup reopens.
  function scenarioFold() {
    var p = panel()
    if (!p) { finish("no panel instance"); return }
    p.open()
    _waitUntil(function() { return p.opened === true }, 3000, function(timedOut) {
      if (timedOut) { finish("panel did not open for fold scenario"); return }
      verifyFoldSession(p)
    })
  }

  function verifyFoldSession(p) {
    var content = p._debugContentItem
    var sections = [
      { label: "INBOX", state: "inboxCollapsed" },
      { label: "REVIEW REQUESTS", state: "reviewRequestsCollapsed" },
      { label: "MY OPEN PULL REQUESTS", state: "openPRsCollapsed" },
      { label: "MY OPEN ISSUES", state: "myIssuesCollapsed" },
      { label: "REPOSITORIES", state: "repoActivityCollapsed" }
    ]
    var headers = []
    var rows = []
    var allFound = true
    var allInitiallyCollapsed = true
    var allInitiallyHidden = true
    var everyHeaderFoldable = true
    var eachExpandsOnlyOwnBody = true
    for (var i = 0; i < sections.length; i++) {
      headers[i] = findByProp(content, "text", sections[i].label)
      rows[i] = sectionRows(headers[i])
      allFound = allFound && headers[i] !== null && rows[i] !== null
      allInitiallyCollapsed = allInitiallyCollapsed && p[sections[i].state] === true
      allInitiallyHidden = allInitiallyHidden && rows[i] && rows[i].visible === false
      everyHeaderFoldable = everyHeaderFoldable && headers[i] && headers[i].foldAffordanceVisible === true
    }
    // An empty, unsynced header must retain its affordance too.
    if (headers[0]) {
      headers[0].synced = false
      headers[0].count = 0
      everyHeaderFoldable = everyHeaderFoldable && headers[0].foldAffordanceVisible === true
    }
    for (var j = 0; j < sections.length; j++) {
      headers[j].toggled()
      for (var k = 0; k < sections.length; k++) {
        eachExpandsOnlyOwnBody = eachExpandsOnlyOwnBody && rows[k].visible === (j === k)
      }
      headers[j].toggled()
    }
    var issuesChip = findByProp(headers[3], "text", "SUBSCRIBED")
    var chipKeepsIssuesFolded = issuesChip !== null
    if (issuesChip) {
      var issuesCollapsedBeforeChip = p.myIssuesCollapsed
      issuesChip.clicked()
      chipKeepsIssuesFolded = p.myIssuesCollapsed === issuesCollapsedBeforeChip
    }
    for (var n = 0; n < sections.length; n++) p[sections[n].state] = false
    p.close()
    _waitUntil(function() { return p.opened === false }, 3000, function(closeTimedOut) {
      if (closeTimedOut) { finish("panel did not close for fold reset"); return }
      p.open()
      _waitUntil(function() { return p.opened === true }, 3000, function(openTimedOut) {
        if (openTimedOut) { finish("panel did not reopen for fold reset"); return }
        var resetCollapsed = true
        var resetHidden = true
        for (var m = 0; m < sections.length; m++) {
          resetCollapsed = resetCollapsed && p[sections[m].state] === true
          resetHidden = resetHidden && rows[m].visible === false
        }
        finish("", {
          allFound: allFound,
          allInitiallyCollapsed: allInitiallyCollapsed,
          allInitiallyHidden: allInitiallyHidden,
          everyHeaderFoldable: everyHeaderFoldable,
          eachExpandsOnlyOwnBody: eachExpandsOnlyOwnBody,
          chipKeepsIssuesFolded: chipKeepsIssuesFolded,
          resetCollapsed: resetCollapsed,
          resetHidden: resetHidden
        })
      })
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

  // (7) openItem keeps the popup open for a rejection, then closes it only
  // after the service starts the safe, fixed-argv browser handoff.
  function scenarioOpenItem() {
    var p = panel()
    if (!p) { finish("no panel instance"); return }
    p.open()
    _waitUntil(function() { return p.opened === true }, 3000, function(timedOut) {
      if (timedOut) { finish("panel did not open for openItem scenario"); return }
      p.openItem("https://evil.example.com/x")
      probeRoot.openItemRejectedStayedOpen = p.opened === true
      p.openItem("https://github.com/o/r/issues/1")
      probeRoot.openItemClosedAfterValid = p.opened === false
      readLogTimer.start()
    })
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
      onStreamFinished: {
        var lines = text.trim() ? text.trim().split("\n") : []
        probeRoot.finish("", {
          rejectedStayedOpen: probeRoot.openItemRejectedStayedOpen,
          closedAfterValid: probeRoot.openItemClosedAfterValid,
          xdgOpenCount: lines.length,
          validArgvOnly: lines.length === 1 && lines[0].indexOf("ARGV: https://github.com/o/r/issues/1") >= 0
        })
      }
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
