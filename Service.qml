// Single owner of the SMART poll, the persisted severity state and the
// notification. The bar instantiates one widget per screen, so anything that
// polls or notifies from the widget happens once per monitor: on a four-head
// machine that is four status.py processes per tick, four writers racing on one
// state file, and four identical notifications for one event. A service is
// instantiated once, so the work lands here and the widgets only render it.
import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

Item {
  id: root

  // Injected by the shell.
  property var shell: null

  // Pushed by the bar widget, which is where the settings live. Every widget
  // instance pushes the same values, so the writes are idempotent.
  property int refreshIntervalSec: 300
  property string configuredDevice: ""
  property bool notifyEnabled: true

  property var status: null
  property bool loading: false
  property string lastError: ""

  // Every drive status.py listed. Older payloads only carried `disk`.
  readonly property var disks: {
    if (status && status.disks && status.disks.length > 0) return status.disks
    if (status && status.disk) return [status.disk]
    return []
  }
  // The drive the bar speaks for: whichever most deserves attention.
  readonly property var worst: Model.worstDisk(root.disks)
  readonly property bool warning: worst
    ? worst.warning === true
    : (status ? status.ok === false : false)
  readonly property string label: Model.barLabel(worst, false, status && status.ok === false)

  // Severity seen on the previous poll, keyed by device. Persisted so a
  // notification fires when a disk gets worse, not on every refresh.
  property var lastSeen: ({})
  property bool stateLoaded: false

  readonly property string statePath: {
    var base = String(Quickshell.env("XDG_STATE_HOME") || "").trim()
    if (base === "") base = String(Quickshell.env("HOME") || "") + "/.local/state"
    return base + "/omarchy/nvme-health/severity.json"
  }

  readonly property string pluginDir: {
    var path = String(Qt.resolvedUrl("."))
    if (path.indexOf("file://") === 0) path = path.substring(7)
    if (path.length > 1 && path.charAt(path.length - 1) === "/")
      path = path.substring(0, path.length - 1)
    return path
  }

  function configure(interval, device, notify) {
    var n = Number(interval)
    if (isFinite(n)) root.refreshIntervalSec = Math.max(60, Math.min(3600, Math.round(n)))
    var d = String(device || "").trim()
    // Keep in sync with status.py MAX_DEVICE_ARG_LEN.
    root.configuredDevice = d.length > 64 ? d.substring(0, 64) : d
    root.notifyEnabled = notify !== false
  }

  function refresh() {
    if (proc.running) return
    loading = true
    lastError = ""
    procWatchdog.restart()
    proc.running = true
  }

  function applyStatus(text) {
    var capped = Model.clampStatusText(text)
    var parsed = Model.parseStatus(capped)
    if (!parsed) {
      lastError = "Could not parse status output"
      status = null
      return
    }
    status = parsed
    if (!parsed.ok && parsed.message)
      lastError = String(parsed.message).substring(0, 256)
    checkTransitions()
  }

  function severityReason(d) {
    if (Model.asInt(d.criticalWarning, 0) !== 0) return "SMART critical warning"
    if (Model.asInt(d.mediaErrors, 0) > 0) return "media errors: " + d.mediaErrors
    if (d.warning === true)
      return "SMART warning, life " + Model.formatPercent(d.lifeRemainingPercent)
    if (Model.asInt(d.availableSparePercent, 100) < 100)
      return "spare down to " + Model.formatPercent(d.availableSparePercent)
    return "state changed"
  }

  // Notify only when a disk's severity rises. One notification per poll: if
  // several disks worsen at once, the worst one speaks for the batch.
  function checkTransitions() {
    if (!root.stateLoaded) return
    var worsened = Model.worsenedDisk(root.lastSeen, root.disks)
    root.lastSeen = Model.severityMap(root.disks)
    stateFile.setText(JSON.stringify({ version: 1, severity: root.lastSeen }, null, 2) + "\n")
    if (worsened && root.notifyEnabled) notifyDegraded(worsened)
  }

  function notifyDegraded(d) {
    notifier.command = [
      "notify-send",
      "--app-name=NVMe Health",
      "--urgency=" + (Model.severityRank(d) >= 3 ? "critical" : "normal"),
      Model.shortDevice(d) + " health changed",
      (d.model ? String(d.model) + " — " : "") + root.severityReason(d)
    ]
    notifier.running = true
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: {
      try {
        var parsed = JSON.parse(String(text() || ""))
        if (parsed && typeof parsed === "object" && parsed.severity)
          root.lastSeen = parsed.severity
      } catch (e) {
        root.lastSeen = ({})
      }
      root.stateLoaded = true
    }
    onLoadFailed: {
      // First run, or the state file was removed: start from a clean slate.
      root.lastSeen = ({})
      root.stateLoaded = true
    }
  }

  // argv array, never a shell string: a drive model string reaches notify-send
  // as one argument and cannot be interpreted.
  Process {
    id: notifier
  }

  Process {
    id: proc
    // Absolute path, not bare "python3": a version manager (mise, asdf, pyenv)
    // puts its own shim first on PATH, and that interpreter has no
    // python-gobject, so "import gi" fails while /usr/bin/python3 works.
    command: root.configuredDevice !== ""
      ? ["/usr/bin/python3", root.pluginDir + "/status.py", root.configuredDevice]
      : ["/usr/bin/python3", root.pluginDir + "/status.py"]
    stdout: StdioCollector {
      id: statusStdout
      waitForEnd: true
    }
    // Do not attach a stderr collector: StdioCollector has no byte cap.
    // status.py emits all errors as bounded JSON on stdout.
    onExited: function(exitCode) {
      procWatchdog.stop()
      procKillTimer.stop()
      root.loading = false
      // Cap before parse/UI; status.py also refuses to emit > MAX_JSON_BYTES.
      var out = Model.clampStatusText(statusStdout.text || "")
      if (out.trim() !== "") {
        root.applyStatus(out)
        return
      }
      root.lastError = "status.py failed (" + exitCode + ")"
      root.status = null
    }
  }

  Timer {
    id: pollTimer
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Timer {
    id: procWatchdog
    interval: 50000
    repeat: false
    onTriggered: {
      if (!proc.running) return
      proc.signal(15)
      procKillTimer.restart()
    }
  }

  Timer {
    id: procKillTimer
    interval: 2000
    repeat: false
    onTriggered: {
      if (!proc.running) return
      proc.signal(9)
      root.loading = false
      root.lastError = "status.py timed out"
      root.status = null
    }
  }

  Component.onCompleted: Qt.callLater(root.refresh)
}
