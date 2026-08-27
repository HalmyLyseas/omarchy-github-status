// Panel.qml -- the popup for halmylyseas.github-status.
//
// Panel + KeyboardPanel per exchange/03-shell-api.md §5. Single scrollable
// column: Hero (title/status/refresh), Inbox, Review requests, My open PRs,
// Repo activity -- section order per 06-design.md "What v1 does" (review
// requests before own PRs: other people blocked on the user outrank the
// user's own backlog).
//
// This file codes only against the frozen Service public API contract in
// 06-design.md -- every read of `svc.*` is null-guarded, and every list is
// defaulted to [] before use, because the service may not have resolved yet
// on first paint (§3) and its data can legitimately be empty.
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
  readonly property var repos: svc && svc.repos ? svc.repos : []

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

            PanelSectionHeader {
              text: "INBOX"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            EmptyRow {
              visible: root.unreadNotifications.length === 0
              label: "Inbox zero"
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

            PanelSectionHeader {
              text: "REVIEW REQUESTS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            EmptyRow {
              visible: root.reviewRequests.length === 0
              label: "No review requests"
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

            PanelSectionHeader {
              text: "MY OPEN PULL REQUESTS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            EmptyRow {
              visible: root.openPRs.length === 0
              label: "No open PRs"
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

          // ------------------------------------------------- repo activity
          Column {
            width: parent.width
            spacing: Style.space(4)

            PanelSectionHeader {
              text: "REPO ACTIVITY"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            EmptyRow {
              visible: root.repos.length === 0
              label: "No repos found"
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

  // Centered dim italic placeholder for an empty section -- a first-class
  // row, not an omitted section (exchange/03-shell-api.md §7).
  component EmptyRow: Text {
    property string label: ""
    width: parent ? parent.width : 0
    text: label
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    font.italic: true
    horizontalAlignment: Text.AlignHCenter
    topPadding: Style.space(6)
    bottomPadding: Style.space(6)
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

  // One unread notification: title, then "repo · reason · relative time".
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

      Text {
        width: parent.width
        text: notifRow.item ? notifRow.item.title : ""
        textFormat: Text.PlainText
        elide: Text.ElideRight
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      Text {
        width: parent.width
        text: notifRow.item
          ? (notifRow.item.repo + "  ·  " + root.reasonLabel(notifRow.item.reason) + "  ·  " + Model.relativeTime(notifRow.item.updatedAt, root.nowMs))
          : ""
        textFormat: Text.PlainText
        elide: Text.ElideRight
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
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

  // One review request: title, then "repo #number · relative time".
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

      Text {
        width: parent.width
        text: rrRow.item ? rrRow.item.title : ""
        textFormat: Text.PlainText
        elide: Text.ElideRight
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      Text {
        width: parent.width
        text: rrRow.item
          ? (rrRow.item.repo + " #" + rrRow.item.number + "  ·  " + Model.relativeTime(rrRow.item.updatedAt, root.nowMs))
          : ""
        textFormat: Text.PlainText
        elide: Text.ElideRight
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
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

  // One open PR: title (+ draft marker), "repo #number · review decision",
  // CI rollup glyph pinned to the trailing edge.
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

      Text {
        width: parent.width
        text: prRow.item ? ((prRow.item.isDraft ? "[Draft] " : "") + prRow.item.title) : ""
        textFormat: Text.PlainText
        elide: Text.ElideRight
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      Text {
        width: parent.width
        text: {
          if (!prRow.item) return ""
          var label = root.reviewDecisionLabel(prRow.item.reviewDecision)
          return prRow.item.repo + " #" + prRow.item.number + (label ? "  ·  " + label : "")
        }
        textFormat: Text.PlainText
        elide: Text.ElideRight
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
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
        width: parent.width
        spacing: Style.space(6)

        Text {
          id: repoNameText
          text: repoRow.item ? repoRow.item.name : ""
          textFormat: Text.PlainText
          elide: Text.ElideRight
          width: Math.max(0, Math.min(implicitWidth, parent.width - (releasePill.visible ? releasePill.implicitWidth + Style.space(6) : 0)))
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
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
