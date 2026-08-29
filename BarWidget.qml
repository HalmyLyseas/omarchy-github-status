// BarWidget.qml -- bar entry point. Owns only the button + icon/count-pill
// composite; Panel.qml loads eagerly via a Loader. Always visible, even
// degraded -- the panel itself carries the setup hint.
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
  // summary only; svc.hasAttention drives the icon's urgent recolor, so
  // this never disagrees with the icon about whether attention is needed.
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

  // UI-probe-only: exposes the eagerly-loaded Panel instance itself, since
  // it's otherwise unreachable from outside this file -- see
  // test/probe/ui-probe.qml.
  readonly property var _debugPanelItem: panelLoader.item

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
    // badge, so this is bespoke but built entirely from Style/Color tokens.
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
