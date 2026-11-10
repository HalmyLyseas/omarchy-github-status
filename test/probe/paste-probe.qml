import QtQuick
import Quickshell
import Quickshell.Io

// Loads the real PasteJob against a mode-driven `wl-paste` mock and prints one
// PASTE_RESULT line for the selected scenario.
ShellRoot {
  id: root

  property string pluginDir: Quickshell.env("GHS_PLUGIN_DIR")
  property string mockPath: Quickshell.env("PASTE_MOCK")
  property string scenario: Quickshell.env("PASTE_SCENARIO") || "normal"
  property bool done: false
  property var job: null
  property var result: null

  function report() {
    console.log("PASTE_RESULT " + JSON.stringify({
      scenario: root.scenario,
      ok: root.result.ok,
      text: root.result.text,
      error: root.result.error,
      busy: root.result.busy,
      pid: root.result.pid
    }))
    Qt.quit()
  }

  function start() {
    if (root.scenario === "cancel") cancelTimer.start()
    root.job.paste(root.scenario === "primary")
  }

  Loader {
    id: loader
    active: true
    source: "file://" + root.pluginDir + "/PasteJob.qml"
    onLoaded: {
      root.job = item
      item.wlPastePath = root.mockPath
      item.timeoutMs = 300
      item.maxChars = 64
      item.finished.connect(function(ok, text, error) {
        if (root.done) return
        root.done = true
        root.result = { ok: ok, text: text, error: error, busy: item.busy, pid: item.childPid }
        root.report()
      })
      startTimer.start()
    }
  }

  Timer { id: startTimer; interval: 100; onTriggered: root.start() }
  Timer { id: cancelTimer; interval: 100; onTriggered: root.job.cancel() }
  Timer {
    id: probeTimeout
    interval: 2500
    running: true
    onTriggered: if (!root.done) {
      root.done = true
      root.result = { ok: false, text: "", error: "probe timeout", busy: root.job ? root.job.busy : false, pid: root.job ? root.job.childPid : 0 }
      root.report()
    }
  }
}
