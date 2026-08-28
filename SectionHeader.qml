// SectionHeader.qml -- kit-styled panel section header: a small-caps label
// (PanelSectionHeader) plus a right-aligned count pill, used by all five
// sections in Panel.qml (Inbox, Review requests, My open PRs, My open
// issues, Repositories) per exchange/19-feedback-delta-spec.md F4. ("Repo
// activity" was renamed "Repositories" by exchange/33-feedback3-delta-spec.md
// H3 -- see the next paragraph.)
//
// Pill text: the rendered count (post-cap/slice/filter -- whatever the
// caller is actually about to draw), or "…" before the service's first
// successful sync (synced === false). Count text is PlainText even though
// it is numeric/synthesized -- cheap insurance, matches the file-wide
// policy in Panel.qml.
//
// `extra` is an optional Component instantiated between the label and the
// count pill. Historically Panel.qml used this for the F1 repo-sort toggle
// in the Repo activity header ("left of the count pill" per the spec) and,
// per exchange/26-feedback2-delta-spec.md G4, the single-toggle chip in the
// My open issues header (Focus/All at first, later H1's single "Subscribed"
// chip). exchange/33-feedback3-delta-spec.md H3 removed the sort feature
// entirely and renamed the section "Repositories" -- that header no longer
// passes `extra` at all. The issues header is the only remaining user.
//
// exchange/26-feedback2-delta-spec.md G3 (fold): a header is clickable
// (toggles Panel.qml's per-section `collapsed` state) exactly when it is
// both synced and has count > 0 -- an unsynced ("…") or genuinely-empty
// (count === 0) header is inert, same as before this delta. `collapsed` is
// owned by the caller (Panel.qml), not this component -- this file only
// reads it to paint the chevron and emits `toggled()` on click, the same
// "state lives in the parent, child just reports the click" shape as
// ButtonGroup's `value`/`changed(value)`.
//
// Hit-area separation (G3's own requirement, "verify by geometry, not
// hope"): the fold click/hover region is sized to
// `trailing.x - a small gap`, i.e. it stops exactly where the trailing Row
// (extra + pill) begins. That Row's own children (the issues header's
// toggle chip when present, the count pill) sit strictly to the right of
// that boundary and are never covered by the fold MouseArea, so a click on
// the toggle can never register as a fold -- this is a real non-overlapping
// rectangle, not a z-order/event-consumption trick.
import QtQuick
import qs.Commons
import qs.Ui

Item {
  id: root

  property string text: ""
  property int count: 0
  property bool synced: true
  property bool collapsed: false
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  property Component extra: null

  signal toggled()

  // Zero-count sections keep the old auto-fold behavior (they already
  // render header-only -- nothing to toggle); an unsynced "…" header isn't
  // clickable either, since its count isn't real yet.
  readonly property bool clickable: root.synced && root.count > 0

  width: parent ? parent.width : 0
  implicitHeight: Math.max(
    headerText.implicitHeight,
    pill.implicitHeight,
    extraLoader.item ? extraLoader.item.implicitHeight : 0)

  // Fold hover/click surface -- left edge to `trailing`'s left edge only,
  // see header comment. Sits behind headerText/chevron (declared first),
  // never behind `trailing` (declared after, and geometrically excluded
  // anyway).
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

  // "Folded by user" indicator -- deliberately absent (not just invisible:
  // not instantiated with empty text) when the header isn't clickable, so
  // an empty/unsynced section reads exactly as it did before this delta
  // (header + pill, nothing else) and a folded populated section reads
  // distinctly (chevron flips to "▸").
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
