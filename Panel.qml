// Panel.qml -- the popup for halmylyseas.github-status.
//
// Panel + KeyboardPanel per exchange/03-shell-api.md §5. Single scrollable
// column: Hero (title/status/refresh), Inbox, Review requests, My open PRs,
// My open issues, Repo activity -- section order per 06-design.md "What v1
// does" (review requests before own PRs: other people blocked on the user
// outrank the user's own backlog) amended by
// exchange/19-feedback-delta-spec.md F3 (issues section inserted after PRs).
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

  onOpenedChanged: if (opened) {
    root.nowMs = Date.now()
    if (panelFlick) panelFlick.contentY = 0
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
  readonly property var myIssues: svc && svc.myIssues ? svc.myIssues : []
  readonly property var repos: svc && svc.repos ? svc.repos : []

  // "…" pill state (F4/SectionHeader) -- svc.lastSyncMs === 0 is the
  // service's own "never synced yet" signal (same one lastSyncLabel() below
  // already reads); a null svc is equally "not synced" from the panel's POV.
  readonly property bool synced: !!svc && Number(svc.lastSyncMs) !== 0

  readonly property string repoSort: svc && svc.repoSort ? String(svc.repoSort) : "activity"

  function setRepoSort(mode) {
    if (svc && typeof svc.setRepoSort === "function") svc.setRepoSort(mode)
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
              // Inbox pill is the service's own unread count, not the
              // rendered list length -- the two should agree, but the
              // spec calls out unreadCount specifically as the source
              // (exchange/19-feedback-delta-spec.md F4).
              count: svc ? (Number(svc.unreadCount) || 0) : 0
              synced: root.synced
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.unreadNotifications

              NotificationRow {
                required property var modelData
                width: parent ? parent.width : 0
                item: modelData
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
              count: root.reviewRequests.length
              synced: root.synced
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.reviewRequests

              ReviewRequestRow {
                required property var modelData
                width: parent ? parent.width : 0
                item: modelData
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
              count: root.openPRs.length
              synced: root.synced
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.openPRs

              PrRow {
                required property var modelData
                width: parent ? parent.width : 0
                item: modelData
              }
            }
          }

          PanelSeparator { foreground: root.foreground }

          // ------------------------------------------------- open issues
          // F3: issues the user themselves opened, any repo -- distinct from
          // review requests (PRs waiting on the user) and open PRs (the
          // user's own PR backlog).
          Column {
            width: parent.width
            spacing: Style.space(4)

            SectionHeader {
              text: "MY OPEN ISSUES"
              count: root.myIssues.length
              synced: root.synced
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.myIssues

              IssueRow {
                required property var modelData
                width: parent ? parent.width : 0
                item: modelData
              }
            }
          }

          PanelSeparator { foreground: root.foreground }

          // ------------------------------------------------- repo activity
          Column {
            width: parent.width
            spacing: Style.space(4)

            SectionHeader {
              text: "REPO ACTIVITY"
              count: root.repos.length
              synced: root.synced
              foreground: root.foreground
              fontFamily: root.fontFamily
              // F1: compact recent/stars sort toggle, left of the count
              // pill. ButtonGroup's value/changed contract maps 1:1 onto
              // svc.repoSort/setRepoSort -- setRepoSort itself validates the
              // mode (Service.qml's job), so this click is a plain pass-
              // through.
              extra: Component {
                ButtonGroup {
                  anchors.verticalCenter: parent ? parent.verticalCenter : undefined
                  options: [
                    { value: "activity", label: "recent" },
                    { value: "stars", label: "stars" }
                  ]
                  value: root.repoSort
                  foreground: root.foreground
                  accent: Color.accent
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  focusable: false
                  onChanged: function(v) { root.setRepoSort(v) }
                }
              }
            }

            Repeater {
              model: root.repos

              RepoRow {
                required property var modelData
                width: parent ? parent.width : 0
                item: modelData
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
  component SafeToolTip: ToolTip {
    id: tip
    property string fontFamily: Style.font.family

    delay: 400
    padding: 0

    background: BorderSurface {
      color: Color.tooltip.background
      borderSpec: Border.flat(Color.tooltip.border, Style.normalBorderWidth)
      radius: Style.cornerRadius
    }

    contentItem: Text {
      text: tip.text
      textFormat: Text.PlainText
      elide: Text.ElideRight
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
  }

  // One open PR: title (+ draft marker, + right-aligned relative age),
  // "[owner pill] repo #number · review decision", CI rollup glyph pinned
  // to the trailing edge. F5/F6 per exchange/19-feedback-delta-spec.md.
  component PrRow: Item {
    id: prRow
    property var item: null
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
  }

  // One issue the user themselves opened (F3): title (+ right-aligned
  // relative age), then "[owner pill] repo #number". Same shape as PrRow
  // minus the CI glyph and draft marker -- issues have neither.
  component IssueRow: Item {
    id: issueRow
    property var item: null
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
  }

  // One owned repo: name (+ release-tag pill when present), then
  // "pushed <relative> · N issues · M PRs". Hover tooltip carries the
  // default-branch commit headline via SafeToolTip (never PanelToolTip --
  // see the component's own comment).
  component RepoRow: Item {
    id: repoRow
    property var item: null
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
    }
  }
}
