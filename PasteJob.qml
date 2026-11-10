// Pastes through a direct wl-paste child with a character cap, deadline and kill
// escalation; the native path retrieves an unbounded clipboard synchronously.
import QtQuick
import Quickshell.Io

Item {
  id: root

  property int maxChars: 4096
  property int timeoutMs: 1500
  property string wlPastePath: "/usr/bin/wl-paste"
  property string pkillPath: "/usr/bin/pkill"
  readonly property bool busy: root._busy
  readonly property int childPid: root._pid
  signal finished(bool success, string text, string error)

  property bool _busy: false
  property bool _failed: false
  property int _serial: 0
  property int _doneSerial: -1
  property int _pid: 0
  property string _text: ""
  property string _failure: ""
  property string _termSignal: ""

  function paste(primary) {
    if (root._busy || child.running) return false
    root._serial += 1
    root._busy = true
    root._failed = false
    root._failure = ""
    root._termSignal = ""
    root._text = ""
    root._pid = 0
    deadline.interval = root.timeoutMs
    deadline.restart()
    child.command = [root.wlPastePath, "--type", "text", "--no-newline"].concat(primary ? ["--primary"] : [])
    child.running = true
    return true
  }

  function cancel() {
    root.stop("cancelled")
  }

  // Kill only this helper's direct children (wl-paste's cat), never a group
  // or session; the parent is signalled separately below.
  function signalDescendants(sig) {
    if (!root._busy || root._pid <= 0 || terminator.running) return false
    root._termSignal = sig
    terminator.command = [root.pkillPath, "-" + sig, "-P", String(root._pid)]
    terminator.running = true
    return true
  }

  function stop(reason) {
    if (!root._busy || root._failed) return
    root._failed = true
    root._failure = reason || "cancelled"
    if (child.running) {
      if (!root.signalDescendants("TERM") && child.processId > 0) child.signal(15)
      killDeadline.restart()
      hardDeadline.restart()
    } else root.complete(root._serial, false)
  }

  function append(chunk) {
    if (!root._busy || root._failed) return
    var text = String(chunk || "")
    if (text.length > root.maxChars - root._text.length) {
      root.stop("clipboard too large")
      return
    }
    root._text += text
  }

  function complete(serial, success) {
    if (!root._busy || serial !== root._serial || serial === root._doneSerial) return
    root._doneSerial = serial
    deadline.stop()
    killDeadline.stop()
    hardDeadline.stop()
    var text = root._text
    var error = root._failure
    var ok = success && !root._failed
    root._busy = false
    root._pid = 0
    root._termSignal = ""
    root._text = ""
    if (!ok && !error) error = "clipboard read failed"
    root.finished(ok, text, error)
  }

  Timer { id: deadline; repeat: false; onTriggered: root.stop("clipboard timed out") }
  Timer {
    id: killDeadline
    interval: 1000
    repeat: false
    onTriggered: if (child.running && child.processId > 0 && child.processId === root._pid) {
      if (!root.signalDescendants("KILL")) child.signal(9)
    }
  }
  Timer {
    id: hardDeadline
    interval: 2000
    repeat: false
    onTriggered: if (child.running) {
      root.signalDescendants("KILL")
      child.running = false
      root.complete(root._serial, false)
    }
  }
  Process {
    id: child
    running: false
    onStarted: {
      root._pid = processId
      if (root._failed && root._pid > 0) child.signal(15)
    }
    onRunningChanged: if (!running) {
      var serial = root._serial
      Qt.callLater(function() { if (!child.running) root.complete(serial, false) })
    }
    onExited: function(code, status) { root.complete(root._serial, code === 0 && status === 0) }
    // No delimiter: emit arbitrary read chunks instead of buffering a line.
    stdout: SplitParser { splitMarker: ""; onRead: function(chunk) { root.append(chunk) } }
    stderr: SplitParser { splitMarker: ""; onRead: function(chunk) { } }
  }
  Process {
    id: terminator
    running: false
    onRunningChanged: if (!running) {
      var serial = root._serial
      var sig = root._termSignal
      Qt.callLater(function() {
        if (serial !== root._serial || !root._busy || !child.running || root._pid <= 0) return
        if (sig === "KILL") child.signal(9)
        else child.signal(15)
      })
    }
    onExited: function(code, status) {
      // The descendant sweep must finish before the parent is signalled;
      // otherwise the parent can exit and reparent its child first.
      if (!root._busy || !child.running || root._pid <= 0) return
      if (root._termSignal === "KILL") child.signal(9)
      else child.signal(15)
    }
  }
}
