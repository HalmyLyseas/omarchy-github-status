// Panel.qml -- the popup for halmylyseas.github-status.
//
// Panel + KeyboardPanel per exchange/03-shell-api.md §5. Single scrollable
// column: Hero (title/status/refresh), Inbox, Review requests, My open PRs,
// My open issues, Repositories -- section order per 06-design.md "What v1
// does" (review requests before own PRs: other people blocked on the user
// outrank the user's own backlog) amended by
// exchange/19-feedback-delta-spec.md F3 (issues section inserted after PRs).
// "Repositories" was "Repo activity" through v1.2; renamed by
// exchange/33-feedback3-delta-spec.md H3 (see the v1.3 delta note below).
//
// v1.1 delta (exchange/19-feedback-delta-spec.md, S9 side, F1/F2/F3/F4/F5/F6):
//   - every section header is the new SectionHeader.qml: label + a
//     right-aligned count pill ("…" pre-sync). Empty+synced sections render
//     only that header row now -- the old "Inbox zero"/"No review
//     requests"/etc. placeholder rows are gone (F4).
//   - Inbox / Review requests / My PRs / My issues rows gained a
//     right-aligned muted relative-age caption on the title line, and an
//     outlined owner pill on the subtitle line for isExternal rows (F5/F6).
//   - Repo rows gained Model.repoPill() (archived/fork/private) next to the
//     repo name (F2), and the Repo activity header gained a compact
//     recent/stars sort toggle wired to svc.repoSort/setRepoSort (F1).
//   - New "MY OPEN ISSUES" section (svc.myIssues) between My PRs and Repo
//     activity (F3).
//
// S12 fix (exchange/23-s11-delta-review.md F1): each SectionHeader's
// "synced" is now sourced per-section (root.notifSynced for Inbox,
// root.dashboardSynced for the other four) instead of one blended
// root.synced -- see those properties' own header comment below.
//
// v1.2 delta (exchange/26-feedback2-delta-spec.md, S14 side, G1/G2/G3/G4):
//   - G1: a TextField search row sits directly under the hero
//     (`searchRow`/`searchField`). `root.searchQuery` is ephemeral (reset
//     every time the panel opens, see onOpenedChanged) and live-filters
//     every section's rendered rows through Model.matchesQuery (guarded --
//     see `itemMatchesQuery`/`filterList`). Focus model: the field is NOT
//     auto-focused on open (a click engages it, exactly like the
//     wifi/network panel's inline passphrase prompt) -- see `searchField`'s
//     own comment for the full rationale. While it holds focus,
//     PanelKeyCatcher is `blocked` so typing (including vim letters
//     j/k/h/l/x, which the key catcher would otherwise steal as
//     scroll/delete keys -- "Nujabes" itself contains a "j") reaches the
//     field untouched. Esc: first press clears a non-empty query, second
//     press (query already empty) closes the panel, both handled locally by
//     the field's own Keys.onEscapePressed -- no change to PanelKeyCatcher
//     itself needed. A section's count pill during an active search always
//     shows the FILTERED (rendered) length; "every section shows zero
//     matches" deliberately gets no special full-panel message -- it just
//     reads as five zero-pill headers, the same presentation an
//     empty-and-synced section already had pre-G1 (see `filterList`).
//   - G2: PrRow/ReviewRequestRow/IssueRow (not NotificationRow -- the
//     contract only adds lastCommenter/lastCommentAt to
//     openPRs/reviewRequests/myIssues) each gained a SafeToolTip via
//     `commentTooltip(item)`, shown only when item.lastCommenter is
//     non-empty.
//   - G3: each section's Repeater is now wrapped in an inner Column gated
//     on a new per-section `xCollapsed` property (session-only -- reset on
//     every panel open, same as searchQuery) so Column's positioner
//     excludes it from layout entirely while folded (no stray gap).
//     SectionHeader itself owns the click/hover surface and chevron; see
//     its own header comment for the hit-area-separation geometry.
//   - G4: the My open issues header gained a Focus/All ButtonGroup in its
//     `extra` slot, byte-for-byte the same idiom as the (now-removed, see
//     v1.3 below) Repo activity header's F1 sort toggle, wired to
//     svc.issuesFilter/setIssuesFilter. svc.myIssues is already the
//     post-filter list (Service.qml's job) -- this file does not re-filter
//     by `subscribed` itself, only by search on top of whatever
//     svc.myIssues already returned.
//
// v1.3 delta (exchange/33-feedback3-delta-spec.md, S18 side, H1/H2/H3):
//   - H1: the G4 Focus/All ButtonGroup above became a single "Subscribed"
//     toggle chip (one Button, `selected` <=> issuesFilter === "focus") --
//     UI-only reshape, svc.issuesFilter/setIssuesFilter and their
//     persistence are untouched.
//   - H2: SafeToolTip's default (style-provided) "open above the hovered
//     row" position collided with whatever sat directly above -- the
//     section header itself for a section's first row (reported as a
//     "detached" tooltip), a neighboring row's text otherwise. Fixed by
//     opening below the row instead; see SafeToolTip's own header comment
//     for the full diagnosis and exchange/34-s18-implementation.md for the
//     repro/proof. (The "hovering a row does nothing" half of the same
//     report turned out to be correct, spec-compliant behavior -- that
//     row's real GitHub issue genuinely has zero comments.)
//   - H3: "Repo activity" is now "Repositories"; its F1 recent/stars sort
//     toggle is removed entirely (not just hidden), along with
//     svc.repoSort/setRepoSort and Model.sortRepos (Service.qml/Model.js's
//     side of this). Repos render in fetch order (GraphQL PUSHED_AT desc)
//     sliced by repoLimit -- see root.repos below.
//
// v1.3.1 delta (exchange/38-feedback4-delta-spec.md, S21 side, I1a/I1b):
//   - I1a: the H1 "Subscribed" toggle chip's own label now follows its
//     state instead of staying fixed -- see the chip's own comment below
//     for the exact rule and the width-reflow decision.
//
// This file codes only against the Service public API contract -- the v1
// surface frozen in 06-design.md, plus the v1.1 additions specified in
// 19-feedback-delta-spec.md (S8 owns landing them in Service.qml/Model.js).
// Every read of `svc.*`/`Model.*` is null-guarded and every list defaults to
// [] before use, because the service may not have resolved yet on first
// paint (§3), its data can legitimately be empty, and -- during the parallel
// S8/S9 delta -- the new fields/functions may not have landed yet either; in
// every one of those cases this file degrades to empty lists/no pill, never
// a crash.
//
// Security invariants carried through from 06-design.md, non-negotiable:
//   - every Text rendering a GitHub-controlled string sets
//     textFormat: Text.PlainText + elide, and is width-constrained.
//   - PanelToolTip's own Text does NOT set Text.PlainText (it is a
//     first-party read-only component), so remote-derived tooltip content
//     (the repo row's lastCommitHeadline) is never routed through it --
//     `SafeToolTip` below is a drop-in replacement that forces PlainText.
//   - every click-to-open goes through svc.openUrl(...) only -- never
//     bar.run/xdg-open/Quickshell.execDetached from this file. openUrl
//     itself allowlists https://github.com/ and spawns array-form
//     (Service.qml's job, not this file's).
import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "halmylyseas.github-status"
  ipcTarget: "halmylyseas.github-status"

  // Handed over by BarWidget.injectPanel().
  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property var shell: bar && bar.shell ? bar.shell : null
  readonly property var svc: shell ? shell.serviceFor("halmylyseas.github-status") : null

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color muted: Color.muted
  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  // Relative-time labels read this instead of Date.now() so a panel left
  // open keeps counting up ("3m" -> "4m") while the user is looking at it,
  // matching the agents-plugin precedent (Panel.qml `nowMs`).
  property double nowMs: Date.now()

  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  // G1: query text typed into `searchField`. Ephemeral by design (spec:
  // "resets when panel closes") -- reset below, on open rather than on
  // close, so a panel instance that stays alive in memory between
  // open/close cycles (the norm for this kit's Panel/KeyboardPanel) never
  // shows a stale query from a previous session for even one frame.
  property string searchQuery: ""
  readonly property bool searchActive: root.searchQuery.trim() !== ""

  // G3: per-section fold state, session-only (spec: "NOT persisted; resets
  // on panel reload") -- same reset-on-open treatment as searchQuery, same
  // reasoning.
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

  // G1: Model.matchesQuery(item, query) is the data-layer's contract
  // (exchange/26-feedback2-delta-spec.md); guarded exactly like every other
  // cross-owner Model.* read in this file (e.g. Model.repoPill below) so a
  // moment where Model.js hasn't landed the function yet degrades to "show
  // everything unfiltered", never a crash.
  function itemMatchesQuery(item) {
    if (!root.searchActive) return true
    return (typeof Model.matchesQuery === "function") ? Model.matchesQuery(item, root.searchQuery) : true
  }

  // Pure client-side narrowing of an already-fetched list -- never a new
  // remote read. Returns the SAME array reference when no query is active
  // (the common case) so this costs nothing extra when the user isn't
  // searching.
  function filterList(list) {
    if (!root.searchActive) return list
    var out = []
    for (var i = 0; i < list.length; i++) {
      if (root.itemMatchesQuery(list[i])) out.push(list[i])
    }
    return out
  }

  // ---------------------------------------------------------------- data
  //
  // Every list defaults to [] and every item access below is guarded --
  // svc can be null on first paint, and a degraded service (no-gh,
  // unauthenticated, offline) legitimately reports empty/last-good lists.

  readonly property var allNotifications: svc && svc.notifications ? svc.notifications : []
  // "Inbox" per 06-design.md is unread notifications specifically; filtered
  // here rather than assumed pre-filtered, so this panel is correct even if
  // the service ever starts returning read ones too.
  readonly property var unreadNotifications: {
    var out = []
    for (var i = 0; i < allNotifications.length; i++) {
      if (allNotifications[i] && allNotifications[i].unread === true) out.push(allNotifications[i])
    }
    return out
  }
  readonly property var reviewRequests: svc && svc.reviewRequests ? svc.reviewRequests : []
  readonly property var openPRs: svc && svc.openPRs ? svc.openPRs : []
  // G4: svc.myIssues is already post-subscribed-filter (Service.qml's job,
  // same ownership split repos has for its own read-time slice) -- this is
  // the shown set before G1 search narrows it further below.
  readonly property var myIssues: svc && svc.myIssues ? svc.myIssues : []
  readonly property var repos: svc && svc.repos ? svc.repos : []

  // G1: the rendered (search-filtered) list each Repeater below actually
  // binds to. Identical to the un-filtered list above when no query is
  // active.
  readonly property var filteredNotifications: root.filterList(root.unreadNotifications)
  readonly property var filteredReviewRequests: root.filterList(root.reviewRequests)
  readonly property var filteredOpenPRs: root.filterList(root.openPRs)
  readonly property var filteredMyIssues: root.filterList(root.myIssues)
  readonly property var filteredRepos: root.filterList(root.repos)

  // "…" pill state (F4/SectionHeader) -- per-source, NOT the blended
  // svc.lastSyncMs (exchange/23-s11-delta-review.md F1): both pollers fire
  // on essentially every cold start in the same JS tick, and race
  // independently. Gating every section on whichever one happens to finish
  // first meant up to four sections could show a false confirmed-"0" (their
  // own backing arrays still empty) the instant the OTHER poller won the
  // race. Inbox is backed by the notifications poller only; Review
  // requests/My PRs/My issues/Repositories are all backed by the single
  // combined dashboard fetch. A null svc is "not synced" on both, same as
  // before.
  readonly property bool dashboardSynced: !!svc && Number(svc.dashboardLastSyncMs) !== 0
  readonly property bool notifSynced: !!svc && Number(svc.notificationsLastSyncMs) !== 0

  // G4/H1: mirror-property + setter shape against the Service.qml contract
  // (issuesFilter "focus"|"all" default "focus", setIssuesFilter(mode)) --
  // H1 (exchange/33-feedback3-delta-spec.md) only reshaped the UI (the
  // Focus/All ButtonGroup below became a single "Subscribed" toggle chip),
  // the backend/persistence contract here is untouched.
  readonly property string issuesFilter: svc && svc.issuesFilter ? String(svc.issuesFilter) : "focus"

  function setIssuesFilter(mode) {
    if (svc && typeof svc.setIssuesFilter === "function") svc.setIssuesFilter(mode)
  }

  // "owner/repo" -> "repo". Own-vs-external marking (F6) moves the owner out
  // of the repo breadcrumb and into its own pill, so rows need the bare repo
  // name rather than the nameWithOwner string every list item already
  // carries. Pure client-side split of a field the row's Text already plans
  // to render with Text.PlainText -- never a new remote read.
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
    return lastSyncLabel()
  }

  // ---------------------------------------------------- degradation states
  //
  // Shown as a hint block in the hero area, per 06-design.md "Degradation
  // states" -- never a blank/broken panel; last-good data (if any) stays
  // listed in the sections below regardless of this block.

  readonly property bool statusHintSevere: !!svc && (svc.status === "no-gh" || svc.status === "unauthenticated")

  readonly property string statusHint: {
    if (!svc) return ""
    switch (svc.status) {
      case "no-gh": return "GitHub CLI (gh) not found. Install it from https://cli.github.com/."
      case "unauthenticated": return "Not signed in — run \"gh auth login\" in a terminal."
      case "offline": return "Offline — showing last-known data."
      case "rate-limited": {
        var until = svc.rateLimitedUntil
        return "Rate-limited — resuming" + (until ? " at " + until : " shortly") + ". Showing last-known data."
      }
      default: return ""
    }
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

  // Mapped from GitHub's fixed reviewDecision enum to a short label -- not a
  // raw pass-through of remote text, so this alone would not need
  // Text.PlainText, but every Text using it still sets it as a matter of
  // policy (the string ultimately traces back to the API response).
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

  // ------------------------------------------------------------ G2 tooltip
  //
  // "last comment: <login> · <relative age>" -- item.lastCommenter/
  // lastCommentAt are the exchange/26-feedback2-delta-spec.md contract
  // fields on openPRs/reviewRequests/myIssues rows (not present on
  // notifications or repos). "" whenever lastCommenter is empty/missing --
  // the caller (each row's SafeToolTip) treats "" as "no tooltip at all",
  // per spec ("omit the line entirely when \"\""). Defensive on a
  // not-yet-landed field the same way every other cross-owner read in this
  // file is: `item.lastCommenter` on an object that doesn't have the field
  // yet is simply `undefined`, which the falsy check below already treats
  // as "no tooltip".
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
      // G1: while the search field holds focus, it owns every key --
      // PanelKeyCatcher's own header comment prescribes exactly this
      // `blocked: editor.activeFocus` shape (the wifi/network panel's
      // passphrase-prompt precedent uses the identical idiom), so vim
      // letters typed into a query (j/k/h/l/x -- "Nujabes" itself has a
      // "j") never get stolen as scroll/delete keys.
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

          // -------------------------------------------------- search (G1)
          //
          // Focus model decision: the field is NOT auto-focused when the
          // panel opens. KeyboardPanel already force-focuses `keyCatcher`
          // itself on every open (its own `focusTarget` mechanism, via
          // Qt.callLater -- see KeyboardPanel.qml), and racing a second
          // Qt.callLater(searchField.forceActiveFocus) against that from
          // here would depend on undocumented callLater ordering between
          // two independent onOpenChanged handlers (root's and
          // KeyboardPanel's own). Rather than fight the kit's own focus
          // management, this follows the closest first-party precedent
          // for an inline text editor living inside a KeyboardPanel: the
          // network plugin's wifi passphrase prompt (only ever focused by
          // an explicit user action -- clicking a row -- never on panel
          // open). Landing here: the panel opens exactly like every other
          // panel (keyCatcher owns focus, Tab/Esc/j-k-scroll all work
          // immediately); a single click into this field is what engages
          // search, at which point PanelKeyCatcher yields via `blocked`
          // above. image-picker's `filterable` mode was the other
          // candidate idiom (type-to-filter with no visible focused
          // widget, via its own dedicated Keys.onPressed) but it depends
          // on that panel never using j/k/h/l for anything else -- this
          // panel already binds j/k (and, structurally, h/l) to scroll via
          // PanelKeyCatcher, so routing raw keystrokes into the query
          // through the same generic textKey channel would silently eat
          // any query letter that collides with a vim key ("Nujabes" has a
          // "j") before it ever reached the filter. A real, focusable
          // TextField sidesteps that collision entirely.
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
              // Mirrors Model.matchesQuery's own ~100-char query cap
              // (exchange/26-feedback2-delta-spec.md) so a pathologically
              // long paste never even reaches the filter as a long string
              // in the first place.
              maximumLength: 100
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              foreground: root.foreground

              // Field owns `text`; root.searchQuery just mirrors it. Every
              // place that clears the query from OUTSIDE the field (the
              // ✕ glyph, Esc below, panel close) sets `searchField.text`
              // imperatively too, rather than relying on a `text: ...`
              // binding that QML would silently drop the first time the
              // user types (a real TextInput/TextField gotcha -- typing
              // reassigns `text` imperatively, which permanently breaks a
              // declarative `text: root.searchQuery` binding).
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

            // Clear affordance for mouse users (spec: "Esc clears search
            // first, second Esc closes panel -- if feasible ... otherwise
            // an ✕ button"); kept alongside the Esc handling above rather
            // than instead of it, since both are cheap and serve different
            // input styles.
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
              // Inbox pill: the service's own unread count when not
              // searching (F4's original source -- the two should agree,
              // but unreadCount is the spec-called-out authority), the
              // filtered rendered length while a G1 query is active (so
              // the pill reflects what's actually on screen, matching
              // every other section).
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
          // F3: issues the user themselves opened, any repo -- distinct from
          // review requests (PRs waiting on the user) and own PRs (the
          // user's own PR backlog).
          //
          // exchange/33-feedback3-delta-spec.md H1: the old Focus/All
          // two-option ButtonGroup is now a single "Subscribed" toggle
          // chip -- UI-only reshape, the backend contract underneath
          // (svc.issuesFilter "focus"|"all", svc.setIssuesFilter(mode),
          // persistence) is untouched (see root.issuesFilter/
          // setIssuesFilter above, still exactly the G4 mirror-property
          // shape). Chip active (selected fill) <=> issuesFilter ===
          // "focus" (only subscribed issues shown, the default); clicking
          // it flips to the other mode. Same visual idiom the removed F1
          // repo-sort/G4 issues ButtonGroup used for its own chips --
          // this is literally one of that ButtonGroup's own Button
          // delegates, instantiated directly, since there's now only one
          // option to show.
          Column {
            width: parent.width
            spacing: Style.space(4)

            SectionHeader {
              text: "MY OPEN ISSUES"
              count: root.filteredMyIssues.length
              synced: root.dashboardSynced
              collapsed: root.myIssuesCollapsed
              foreground: root.foreground
              fontFamily: root.fontFamily
              onToggled: root.myIssuesCollapsed = !root.myIssuesCollapsed
              // exchange/38-feedback4-delta-spec.md I1a/I1b: the chip's
              // label now follows its own state instead of a fixed
              // "Subscribed" -- active (issuesFilter === "focus") reads
              // "subscribed", inactive reads "all". Lowercase is the
              // interim casing per I1b (precedent: the removed F1
              // repo-sort toggle's "recent"/"stars" was lowercase too;
              // section headers themselves own the uppercase register).
              // Text.PlainText doesn't apply here the way it does to
              // remote-data Text elements (see file-wide policy) -- both
              // strings are local literals, never user/network data, so
              // there's nothing to sanitize; Button's own Text delegates
              // don't expose textFormat as an overridable property anyway
              // (framework file, not ours to touch).
              //
              // Width: deliberately NOT pinned to the longer label.
              // `trailing` (SectionHeader.qml) right-anchors this chip
              // and the count pill as a Row, so a width change here only
              // moves the chip's own left edge and the fold-hover
              // boundary (`trailing.x`-derived, already reactive) --
              // nothing else in the header shifts or overlaps. Given
              // that, a fixed-width reservation would just be unused
              // complexity for a two-word toggle; reflow is accepted.
              extra: Component {
                Button {
                  anchors.verticalCenter: parent ? parent.verticalCenter : undefined
                  text: root.issuesFilter === "focus" ? "subscribed" : "all"
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
          // exchange/33-feedback3-delta-spec.md H3: "Repo Activity" ->
          // "Repositories"; the F1 recent/stars sort toggle is removed
          // entirely (not just hidden) -- search plus the default
          // last-activity order are enough, and it's one less control to
          // scan. Repos render in fetch order (GraphQL PUSHED_AT desc,
          // scripts/fetch-dashboard's own query order) sliced by
          // repoLimit -- see root.repos below, no client-side sort layer
          // left over this delta.
          Column {
            width: parent.width
            spacing: Style.space(4)

            SectionHeader {
              text: "REPOSITORIES"
              count: root.filteredRepos.length
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

  // NOTE: the old EmptyRow placeholder ("Inbox zero" / "No review
  // requests" / ...) is gone per exchange/19-feedback-delta-spec.md F4 --
  // an empty, synced section now renders only its SectionHeader (the count
  // pill reads "0"), no body row at all.

  // Small outlined pill used by both F2 (repo status: archived/fork/
  // private) and F6 (external-repo owner marking) -- same visual language
  // as GitHub's own "Public archive" pill (exchange/18-human-feedback.md
  // screenshot), built entirely from kit tokens (no raw hex). `maxWidth`
  // caps the pill's *text*, not the pill itself, so a long owner login
  // still elides instead of stretching the row.
  component InlinePill: BorderSurface {
    id: pill
    property string label: ""
    // ~12 characters at caption size -- exchange/19-feedback-delta-spec.md
    // F6's "elided ≤ ~12ch max width" for the owner pill. Approximated in
    // px (a fixed character count isn't directly expressible against a
    // proportional or user-substituted font) rather than measured exactly;
    // F2's repo-status labels ("archived"/"fork"/"private") are all well
    // under this cap so they never actually elide against it.
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

  // Drop-in replacement for qs.Ui.PanelToolTip that forces
  // textFormat: Text.PlainText on its content -- PanelToolTip's own Text
  // does not set that, so any GitHub-controlled string (e.g. a commit
  // headline) must go through this instead, never through PanelToolTip
  // directly.
  //
  // exchange/33-feedback3-delta-spec.md H2 fix, v1 (diagnosed + proven in
  // exchange/34-s18-implementation.md): the active QQC2 style's default
  // ToolTip position
  // (/usr/lib/qt6/qml/QtQuick/Controls/Basic/ToolTip.qml:12-13) opens the
  // popup ABOVE its `parent` (`y: -implicitHeight - 3`). `parent` IS
  // correctly the individual hovered row (verified live -- each
  // instance's parent is that row's own Item, never shared/mis-anchored,
  // ruling out the "shared tooltip instance" theory). v1 changed this to
  // always open BELOW the row instead.
  //
  // exchange/35-s19-delta-review.md F1/F2 (S20 flip-to-fit fix): always-
  // below just relocated the collision, in two ways -- (F1) for any row
  // followed by another row in the same section (the common case), the
  // ~35px-tall tooltip landed mostly on top of the NEXT row's own text
  // (Style.space(4), ~4px, separates rows -- nowhere near enough
  // clearance); (F2) for the last row of the last section, the tooltip's
  // bottom could land past the panel card's own bottom edge -- QQC2
  // Popups render via the top-level Overlay, not as a normal child of
  // this item tree, so they ignore every ancestor's `clip` (confirmed by
  // reading BorderSurface/KeyboardPanel.qml -- neither clips) and paint
  // straight onto the transparent full-screen layer-shell window behind
  // the visible card.
  //
  // Fix: flip-to-fit against the panel's own scrollable viewport
  // (`viewport`, set explicitly by each of the 4 call sites to
  // `panelFlick` -- a plain property, not a parent-chain walk, so this
  // component stays decoupled from exactly where in the tree it's
  // instantiated, per the PM's explicit "pass the geometry, don't walk
  // parents" instruction). Below stays the default (it never re-collides
  // with a header, the original H2 complaint); only when the row sits
  // close enough to the viewport's own visible bottom edge that the
  // tooltip would cross it does it open ABOVE instead (falling back to
  // below only if THAT would also cross the viewport's top -- a
  // scrolled-boundary edge case, never observed live but cheap to guard,
  // and never worse than the v1 always-below fix it replaces). See
  // exchange/36-s20-release.md for the proof (rows 1/middle/last,
  // scrolled and unscrolled).
  component SafeToolTip: ToolTip {
    id: tip
    property string fontFamily: Style.font.family
    // Width cap (G2 audit: "PlainText+elide+width-capped" on every new
    // sink) -- applies retroactively to the pre-existing repo-row tooltip
    // too, since both share this one component. A commit headline or a
    // "last comment: <login> · <age>" line could otherwise stretch the
    // popup arbitrarily wide against a pathological remote string; elide
    // alone bounds render cost but not layout width.
    property real maxWidth: Style.space(320)
    // S20 flip-to-fit input (exchange/35 F1/F2): the Flickable whose
    // visible (clipped) viewport bounds the tooltip's allowed vertical
    // range. Set explicitly by each call site -- null-safe, falling back
    // to the old always-below placement if ever left unset. Typed as
    // Flickable (not a generic Item) so contentItem/contentY below resolve
    // statically instead of adding to the missing-property baseline.
    property Flickable viewport: null
    // S20 flip-to-fit input: an explicit reference to this tooltip's own
    // hovered row, set by each call site to its own row id (e.g.
    // `rowItem: issueRow`). Deliberately NOT read via the bare `parent`
    // property from inside this y binding's JS function body -- measured
    // live (S20 probe harness, .../scratchpad/probe-s20/) that
    // `parent.mapToItem(...)`/`parent.mapToGlobal(...)` called from
    // inside a JS function block here resolves to the SAME single Item's
    // geometry for every one of a Repeater's ~20 delegate instances (a
    // `pragma ComponentBehavior: Bound`-class scoping defect: this file's
    // components aren't declared Bound, a pre-existing, documented
    // condition -- see docs/developers.md's qmllint baseline note). The
    // pre-S20 code never surfaced this because it only ever read
    // `parent.height`, uniform across every row of a given type, so a
    // wrong-but-same-height `parent` was undetectable; this fix reads
    // *position*, which is not uniform, so the latent bug became a real
    // one. An explicit property assigned directly at each call site (a
    // plain per-instance declarative binding, not a JS-function `parent`
    // lookup) sidesteps it entirely -- confirmed correct per-row live.
    property Item rowItem: null
    // S20 flip-to-fit input: true when `rowItem` is its section's first
    // row (set by each call site from `<rowId>.firstInSection`, which the
    // Repeater delegate sets from its own `index === 0`). "Above" for a
    // first row always lands on the SECTION HEADER, not another row --
    // live-reproduced during S20's own deploy-time verification (hovering
    // a section's first row after scrolling flipped the tooltip onto the
    // header, reintroducing the exact defect the v1 H2 fix eliminated).
    // See the y binding below.
    property bool firstInSection: false
    property real gap: Style.space(3)

    delay: 400
    padding: 0
    // S20 flip-to-fit -- see header comment above. Deliberately reads
    // `tip.viewport.contentY` directly (a genuine bindable Flickable
    // property) rather than relying on `mapToItem`/`mapToGlobal` alone to
    // pick up scroll changes: `mapToItem`/`mapToGlobal` are plain
    // synchronous coordinate-transform calls, not bindable properties --
    // QML's automatic dependency tracker does not treat a call to them as
    // depending on `contentY`, so a binding that only calls them (with no
    // *other* changing property read in the same evaluation) silently goes
    // stale on scroll and never re-fires (measured live in the S20 probe
    // harness: the true-last-row case never re-evaluated after its initial
    // below-the-fold layout pass, even though the row's real screen
    // position moved). Mapping against `viewport.contentItem`
    // instead gives a scroll-INVARIANT content-space position (row and
    // contentItem move together, so their relative offset never changes
    // from scrolling alone), and combining that with the directly-read,
    // properly-reactive `contentY`/`height` pair is what makes this
    // binding actually re-run when the Flickable scrolls.
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
  // "[owner pill] repo · reason". F5/F6 per exchange/19-feedback-delta-spec.md.
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

      // Subtitle line: optional owner pill (F6, external rows only), then
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
  // "[owner pill] repo #number". F5/F6 per exchange/19-feedback-delta-spec.md.
  component ReviewRequestRow: Item {
    id: rrRow
    property var item: null
    // S20 flip-to-fit input (exchange/35 F1/F2): true for this section's
    // first row, set by the Repeater call site from its own `index`.
    // SafeToolTip's y binding never opens above when this is true --
    // "above" for a first row always means the SECTION HEADER, not
    // another row, and landing there would reintroduce the original H2
    // bug this whole fix exists to prevent.
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

    // G2: "last comment: <login> · <age>", omitted entirely when there is
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
  // to the trailing edge. F5/F6 per exchange/19-feedback-delta-spec.md.
  component PrRow: Item {
    id: prRow
    property var item: null
    // S20 flip-to-fit input -- see ReviewRequestRow's own comment above.
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

    // G2: "last comment: <login> · <age>", omitted entirely when there is
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

  // One issue the user themselves opened (F3): title (+ right-aligned
  // relative age), then "[owner pill] repo #number". Same shape as PrRow
  // minus the CI glyph and draft marker -- issues have neither.
  component IssueRow: Item {
    id: issueRow
    property var item: null
    // S20 flip-to-fit input -- see ReviewRequestRow's own comment above.
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

    // G2: "last comment: <login> · <age>", omitted entirely when there is
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
  // default-branch commit headline via SafeToolTip (never PanelToolTip --
  // see the component's own comment).
  component RepoRow: Item {
    id: repoRow
    property var item: null
    // S20 flip-to-fit input -- see ReviewRequestRow's own comment above.
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

        // F2: repo status pill (archived/fork/private, one max --
        // Model.repoPill's own priority order) right after the repo name,
        // GitHub's own "Public archive" pill look via kit tokens only --
        // muted outline + foreground/dim text, no raw hex (the kit has no
        // dedicated "archived" semantic color to reach for instead, per
        // exchange/19-feedback-delta-spec.md F2).
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
          implicitWidth: releaseText.implicitWidth + Style.space(10)
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
