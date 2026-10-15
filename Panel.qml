import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "io.github.qadram.nvme-health"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null

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
  readonly property var disk: Model.worstDisk(root.disks)
  readonly property bool warning: disk ? disk.warning === true : (status ? status.ok === false : false)
  readonly property string label: Model.barLabel(disk, false, status && status.ok === false)

  readonly property int refreshIntervalSec: {
    var n = Number(setting("refreshIntervalSec", 300))
    if (!isFinite(n)) return 300
    return Math.max(60, Math.min(3600, Math.round(n)))
  }
  readonly property string configuredDevice: {
    var s = String(setting("device", "") || "").trim()
    // Keep in sync with status.py MAX_DEVICE_ARG_LEN.
    if (s.length > 64) return s.substring(0, 64)
    return s
  }

  readonly property bool notifyEnabled: setting("notify", true) !== false
  readonly property string statePath: {
    var base = String(Quickshell.env("XDG_STATE_HOME") || "").trim()
    if (base === "") base = String(Quickshell.env("HOME") || "") + "/.local/state"
    return base + "/omarchy/nvme-health/severity.json"
  }

  // Severity seen on the previous poll, keyed by device. Persisted so a
  // notification fires when a disk gets worse, not on every refresh.
  property var lastSeen: ({})
  property bool stateLoaded: false

  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property color contentDim: Qt.darker(contentForeground, 1.5)
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string pluginDir: {
    var path = String(Qt.resolvedUrl("."))
    if (path.indexOf("file://") === 0) path = path.substring(7)
    if (path.length > 1 && path.charAt(path.length - 1) === "/")
      path = path.substring(0, path.length - 1)
    return path
  }

  function open() {
    root.controller.show()
    refresh()
  }

  function close() {
    root.controller.hide()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.hostWidget || root, direction)
    return false
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
      root.shortDevice(d) + " health changed",
      (d.model ? String(d.model) + " — " : "") + root.severityReason(d)
    ]
    notifier.running = true
  }

  function metricValue(d, key) {
    if (!d) return "—"
    if (key === "temp")
      return d.temperatureC === null || d.temperatureC === undefined
        ? "—" : String(d.temperatureC) + "°C"
    if (key === "life") return Model.formatPercent(d.lifeRemainingPercent)
    if (key === "spare") return Model.formatPercent(d.availableSparePercent)
    if (key === "errors") {
      var v = d.protocol === "nvme" ? d.mediaErrors : d.reallocatedSectors
      return v === null || v === undefined ? "—" : String(v)
    }
    if (key === "hours") return Model.formatHours(d.powerOnHours)
    if (key === "tbw") return Model.formatTiB(d.tbwTiB)
    return "—"
  }

  // "/dev/nvme2n1" -> "nvme2n1"; the /dev/ prefix is noise in a narrow column.
  function shortDevice(d) {
    if (!d || !d.device) return "—"
    var s = String(d.device)
    return s.indexOf("/dev/") === 0 ? s.substring(5) : s
  }

  function diskColor(d) {
    if (!d || d.available === false) return root.contentDim
    if (d.warning === true || Model.severityRank(d) >= 3)
      return root.bar ? root.bar.urgent : Color.urgent
    return root.contentForeground
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

  // argv array, never a shell string: disk model strings reach notify-send as
  // a single argument and cannot be interpreted.
  Process {
    id: notifier
  }

  Timer {
    id: pollTimer
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  // Keep in sync with status.py PROCESS_DEADLINE_SEC (+ small grace).
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

  Process {
    id: proc
    // Absolute path, not bare "python3": a version manager (mise, asdf,
    // pyenv, etc.) that puts its shims ahead of /usr/bin in PATH -- a
    // common, supported setup, not a misconfiguration -- makes a
    // PATH-resolved "python3" hit an isolated interpreter with no
    // python-gobject installed instead of the system one this plugin
    // depends on for UDisks2/gi access. Reproduced directly: status.py
    // raised `ModuleNotFoundError: No module named 'gi'` under a mise
    // Python, and returned real SMART JSON under /usr/bin/python3 on the
    // same machine, same install, only the interpreter changed.
    command: root.configuredDevice !== ""
      ? ["/usr/bin/python3", root.pluginDir + "/status.py", root.configuredDevice]
      : ["/usr/bin/python3", root.pluginDir + "/status.py"]
    stdout: StdioCollector {
      id: statusStdout
      waitForEnd: true
    }
    // Do not attach a stderr collector: StdioCollector has no byte cap.
    // status.py emits all errors as bounded JSON on stdout.
    stderr: null
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

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onActivateRequested: root.refresh()
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh()
      }

      Column {
        id: content
        width: parent.width
        spacing: Style.space(10)

        Text {
          width: parent.width
          text: root.disks.length > 0
            ? "Disk SMART — " + root.disks.length + (root.disks.length === 1 ? " drive" : " drives")
            : "Disk SMART"
          color: root.contentForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
          wrapMode: Text.WordWrap
        }

        Text {
          width: parent.width
          visible: root.lastError !== "" || (status && status.ok === false)
          text: root.lastError !== ""
            ? root.lastError
            : (status && status.message
                ? String(status.message).substring(0, 256)
                : "Could not read disk SMART data.")
          color: root.warning ? (root.bar ? root.bar.urgent : Color.urgent) : root.contentDim
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        // One aligned row per drive. Explicit widths instead of a nested
        // Repeater so the columns line up without a layout pass.
        Row {
          width: parent.width
          spacing: Style.space(6)
          visible: root.disks.length > 0

          Text {
            width: Style.space(76)
            text: "DRIVE"
            color: root.contentDim
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            width: Style.space(130)
            text: "MODEL"
            color: root.contentDim
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            width: Style.space(46)
            horizontalAlignment: Text.AlignRight
            text: "TEMP"
            color: root.contentDim
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            width: Style.space(46)
            horizontalAlignment: Text.AlignRight
            text: "LIFE"
            color: root.contentDim
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            width: Style.space(52)
            horizontalAlignment: Text.AlignRight
            text: "SPARE"
            color: root.contentDim
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            width: Style.space(40)
            horizontalAlignment: Text.AlignRight
            text: "ERR"
            color: root.contentDim
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Repeater {
          model: root.disks

          Row {
            required property var modelData
            width: content.width
            spacing: Style.space(6)

            Text {
              width: Style.space(76)
              text: root.shortDevice(modelData)
              color: root.diskColor(modelData)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: modelData === root.disk
              elide: Text.ElideRight
            }

            Text {
              width: Style.space(130)
              text: modelData.model ? String(modelData.model) : "—"
              color: root.contentDim
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
            }

            Text {
              width: Style.space(46)
              horizontalAlignment: Text.AlignRight
              text: root.metricValue(modelData, "temp")
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              width: Style.space(46)
              horizontalAlignment: Text.AlignRight
              text: root.metricValue(modelData, "life")
              color: root.diskColor(modelData)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              width: Style.space(52)
              horizontalAlignment: Text.AlignRight
              text: root.metricValue(modelData, "spare")
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              width: Style.space(40)
              horizontalAlignment: Text.AlignRight
              text: root.metricValue(modelData, "errors")
              color: root.diskColor(modelData)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: root.metricValue(modelData, "errors") !== "0"
            }
          }
        }

        Text {
          width: parent.width
          text: root.loading ? "Refreshing…" : "Press R or Enter to refresh"
          color: root.contentDim
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
