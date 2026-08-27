// SectionHeader.qml -- kit-styled panel section header: a small-caps label
// (PanelSectionHeader) plus a right-aligned count pill, used by all five
// sections in Panel.qml (Inbox, Review requests, My open PRs, My open
// issues, Repo activity) per exchange/19-feedback-delta-spec.md F4.
//
// Pill text: the rendered count (post-cap/slice -- whatever the caller is
// actually about to draw), or "…" before the service's first successful
// sync (synced === false). Count text is PlainText even though it is
// numeric/synthesized -- cheap insurance, matches the file-wide policy in
// Panel.qml.
//
// `extra` is an optional Component instantiated between the label and the
// count pill -- Panel.qml uses this for the F1 repo-sort toggle in the
// Repo activity header ("left of the count pill" per the spec). Every
// other section leaves it unset.
import QtQuick
import qs.Commons
import qs.Ui

Item {
  id: root

  property string text: ""
  property int count: 0
  property bool synced: true
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  property Component extra: null

  width: parent ? parent.width : 0
  implicitHeight: Math.max(
    headerText.implicitHeight,
    pill.implicitHeight,
    extraLoader.item ? extraLoader.item.implicitHeight : 0)

  PanelSectionHeader {
    id: headerText
    text: root.text
    foreground: root.foreground
    fontFamily: root.fontFamily
    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
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
        text: root.synced ? String(root.count) : "…"
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
