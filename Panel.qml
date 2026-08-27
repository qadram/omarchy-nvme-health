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

  readonly property var disk: status && status.disk ? status.disk : null
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
  }

  function metricValue(key) {
    if (!disk) return "—"
    if (key === "hours") return Model.formatHours(disk.powerOnHours)
    if (key === "realloc") {
      if (disk.protocol === "nvme")
        return disk.mediaErrors === null || disk.mediaErrors === undefined ? "—" : String(disk.mediaErrors)
      return disk.reallocatedSectors === null || disk.reallocatedSectors === undefined ? "—" : String(disk.reallocatedSectors)
    }
    if (key === "tbw") return Model.formatTiB(disk.tbwTiB)
    if (key === "life") return Model.formatPercent(disk.lifeRemainingPercent)
    if (key === "spare") return Model.formatPercent(disk.availableSparePercent)
    if (key === "used") return Model.formatPercent(disk.percentageUsed)
    return "—"
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
    contentWidth: panel.fittedContentWidth(Style.space(320))
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
          text: disk && disk.model ? disk.model : "Disk SMART"
          color: root.contentForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
          wrapMode: Text.WordWrap
        }

        Text {
          width: parent.width
          visible: disk && disk.device
          text: disk ? String(disk.device) : ""
          color: root.contentDim
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
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

        Text {
          width: parent.width
          visible: !!disk
          text: {
            if (!disk) return ""
            if (disk.passed === true) return "SMART: PASSED"
            if (disk.passed === false) return "SMART: FAILED"
            return root.loading ? "Refreshing…" : "SMART status"
          }
          color: disk && disk.passed === false
            ? (root.bar ? root.bar.urgent : Color.urgent)
            : root.contentForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.body
          font.bold: true
        }

        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: !!disk

          Repeater {
            model: [
              { label: "Life remaining", key: "life" },
              { label: "Power-on", key: "hours" },
              { label: disk && disk.protocol === "nvme" ? "Media errors" : "Reallocated sectors", key: "realloc" },
              { label: "TBW", key: "tbw" },
              { label: "Spare", key: "spare" },
              { label: "Wear used", key: "used" }
            ]

            Row {
              required property var modelData
              width: content.width
              spacing: Style.space(12)
              visible: {
                if (!disk) return false
                if (modelData.key === "spare" || modelData.key === "used")
                  return disk.protocol === "nvme"
                return true
              }

              Text {
                width: Style.space(150)
                text: modelData.label
                color: root.contentDim
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Text {
                text: root.metricValue(modelData.key)
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.body
                font.bold: true
              }
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
