// BarWidget.qml -- bar entry point for halmylyseas.github-status.
//
// Owns only the button + the icon/count-pill composite. The panel is a
// separate QML file loaded eagerly (not lazily on first click) via a Loader
// with active: true, per exchange/03-shell-api.md §4 -- the canonical
// pattern shared by clock/weather/Ristretto. Panels/services own no global
// state of their own; timers and subprocesses live in Service.qml (§3).
//
// The widget is always visible, even when the service reports "no-gh" or
// "unauthenticated" -- the panel carries the setup hint (06-design.md
// "Degradation states"), so hiding the bar icon would hide the one place a
// first-time user learns what to do next.
import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

BarWidget {
  id: root
  moduleName: "halmylyseas.github-status"

  readonly property var shell: bar && bar.shell ? bar.shell : null
  readonly property var svc: shell ? shell.serviceFor("halmylyseas.github-status") : null

  readonly property color urgent: bar ? bar.urgent : Color.urgent

  readonly property int unreadCount: svc ? Number(svc.unreadCount) || 0 : 0
  readonly property bool hasAttention: svc ? svc.hasAttention === true : false

  // Counts open PRs whose CI rollup is "failure" -- feeds the bar tooltip
  // summary only; svc.hasAttention (the contract's own derived flag) is what
  // actually drives the icon's urgent recolor, so this can never disagree
  // with the icon about *whether* something needs attention, only add detail
  // to *why*.
  function failingCiCount(prs) {
    if (!prs) return 0
    var n = 0
    for (var i = 0; i < prs.length; i++) {
      if (prs[i] && prs[i].ciState === "failure") n++
    }
    return n
  }

  // Short bar tooltip. Degradation states get a plain-English hint instead
  // of the usual "N unread · M PRs" summary -- matches the hero-area hint in
  // Panel.qml so the bar and the panel never tell two different stories.
  readonly property string tooltipSummary: {
    if (!svc) return "GitHub Status"
    var status = svc.status
    if (status === "no-gh") return "GitHub Status — gh CLI not found"
    if (status === "unauthenticated") return "GitHub Status — not signed in"
    if (status === "offline") return "GitHub Status — offline"
    if (status === "rate-limited") {
      var until = svc.rateLimitedUntil
      return "GitHub Status — rate-limited" + (until ? " until " + until : "")
    }
    return "GitHub Status — " + Model.summaryTooltip({
      unreadCount: svc.unreadCount,
      openPRCount: svc.openPRs ? svc.openPRs.length : 0,
      reviewRequestCount: svc.reviewRequests ? svc.reviewRequests.length : 0,
      ciFailingCount: failingCiCount(svc.openPRs)
    })
  }

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  // The panel is loaded standalone, so it needs everything handed to it: the
  // bar, this widget's settings, and the button to anchor against.
  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  implicitWidth: vertical ? barSize : Style.bar.statusSlot
  implicitHeight: vertical ? Style.bar.statusSlot : barSize

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    slotSize: Style.bar.statusSlot
    active: root.hasAttention
    tooltipText: root.tooltipSummary
    onPressed: function(b) { root.toggle() }

    // Icon + count-pill composite -- no first-party widget renders a numeric
    // badge (exchange/03-shell-api.md §10/§13#13), so this is bespoke but
    // built entirely from Style/Color tokens.
    iconComponent: Component {
      Item {
        width: Style.bar.iconCanvas
        height: Style.bar.iconCanvas

        Text {
          anchors.centerIn: parent
          text: ""
          textFormat: Text.PlainText
          color: button.active && button.useActiveColor ? button.activeColor : button.foreground
          font.family: button.fontFamily
          font.pixelSize: button.fontSize
        }

        Rectangle {
          id: pill
          visible: root.unreadCount > 0
          width: Math.max(Style.space(14), countText.implicitWidth + Style.space(6))
          height: Style.space(14)
          radius: height / 2
          color: root.urgent
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.rightMargin: -Style.space(4)
          anchors.topMargin: -Style.space(4)

          Text {
            id: countText
            anchors.centerIn: parent
            // badgeText() caps the display at "99+" -- Model.js §"bar text",
            // the same cap the service itself applies to unreadCount.
            text: Model.badgeText(root.unreadCount)
            textFormat: Text.PlainText
            color: Color.background
            font.family: button.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }
        }
      }
    }
  }
}
