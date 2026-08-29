// Panel.qml -- the popup: Hero, search, then five independently-foldable
// sections (Inbox, Review requests, My open PRs, My open issues,
// Repositories). See docs/developers.md "Architecture"/"Security invariants".
import QtQuick
import QtQuick.Controls
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "halmylyseas.github-status"
  ipcTarget: "halmylyseas.github-status"
  // This file declares its own IpcHandler below (adds `version()`), so the
  // base Panel's inherited open/close/show/hide/toggle handler is disabled
  // rather than double-registering the same target.
  manageIpc: false

  // Handed over by BarWidget.injectPanel().
  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property var shell: bar && bar.shell ? bar.shell : null
  readonly property var svc: shell ? shell.serviceFor("halmylyseas.github-status") : null

  // UI-probe-only: a plain forward reference to the rendered content
  // Column, otherwise unreachable across files -- see test/probe/ui-probe.qml.
  readonly property var _debugContentItem: column

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color muted: Color.muted
  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  // Relative-time labels read this instead of Date.now() so a panel left
  // open keeps counting up ("3m" -> "4m") while the user is looking at it.
  property double nowMs: Date.now()

  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  // Query text typed into `searchField`. Ephemeral by design -- reset below
  // on open (not close) so a panel instance kept alive in memory between
  // open/close cycles never shows a stale query for even one frame.
  property string searchQuery: ""
  readonly property bool searchActive: root.searchQuery.trim() !== ""

  // Per-section fold state, session-only, deliberately not persisted to
  // shell.json -- same reset-on-open treatment as searchQuery.
  property bool inboxCollapsed: false
  property bool reviewRequestsCollapsed: false
  property bool openPRsCollapsed: false
  property bool myIssuesCollapsed: false
  property bool repoActivityCollapsed: false

  onOpenedChanged: if (opened) {
    root.nowMs = Date.now()
    if (panelFlick) panelFlick.contentY = 0
    root.searchQuery = ""
    if (searchField) searchField.text = ""
    root.inboxCollapsed = false
    root.reviewRequestsCollapsed = false
    root.openPRsCollapsed = false
    root.myIssuesCollapsed = false
    root.repoActivityCollapsed = false
  }

  // Model.matchesQuery(item, query) is the data-layer's contract, guarded
  // like every cross-owner Model.* read here so a Model.js mismatch
  // degrades to "show everything unfiltered", never a crash.
  function itemMatchesQuery(item) {
    if (!root.searchActive) return true
    return (typeof Model.matchesQuery === "function") ? Model.matchesQuery(item, root.searchQuery) : true
  }

  // Pure client-side narrowing of an already-fetched list -- never a new
  // remote read. Returns the SAME array reference when no query is active,
  // so this costs nothing extra when the user isn't searching.
  function filterList(list) {
    if (!root.searchActive) return list
    var out = []
    for (var i = 0; i < list.length; i++) {
      if (root.itemMatchesQuery(list[i])) out.push(list[i])
    }
    return out
  }

  // Every list defaults to [] and every item access is guarded -- svc can
  // be null on first paint, and a degraded service legitimately reports
  // empty/last-good lists.

  readonly property var allNotifications: svc && svc.notifications ? svc.notifications : []
  // "Inbox" is unread notifications specifically; filtered here rather
  // than assumed pre-filtered, so this is correct even if the service ever
  // starts returning read ones too.
  readonly property var unreadNotifications: {
    var out = []
    for (var i = 0; i < allNotifications.length; i++) {
      if (allNotifications[i] && allNotifications[i].unread === true) out.push(allNotifications[i])
    }
    return out
  }
  readonly property var reviewRequests: svc && svc.reviewRequests ? svc.reviewRequests : []
  readonly property var openPRs: svc && svc.openPRs ? svc.openPRs : []
  // svc.myIssues is already post-subscribed-filter (Service.qml's job) --
  // this is the shown set before search narrows it further below.
  readonly property var myIssues: svc && svc.myIssues ? svc.myIssues : []
  readonly property var repos: svc && svc.repos ? svc.repos : []

  // The rendered (search-filtered) list each Repeater actually binds to.
  // Identical to the un-filtered list above when no query is active.
  readonly property var filteredNotifications: root.filterList(root.unreadNotifications)
  readonly property var filteredReviewRequests: root.filterList(root.reviewRequests)
  readonly property var filteredOpenPRs: root.filterList(root.openPRs)
  readonly property var filteredMyIssues: root.filterList(root.myIssues)
  readonly property var filteredRepos: root.filterList(root.repos)

  // "…" pill state, per-source rather than the blended svc.lastSyncMs:
  // both pollers can race on a cold start, so gating every section on
  // whichever finishes first could show a false confirmed-"0" on the other.
  readonly property bool dashboardSynced: !!svc && Number(svc.dashboardLastSyncMs) !== 0
  readonly property bool notifSynced: !!svc && Number(svc.notificationsLastSyncMs) !== 0

  // Mirror-property + setter shape against the Service.qml contract
  // (issuesFilter "focus"|"all" default "focus", setIssuesFilter(mode)).
  readonly property string issuesFilter: svc && svc.issuesFilter ? String(svc.issuesFilter) : "focus"

  function setIssuesFilter(mode) {
    if (svc && typeof svc.setIssuesFilter === "function") svc.setIssuesFilter(mode)
  }

  // "owner/repo" -> "repo". The owner moves into its own pill, so rows need
  // the bare name; a pure client-side split, never a new remote read.
  function shortRepoName(fullName) {
    var s = String(fullName || "")
    var idx = s.indexOf("/")
    return idx >= 0 ? s.slice(idx + 1) : s
  }

  function openItem(url) {
    if (svc && typeof svc.openUrl === "function" && url) svc.openUrl(url)
  }

  function refreshNow() {
    if (svc && typeof svc.refresh === "function") svc.refresh()
  }

  // Replaces the base Panel's own open/close/show/hide/toggle handler
  // (manageIpc: false above) so `version()` can share the same IPC target.
  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }

    // omarchy-shell halmylyseas.github-status version -> JSON verification
    // surface: which gh binary is in use, and whether it's a tested major.
    function version(): string {
      var s = root.svc
      return JSON.stringify({
        ghPath: s ? s.ghPath : "",
        ghVersion: s ? s.ghVersion : "",
        ghVersionSupported: s ? s.ghVersionSupported : null
      })
    }
  }

  // ------------------------------------------------------------- hero text

  function lastSyncLabel() {
    if (!svc || !svc.lastSyncMs) return "Never synced"
    var iso = new Date(Number(svc.lastSyncMs)).toISOString()
    var rel = Model.relativeTime(iso, root.nowMs)
    return rel ? "Synced " + rel : "Never synced"
  }

  readonly property string heroMeta: {
    if (!svc) return "Loading…"
    if (svc.status === "loading") return "Loading…"
    if (svc.busy === true) return "Syncing…"
    // dashboardPartial means the last-applied fetch only parsed some
    // sections -- called out next to the sync time, not only in the hint below.
    return svc.dashboardPartial ? lastSyncLabel() + " · partial" : lastSyncLabel()
  }

  // ---------------------------------------------------- degradation states
  // Shown as a hint block in the hero area -- never a blank/broken panel;
  // last-good data (if any) stays listed in the sections below regardless.

  readonly property bool statusHintSevere: !!svc && (svc.status === "no-gh" || svc.status === "unauthenticated")

  readonly property string statusHint: {
    if (!svc) return ""
    var base = ""
    switch (svc.status) {
      case "no-gh": base = "GitHub CLI (gh) not found. Install it from https://cli.github.com/."; break
      case "unauthenticated": base = "Not signed in — run \"gh auth login\" in a terminal."; break
      case "offline": base = "Offline — showing last-known data."; break
      case "rate-limited": {
        var until = svc.rateLimitedUntil
        base = "Rate-limited — resuming" + (until ? " at " + until : " shortly") + ". Showing last-known data."
        break
      }
      default: base = ""
    }
    // Appended, not replacing, whatever the status ladder above already
    // says -- any combination of a degraded status, a partial fetch, and an
    // untested gh version can be true at once; none of them is severe.
    var extras = []
    if (svc.dashboardPartial) extras.push("Some sections failed to load — showing last-known data for them.")
    if (svc.ghVersionSupported === false) {
      extras.push("GitHub CLI " + svc.ghVersion + " is untested with this plugin; some data may display incorrectly.")
    }
    if (extras.length === 0) return base
    return base ? base + " " + extras.join(" ") : extras.join(" ")
  }

  // ---------------------------------------------------------- CI + review

  function ciGlyph(state) {
    switch (state) {
      case "success": return "✓"
      case "failure": return "✗"
      case "pending": return "●"
      default: return "−"
    }
  }

  function ciColor(state) {
    switch (state) {
      case "success": return root.foreground
      case "failure": return root.urgent
      case "pending": return root.muted
      default: return root.dim
    }
  }

  // Mapped from GitHub's fixed reviewDecision enum to a short label -- every
  // Text using it still sets PlainText as policy, since it traces to the API.
  function reviewDecisionLabel(decision) {
    switch (decision) {
      case "APPROVED": return "Approved"
      case "CHANGES_REQUESTED": return "Changes requested"
      case "REVIEW_REQUIRED": return "Review required"
      default: return ""
    }
  }

  // notification.reason is a fixed GitHub vocabulary ("review_requested",
  // "mention", "assign", ...) but still API-sourced text -- render, don't
  // trust the character set blindly.
  function reasonLabel(reason) {
    var r = String(reason || "")
    if (!r) return ""
    return r.charAt(0).toUpperCase() + r.slice(1).replace(/_/g, " ")
  }

  // "last comment: <login> · <relative age>" -- lastCommenter/lastCommentAt
  // live on openPRs/reviewRequests/myIssues rows only. "" whenever
  // lastCommenter is empty/missing; the caller omits the tooltip line then.
  function commentTooltip(item) {
    if (!item || !item.lastCommenter) return ""
    var age = Model.relativeTime(item.lastCommentAt, root.nowMs)
    return "last comment: " + item.lastCommenter + (age ? " · " + age : "")
  }

  // ------------------------------------------------------------------ UI

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(600))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While the search field holds focus, it owns every key, so vim
      // letters typed into a query never get stolen as scroll/delete keys.
      blocked: !!searchField && searchField.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) {
        if (dy === 0) return
        panelFlick.contentY = Math.max(0, Math.min(
          panelFlick.contentY + dy * Style.space(56),
          Math.max(0, panelFlick.contentHeight - panelFlick.height)))
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // ---------------------------------------------------------- hero
          PanelHero {
            width: parent.width
            title: "GitHub Status"
            meta: root.heroMeta
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                text: ""
                textFormat: Text.PlainText
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
            trailingControl: Component {
              Button {
                iconText: "↻"
                iconSpinning: !!svc && svc.busy === true
                tooltipText: "Refresh"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.refreshNow()
              }
            }
          }

          // Not auto-focused on open: KeyboardPanel already force-focuses
          // `keyCatcher` itself, so this only engages on an explicit click.
          Item {
            id: searchRow
            width: parent.width
            height: searchField.implicitHeight

            TextField {
              id: searchField
              anchors.left: parent.left
              anchors.right: clearGlyph.visible ? clearGlyph.left : parent.right
              anchors.rightMargin: clearGlyph.visible ? Style.space(6) : 0
              anchors.verticalCenter: parent.verticalCenter
              placeholderText: "Search…"
              // Mirrors Model.matchesQuery's own query cap so a
              // pathologically long paste never reaches the filter at all.
              maximumLength: 100
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              foreground: root.foreground

              // Field owns `text`; every place that clears the query from
              // outside it also sets `searchField.text` imperatively --
              // typing already reassigns `text`, breaking a plain binding.
              onTextChanged: root.searchQuery = text

              // Esc: clear-then-close, both steps handled locally so
              // PanelKeyCatcher (blocked while this field has focus) never
              // has to know about search state at all.
              Keys.onEscapePressed: function(event) {
                if (root.searchQuery !== "") {
                  root.searchQuery = ""
                  searchField.text = ""
                } else {
                  root.close()
                }
                event.accepted = true
              }
            }

            // Clear affordance for mouse users, alongside the Esc handling
            // above -- both are cheap and serve different input styles.
            Text {
              id: clearGlyph
              visible: root.searchQuery !== ""
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: "✕"
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body

              MouseArea {
                anchors.fill: parent
                anchors.margins: -Style.space(6)
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root.searchQuery = ""
                  searchField.text = ""
                  searchField.forceActiveFocus()
                }
              }
            }
          }

          BorderSurface {
            id: statusHintBox
            visible: root.statusHint !== ""
            width: parent.width
            implicitHeight: statusHintText.implicitHeight + Style.spacing.xl * 2
            color: root.alpha(root.statusHintSevere ? root.urgent : root.foreground, 0.10)
            borderSpec: Border.flat(root.alpha(root.statusHintSevere ? root.urgent : root.foreground, 0.35), Style.normalBorderWidth)
            radius: Style.cornerRadius

            Text {
              id: statusHintText
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(12)
              anchors.rightMargin: Style.space(12)
              text: root.statusHint
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: root.statusHintSevere ? root.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: root.statusHintSevere
            }
          }

          PanelSeparator { foreground: root.foreground }

          // --------------------------------------------------------- inbox
          Column {
            width: parent.width
            spacing: Style.space(4)

            SectionHeader {
              text: "INBOX"
              // The service's own unread count when not searching; the
              // filtered rendered length while a query is active, matching
              // every other section's "reflect what's on screen" rule.
              count: root.searchActive ? root.filteredNotifications.length : (svc ? (Number(svc.unreadCount) || 0) : 0)
              synced: root.notifSynced
              collapsed: root.inboxCollapsed
              foreground: root.foreground
              fontFamily: root.fontFamily
              onToggled: root.inboxCollapsed = !root.inboxCollapsed
            }

            Column {
              width: parent.width
              spacing: Style.space(4)
              visible: !root.inboxCollapsed

              Repeater {
                model: root.filteredNotifications

                NotificationRow {
                  required property var modelData
                  width: parent ? parent.width : 0
                  item: modelData
                }
              }
            }
          }

          PanelSeparator { foreground: root.foreground }

          // ------------------------------------------------ review requests
          Column {
            width: parent.width
            spacing: Style.space(4)

            SectionHeader {
              text: "REVIEW REQUESTS"
              count: root.filteredReviewRequests.length
              // 0 during an active search -- the pill shows the filtered
              // length only then, never "N of T" against the unfiltered total.
              total: root.searchActive ? 0 : (svc ? (Number(svc.reviewRequestsTotal) || 0) : 0)
              synced: root.dashboardSynced
              collapsed: root.reviewRequestsCollapsed
              foreground: root.foreground
              fontFamily: root.fontFamily
              onToggled: root.reviewRequestsCollapsed = !root.reviewRequestsCollapsed
            }

            Column {
              width: parent.width
              spacing: Style.space(4)
              visible: !root.reviewRequestsCollapsed

              Repeater {
                model: root.filteredReviewRequests

                ReviewRequestRow {
                  required property var modelData
                  required property int index
                  width: parent ? parent.width : 0
                  item: modelData
                  firstInSection: index === 0
                }
              }
            }
          }

          PanelSeparator { foreground: root.foreground }

          // ---------------------------------------------------- open PRs
          Column {
            width: parent.width
            spacing: Style.space(4)

            SectionHeader {
              text: "MY OPEN PULL REQUESTS"
              count: root.filteredOpenPRs.length
              // See the REVIEW REQUESTS header above for the
              // search-suppression rule.
              total: root.searchActive ? 0 : (svc ? (Number(svc.openPRsTotal) || 0) : 0)
              synced: root.dashboardSynced
              collapsed: root.openPRsCollapsed
              foreground: root.foreground
              fontFamily: root.fontFamily
              onToggled: root.openPRsCollapsed = !root.openPRsCollapsed
            }

            Column {
              width: parent.width
              spacing: Style.space(4)
              visible: !root.openPRsCollapsed

              Repeater {
                model: root.filteredOpenPRs

                PrRow {
                  required property var modelData
                  required property int index
                  width: parent ? parent.width : 0
                  item: modelData
                  firstInSection: index === 0
                }
              }
            }
          }

          PanelSeparator { foreground: root.foreground }

          // ------------------------------------------------- open issues
          // Issues the user themselves opened, any repo -- distinct from
          // review requests (waiting on the user) and own PRs.
          Column {
            width: parent.width
            spacing: Style.space(4)

            SectionHeader {
              text: "MY OPEN ISSUES"
              count: root.filteredMyIssues.length
              // See the REVIEW REQUESTS header above for the
              // search-suppression rule.
              total: root.searchActive ? 0 : (svc ? (Number(svc.myIssuesTotal) || 0) : 0)
              synced: root.dashboardSynced
              collapsed: root.myIssuesCollapsed
              foreground: root.foreground
              fontFamily: root.fontFamily
              onToggled: root.myIssuesCollapsed = !root.myIssuesCollapsed
              // The chip's label follows its own state: "SUBSCRIBED" or
              // "ALL". Both are local literals, not remote data, so
              // Text.PlainText's file-wide policy doesn't apply here.
              extra: Component {
                Button {
                  anchors.verticalCenter: parent ? parent.verticalCenter : undefined
                  text: root.issuesFilter === "focus" ? "SUBSCRIBED" : "ALL"
                  selected: root.issuesFilter === "focus"
                  bordered: true
                  foreground: root.foreground
                  accent: Color.accent
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  focusable: false
                  onClicked: root.setIssuesFilter(root.issuesFilter === "focus" ? "all" : "focus")
                }
              }
            }

            Column {
              width: parent.width
              spacing: Style.space(4)
              visible: !root.myIssuesCollapsed

              Repeater {
                model: root.filteredMyIssues

                IssueRow {
                  required property var modelData
                  required property int index
                  width: parent ? parent.width : 0
                  item: modelData
                  firstInSection: index === 0
                }
              }
            }
          }

          PanelSeparator { foreground: root.foreground }

          // --------------------------------------------------- repositories
          // Repos render in fetch order (GraphQL PUSHED_AT desc), sliced by
          // repoLimit -- no client-side sort control; search is enough.
          Column {
            width: parent.width
            spacing: Style.space(4)

            SectionHeader {
              text: "REPOSITORIES"
              count: root.filteredRepos.length
              // See the REVIEW REQUESTS header above for the
              // search-suppression rule.
              total: root.searchActive ? 0 : (svc ? (Number(svc.reposTotal) || 0) : 0)
              synced: root.dashboardSynced
              collapsed: root.repoActivityCollapsed
              foreground: root.foreground
              fontFamily: root.fontFamily
              onToggled: root.repoActivityCollapsed = !root.repoActivityCollapsed
            }

            Column {
              width: parent.width
              spacing: Style.space(4)
              visible: !root.repoActivityCollapsed

              Repeater {
                model: root.filteredRepos

                RepoRow {
                  required property var modelData
                  required property int index
                  width: parent ? parent.width : 0
                  item: modelData
                  firstInSection: index === 0
                }
              }
            }
          }
        }
      }
    }
  }

  // ----------------------------------------------------------- components

  // An empty, synced section renders only its SectionHeader (count pill
  // reads "0"), no placeholder body row.

  // Small outlined pill used for both a repo's archived/fork/private status
  // and an external-repo owner marking, kit tokens only (no raw hex).
  // `maxWidth` caps the pill's text, not the pill, so a long login elides.
  component InlinePill: BorderSurface {
    id: pill
    property string label: ""
    // ~12 characters at caption size, approximated in px since a fixed
    // character count isn't directly expressible against a proportional
    // font; the repo-status labels never actually elide against this.
    property real maxTextWidth: Style.space(72)

    implicitWidth: pillText.width + Style.space(10)
    implicitHeight: pillText.implicitHeight + Style.space(4)
    color: "transparent"
    borderSpec: Border.flat(root.alpha(root.foreground, 0.4), Style.normalBorderWidth)
    radius: pill.implicitHeight / 2

    Text {
      id: pillText
      anchors.centerIn: parent
      text: pill.label
      textFormat: Text.PlainText
      elide: Text.ElideRight
      width: Math.min(implicitWidth, pill.maxTextWidth)
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // Drop-in replacement for qs.Ui.PanelToolTip that forces PlainText --
  // PanelToolTip's own Text doesn't set it. Flips between below (default)
  // and above the hovered row; see docs/developers.md "Architecture".
  component SafeToolTip: ToolTip {
    id: tip
    property string fontFamily: Style.font.family
    // A commit headline or "last comment" line could stretch the popup
    // arbitrarily wide against a pathological remote string; elide alone
    // bounds render cost but not layout width.
    property real maxWidth: Style.space(320)
    // The Flickable whose visible viewport bounds the tooltip's allowed
    // vertical range. Set by each call site; null-safe, falling back to
    // always-below if left unset.
    property Flickable viewport: null
    // An explicit reference to the hovered row, set per call site rather
    // than read via bare `parent` -- this file isn't `pragma
    // ComponentBehavior: Bound`, so a JS-body `parent` read is unreliable.
    property Item rowItem: null
    // True when `rowItem` is its section's first row: opening "above" then
    // always lands on the SECTION HEADER, never another row -- see the y
    // binding below.
    property bool firstInSection: false
    property real gap: Style.space(3)

    delay: 400
    padding: 0
    // Reads `tip.viewport.contentY` directly (a real bindable property) --
    // mapToItem/mapToGlobal alone are synchronous calls the dependency
    // tracker doesn't tie to scroll, so a binding using only those goes stale.
    y: {
      var row = tip.rowItem || parent
      if (!row) return 0
      var below = row.height + tip.gap
      var above = -tip.implicitHeight - tip.gap
      var vp = tip.viewport
      if (!vp || !vp.contentItem) return below
      var contentSpaceBottom = row.mapToItem(vp.contentItem, 0, row.height).y
      var visibleBottom = vp.contentY + vp.height
      var spaceBelow = visibleBottom - contentSpaceBottom
      if (spaceBelow >= tip.implicitHeight + tip.gap) return below
      // Not enough room below. Opening above is only safe when this is
      // NOT a section's first row -- see `firstInSection`'s own comment.
      if (!tip.firstInSection) {
        var contentSpaceTop = row.mapToItem(vp.contentItem, 0, 0).y
        var spaceAbove = contentSpaceTop - vp.contentY
        if (spaceAbove >= tip.implicitHeight + tip.gap) return above
      }
      // Neither a safe "above" nor a fitting "below" -- below is the
      // lesser evil (never re-collides with a header, matching the v1
      // fix's own guarantee) and never worse than the fix it replaces.
      return below
    }

    background: BorderSurface {
      color: Color.tooltip.background
      borderSpec: Border.flat(Color.tooltip.border, Style.normalBorderWidth)
      radius: Style.cornerRadius
    }

    contentItem: Text {
      text: tip.text
      textFormat: Text.PlainText
      elide: Text.ElideRight
      width: Math.min(implicitWidth, tip.maxWidth)
      color: Color.tooltip.text
      font.family: tip.fontFamily
      font.pixelSize: Style.font.bodySmall
      padding: Style.spacing.controlPaddingX
    }
  }

  // One unread notification: title (+ right-aligned relative age), then
  // "[owner pill] repo · reason".
  component NotificationRow: Item {
    id: notifRow
    property var item: null
    implicitHeight: notifCol.implicitHeight + Style.space(10)

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: notifArea.containsMouse ? Style.hoverFillFor(root.foreground, Color.accent, root.urgent) : "transparent"
    }

    Column {
      id: notifCol
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(2)

      // Title line: title elides against the right-aligned age caption.
      Item {
        width: parent.width
        height: Math.max(notifTitle.implicitHeight, notifAge.implicitHeight)

        Text {
          id: notifAge
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: notifRow.item ? Model.relativeTime(notifRow.item.updatedAt, root.nowMs) : ""
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          id: notifTitle
          anchors.left: parent.left
          anchors.right: notifAge.left
          anchors.rightMargin: Style.space(6)
          anchors.verticalCenter: parent.verticalCenter
          text: notifRow.item ? notifRow.item.title : ""
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }
      }

      // Subtitle line: optional owner pill (external rows only), then
      // "repo · reason".
      Item {
        width: parent.width
        height: Math.max(notifSubtitle.implicitHeight, notifOwnerPill.implicitHeight)

        InlinePill {
          id: notifOwnerPill
          visible: !!(notifRow.item && notifRow.item.isExternal)
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          label: notifRow.item ? notifRow.item.owner : ""
        }

        Text {
          id: notifSubtitle
          anchors.left: notifOwnerPill.visible ? notifOwnerPill.right : parent.left
          anchors.leftMargin: notifOwnerPill.visible ? Style.space(6) : 0
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: notifRow.item
            ? (root.shortRepoName(notifRow.item.repo) + "  ·  " + root.reasonLabel(notifRow.item.reason))
            : ""
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }

    MouseArea {
      id: notifArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.openItem(notifRow.item ? notifRow.item.webUrl : "")
    }
  }

  // One review request: title (+ right-aligned relative age), then
  // "[owner pill] repo #number".
  component ReviewRequestRow: Item {
    id: rrRow
    property var item: null
    // True for this section's first row (set by the Repeater from its own
    // `index`) -- SafeToolTip's y binding never opens above when this is
    // true, since "above" for a first row always means the section header.
    property bool firstInSection: false
    implicitHeight: rrCol.implicitHeight + Style.space(10)

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: rrArea.containsMouse ? Style.hoverFillFor(root.foreground, Color.accent, root.urgent) : "transparent"
    }

    Column {
      id: rrCol
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(2)

      Item {
        width: parent.width
        height: Math.max(rrTitle.implicitHeight, rrAge.implicitHeight)

        Text {
          id: rrAge
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: rrRow.item ? Model.relativeTime(rrRow.item.updatedAt, root.nowMs) : ""
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          id: rrTitle
          anchors.left: parent.left
          anchors.right: rrAge.left
          anchors.rightMargin: Style.space(6)
          anchors.verticalCenter: parent.verticalCenter
          text: rrRow.item ? rrRow.item.title : ""
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }
      }

      Item {
        width: parent.width
        height: Math.max(rrSubtitle.implicitHeight, rrOwnerPill.implicitHeight)

        InlinePill {
          id: rrOwnerPill
          visible: !!(rrRow.item && rrRow.item.isExternal)
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          label: rrRow.item ? rrRow.item.owner : ""
        }

        Text {
          id: rrSubtitle
          anchors.left: rrOwnerPill.visible ? rrOwnerPill.right : parent.left
          anchors.leftMargin: rrOwnerPill.visible ? Style.space(6) : 0
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: rrRow.item ? (root.shortRepoName(rrRow.item.repo) + " #" + rrRow.item.number) : ""
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }

    MouseArea {
      id: rrArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.openItem(rrRow.item ? rrRow.item.webUrl : "")
    }

    // "last comment: <login> · <age>", omitted entirely when there is
    // no lastCommenter.
    SafeToolTip {
      visible: rrArea.containsMouse && root.commentTooltip(rrRow.item) !== ""
      text: root.commentTooltip(rrRow.item)
      fontFamily: root.fontFamily
      viewport: panelFlick
      rowItem: rrRow
      firstInSection: rrRow.firstInSection
    }
  }

  // One open PR: title (+ draft marker, + right-aligned relative age),
  // "[owner pill] repo #number · review decision", CI rollup glyph pinned
  // to the trailing edge.
  component PrRow: Item {
    id: prRow
    property var item: null
    // See ReviewRequestRow's own comment above.
    property bool firstInSection: false
    implicitHeight: Math.max(prCol.implicitHeight, prGlyph.implicitHeight) + Style.space(10)

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: prArea.containsMouse ? Style.hoverFillFor(root.foreground, Color.accent, root.urgent) : "transparent"
    }

    Text {
      id: prGlyph
      text: root.ciGlyph(prRow.item ? prRow.item.ciState : "none")
      textFormat: Text.PlainText
      color: root.ciColor(prRow.item ? prRow.item.ciState : "none")
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: true
      anchors.right: parent.right
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
    }

    Column {
      id: prCol
      anchors.left: parent.left
      anchors.right: prGlyph.left
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(2)

      Item {
        width: parent.width
        height: Math.max(prTitle.implicitHeight, prAge.implicitHeight)

        Text {
          id: prAge
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: prRow.item ? Model.relativeTime(prRow.item.updatedAt, root.nowMs) : ""
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          id: prTitle
          anchors.left: parent.left
          anchors.right: prAge.left
          anchors.rightMargin: Style.space(6)
          anchors.verticalCenter: parent.verticalCenter
          text: prRow.item ? ((prRow.item.isDraft ? "[Draft] " : "") + prRow.item.title) : ""
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }
      }

      Item {
        width: parent.width
        height: Math.max(prSubtitle.implicitHeight, prOwnerPill.implicitHeight)

        InlinePill {
          id: prOwnerPill
          visible: !!(prRow.item && prRow.item.isExternal)
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          label: prRow.item ? prRow.item.owner : ""
        }

        Text {
          id: prSubtitle
          anchors.left: prOwnerPill.visible ? prOwnerPill.right : parent.left
          anchors.leftMargin: prOwnerPill.visible ? Style.space(6) : 0
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: {
            if (!prRow.item) return ""
            var label = root.reviewDecisionLabel(prRow.item.reviewDecision)
            return root.shortRepoName(prRow.item.repo) + " #" + prRow.item.number + (label ? "  ·  " + label : "")
          }
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }

    MouseArea {
      id: prArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.openItem(prRow.item ? prRow.item.webUrl : "")
    }

    // "last comment: <login> · <age>", omitted entirely when there is
    // no lastCommenter.
    SafeToolTip {
      visible: prArea.containsMouse && root.commentTooltip(prRow.item) !== ""
      text: root.commentTooltip(prRow.item)
      fontFamily: root.fontFamily
      viewport: panelFlick
      rowItem: prRow
      firstInSection: prRow.firstInSection
    }
  }

  // One issue the user themselves opened: title (+ right-aligned relative
  // age), then "[owner pill] repo #number". Same shape as PrRow minus the
  // CI glyph and draft marker -- issues have neither.
  component IssueRow: Item {
    id: issueRow
    property var item: null
    // See ReviewRequestRow's own comment above.
    property bool firstInSection: false
    implicitHeight: issueCol.implicitHeight + Style.space(10)

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: issueArea.containsMouse ? Style.hoverFillFor(root.foreground, Color.accent, root.urgent) : "transparent"
    }

    Column {
      id: issueCol
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(2)

      Item {
        width: parent.width
        height: Math.max(issueTitle.implicitHeight, issueAge.implicitHeight)

        Text {
          id: issueAge
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: issueRow.item ? Model.relativeTime(issueRow.item.updatedAt, root.nowMs) : ""
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          id: issueTitle
          anchors.left: parent.left
          anchors.right: issueAge.left
          anchors.rightMargin: Style.space(6)
          anchors.verticalCenter: parent.verticalCenter
          text: issueRow.item ? issueRow.item.title : ""
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }
      }

      Item {
        width: parent.width
        height: Math.max(issueSubtitle.implicitHeight, issueOwnerPill.implicitHeight)

        InlinePill {
          id: issueOwnerPill
          visible: !!(issueRow.item && issueRow.item.isExternal)
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          label: issueRow.item ? issueRow.item.owner : ""
        }

        Text {
          id: issueSubtitle
          anchors.left: issueOwnerPill.visible ? issueOwnerPill.right : parent.left
          anchors.leftMargin: issueOwnerPill.visible ? Style.space(6) : 0
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: issueRow.item ? (root.shortRepoName(issueRow.item.repo) + " #" + issueRow.item.number) : ""
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }

    MouseArea {
      id: issueArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.openItem(issueRow.item ? issueRow.item.webUrl : "")
    }

    // "last comment: <login> · <age>", omitted entirely when there is
    // no lastCommenter.
    SafeToolTip {
      visible: issueArea.containsMouse && root.commentTooltip(issueRow.item) !== ""
      text: root.commentTooltip(issueRow.item)
      fontFamily: root.fontFamily
      viewport: panelFlick
      rowItem: issueRow
      firstInSection: issueRow.firstInSection
    }
  }

  // One owned repo: name (+ release-tag pill when present), then
  // "pushed <relative> · N issues · M PRs". Hover tooltip carries the
  // default-branch commit headline via SafeToolTip, never PanelToolTip.
  component RepoRow: Item {
    id: repoRow
    property var item: null
    // See ReviewRequestRow's own comment above.
    property bool firstInSection: false
    implicitHeight: repoCol.implicitHeight + Style.space(10)

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: repoArea.containsMouse ? Style.hoverFillFor(root.foreground, Color.accent, root.urgent) : "transparent"
    }

    Column {
      id: repoCol
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(2)

      Row {
        id: repoNameRow
        width: parent.width
        spacing: Style.space(6)

        Text {
          id: repoNameText
          text: repoRow.item ? repoRow.item.name : ""
          textFormat: Text.PlainText
          elide: Text.ElideRight
          width: Math.max(0, Math.min(implicitWidth, parent.width
            - (statusPill.visible ? statusPill.implicitWidth + Style.space(6) : 0)
            - (releasePill.visible ? releasePill.implicitWidth + Style.space(6) : 0)))
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        // Repo status pill (archived/fork/private, one max -- see
        // Model.repoPill's priority order), GitHub's own "Public archive"
        // look via kit tokens only, no raw hex.
        InlinePill {
          id: statusPill
          property string kind: (repoRow.item && typeof Model.repoPill === "function")
            ? String(Model.repoPill(repoRow.item) || "") : ""
          visible: kind !== ""
          anchors.verticalCenter: parent.verticalCenter
          label: kind
        }

        BorderSurface {
          id: releasePill
          visible: !!(repoRow.item && repoRow.item.releaseTag)
          // A release tag is remote-derived and still wide enough to
          // stretch the row even at its 100-char cap; capped the same way
          // InlinePill caps its own text.
          property real maxTextWidth: Style.space(72)
          implicitWidth: Math.min(releaseText.implicitWidth, releasePill.maxTextWidth) + Style.space(10)
          implicitHeight: releaseText.implicitHeight + Style.space(4)
          anchors.verticalCenter: parent.verticalCenter
          color: "transparent"
          borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)
          radius: Style.cornerRadius

          Text {
            id: releaseText
            anchors.centerIn: parent
            text: repoRow.item ? repoRow.item.releaseTag : ""
            textFormat: Text.PlainText
            elide: Text.ElideRight
            width: Math.min(implicitWidth, releasePill.maxTextWidth)
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }

      Text {
        width: parent.width
        text: repoRow.item
          ? ("pushed " + Model.relativeTime(repoRow.item.pushedAt, root.nowMs) + "  ·  " + repoRow.item.openIssues + " issues  ·  " + repoRow.item.openPRs + " PRs")
          : ""
        textFormat: Text.PlainText
        elide: Text.ElideRight
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    MouseArea {
      id: repoArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.openItem(repoRow.item ? repoRow.item.url : "")
    }

    SafeToolTip {
      visible: repoArea.containsMouse && !!repoRow.item && repoRow.item.lastCommitHeadline !== ""
      text: repoRow.item ? repoRow.item.lastCommitHeadline : ""
      fontFamily: root.fontFamily
      viewport: panelFlick
      rowItem: repoRow
      firstInSection: repoRow.firstInSection
    }
  }
}
