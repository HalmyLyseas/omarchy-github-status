// SectionHeader.qml -- kit-styled section header: a small-caps label, a
// right-aligned count pill, and an optional `extra` Component, shared by
// every Panel.qml section (see docs/developers.md, "Architecture").
import QtQuick
import qs.Commons
import qs.Ui

Item {
  id: root

  property string text: ""
  property int count: 0
  // The source's real GraphQL totalCount/issueCount, when larger than
  // `count` -- 0 (the default) never triggers the "N of T" form, so a
  // caller with no total concept (Inbox) need not pass anything.
  property int total: 0
  property bool synced: true
  property bool collapsed: false
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  property Component extra: null

  // UI-probe-only: the pill's own rendered string, otherwise unreachable
  // from outside this file (`pillText` is a local id) -- see
  // test/probe/ui-probe.qml.
  readonly property alias pillLabel: pillText.text
  readonly property bool foldAffordanceVisible: foldHoverBg.visible && foldArea.enabled && chevron.visible

  signal toggled()

  // Every section can be folded, even while its count is zero or unsynced.
  readonly property bool clickable: true

  width: parent ? parent.width : 0
  implicitHeight: Math.max(
    headerText.implicitHeight,
    pill.implicitHeight,
    extraLoader.item ? extraLoader.item.implicitHeight : 0)

  // Fold hover/click surface -- left edge to `trailing`'s left edge only.
  // Sits behind headerText/chevron (declared first), geometrically
  // excluded from `trailing` (declared after) regardless.
  Rectangle {
    id: foldHoverBg
    visible: root.clickable
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    anchors.left: parent.left
    width: Math.max(0, trailing.x - Style.space(6))
    radius: Style.cornerRadius
    color: foldArea.containsMouse ? Style.hoverFillFor(root.foreground, Color.accent, Color.urgent) : "transparent"
  }

  MouseArea {
    id: foldArea
    anchors.fill: foldHoverBg
    enabled: root.clickable
    hoverEnabled: true
    cursorShape: root.clickable ? Qt.PointingHandCursor : Qt.ArrowCursor
    onClicked: root.toggled()
  }

  PanelSectionHeader {
    id: headerText
    text: root.text
    foreground: root.foreground
    fontFamily: root.fontFamily
    anchors.left: parent.left
    anchors.leftMargin: Style.space(4)
    anchors.verticalCenter: parent.verticalCenter
  }

  // The chevron reflects the current fold state for every section.
  Text {
    id: chevron
    visible: root.clickable
    anchors.left: headerText.right
    anchors.leftMargin: Style.space(6)
    anchors.verticalCenter: parent.verticalCenter
    text: root.collapsed ? "▸" : "▾"
    textFormat: Text.PlainText
    color: Qt.darker(root.foreground, 1.4)
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  Row {
    id: trailing
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(8)

    Loader {
      id: extraLoader
      anchors.verticalCenter: parent.verticalCenter
      sourceComponent: root.extra
    }

    BorderSurface {
      id: pill
      anchors.verticalCenter: parent.verticalCenter
      implicitWidth: Math.max(pill.implicitHeight, pillText.implicitWidth + Style.space(10))
      implicitHeight: pillText.implicitHeight + Style.space(4)
      color: Style.selectedFillFor(root.foreground, Color.accent, Color.urgent)
      borderSpec: Border.none()
      radius: pill.implicitHeight / 2

      Text {
        id: pillText
        anchors.centerIn: parent
        // "N of T" once the source reports a real total larger than what's
        // rendered -- the caller suppresses `total` to 0 during an active
        // search, so this component doesn't need to know about search.
        text: root.synced
          ? (root.total > root.count ? String(root.count) + " of " + String(root.total) : String(root.count))
          : "…"
        textFormat: Text.PlainText
        elide: Text.ElideRight
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }
    }
  }
}
