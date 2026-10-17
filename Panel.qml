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
  property int selectedIndex: 0
  property string selectedDevice: ""

  readonly property var disk: status && status.disk ? status.disk : null
  readonly property var disks: {
    if (status && status.disks && status.disks.length)
      return status.disks
    if (disk) return [disk]
    return []
  }
  readonly property var shownDisk: {
    if (disks.length)
      return disks[Math.max(0, Math.min(selectedIndex, disks.length - 1))]
    return disk
  }
  readonly property bool warning: {
    for (var i = 0; i < disks.length; i++) {
      if (disks[i] && (disks[i].warning === true || disks[i].ok === false)) return true
    }
    return status ? status.ok === false : false
  }
  readonly property string label: Model.barLabel(shownDisk, false, status && status.ok === false)
  readonly property bool canSwitch: disks.length > 1

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
    syncSelection()
  }

  function syncSelection() {
    var list = disks
    if (!list.length) {
      selectedIndex = 0
      return
    }
    var want = selectedDevice
    if (!want && disk && disk.device) want = String(disk.device)
    var idx = Model.indexOfDevice(list, want)
    if (idx < 0) idx = 0
    selectedIndex = idx
    selectedDevice = list[idx] && list[idx].device ? String(list[idx].device) : ""
  }

  function cycleDisk(delta) {
    if (!canSwitch) return
    selectedIndex = Model.nextIndex(selectedIndex, disks.length, delta)
    var d = disks[selectedIndex]
    selectedDevice = d && d.device ? String(d.device) : ""
  }

  function metricValue(key) {
    var d = shownDisk
    if (!d) return "—"
    if (key === "hours") return Model.formatHours(d.powerOnHours)
    if (key === "realloc") {
      if (d.protocol === "nvme")
        return d.mediaErrors === null || d.mediaErrors === undefined ? "—" : String(d.mediaErrors)
      return d.reallocatedSectors === null || d.reallocatedSectors === undefined ? "—" : String(d.reallocatedSectors)
    }
    if (key === "tbw") return Model.formatTiB(d.tbwTiB)
    if (key === "life") return Model.formatPercent(d.lifeRemainingPercent)
    if (key === "spare") return Model.formatPercent(d.availableSparePercent)
    if (key === "used") return Model.formatPercent(d.percentageUsed)
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
      onMoveRequested: function(dx, dy) {
        if (dx !== 0) root.cycleDisk(dx)
      }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh()
        else if (t === "n" || t === "N" || t === "l" || t === "L") root.cycleDisk(1)
        else if (t === "p" || t === "P" || t === "h" || t === "H") root.cycleDisk(-1)
      }

      Column {
        id: content
        width: parent.width
        spacing: Style.space(10)

        Row {
          width: parent.width
          spacing: Style.space(8)
          visible: root.canSwitch

          Text {
            text: "‹"
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
            MouseArea {
              anchors.fill: parent
              anchors.margins: -6
              cursorShape: Qt.PointingHandCursor
              onClicked: root.cycleDisk(-1)
            }
          }

          Text {
            text: (root.selectedIndex + 1) + " / " + root.disks.length
            color: root.contentDim
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            verticalAlignment: Text.AlignVCenter
          }

          Text {
            text: "›"
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
            MouseArea {
              anchors.fill: parent
              anchors.margins: -6
              cursorShape: Qt.PointingHandCursor
              onClicked: root.cycleDisk(1)
            }
          }

          Text {
            text: "← → to switch"
            color: root.contentDim
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            verticalAlignment: Text.AlignVCenter
          }
        }

        Text {
          width: parent.width
          text: {
            if (!shownDisk || !shownDisk.model) return "Disk SMART"
            var name = String(shownDisk.model)
            var isSystem = shownDisk.system === true
            if (shownDisk.system === undefined)
              isSystem = !!(disk && shownDisk.device && disk.device === shownDisk.device)
            return isSystem ? name + "  (system)" : name
          }
          color: root.contentForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
          wrapMode: Text.WordWrap
        }

        Text {
          width: parent.width
          visible: shownDisk && shownDisk.device
          text: shownDisk ? String(shownDisk.device) : ""
          color: root.contentDim
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          width: parent.width
          visible: root.lastError !== "" || (shownDisk && shownDisk.ok === false) || (status && status.ok === false)
          text: {
            if (root.lastError !== "") return root.lastError
            if (shownDisk && shownDisk.ok === false)
              return shownDisk.error
                ? String(shownDisk.error).substring(0, 256)
                : "Could not read SMART data for this disk."
            return (status && status.message
                ? String(status.message).substring(0, 256)
                : "Could not read disk SMART data.")
          }
          color: root.warning ? (root.bar ? root.bar.urgent : Color.urgent) : root.contentDim
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        Text {
          width: parent.width
          visible: !!shownDisk
          text: {
            if (!shownDisk) return ""
            if (shownDisk.ok === false) return "Read failed"
            if (shownDisk.passed === true) return "SMART: PASSED"
            if (shownDisk.passed === false) return "SMART: FAILED"
            return root.loading ? "Refreshing…" : "SMART status"
          }
          color: shownDisk && shownDisk.passed === false
            ? (root.bar ? root.bar.urgent : Color.urgent)
            : root.contentForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.body
          font.bold: true
        }

        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: !!shownDisk

          Repeater {
            model: [
              { label: "Life remaining", key: "life" },
              { label: "Power-on", key: "hours" },
              { label: shownDisk && shownDisk.protocol === "nvme" ? "Media errors" : "Reallocated sectors", key: "realloc" },
              { label: "TBW", key: "tbw" },
              { label: "Spare", key: "spare" },
              { label: "Wear used", key: "used" }
            ]

            Row {
              required property var modelData
              width: content.width
              spacing: Style.space(12)
              visible: {
                if (!shownDisk) return false
                if (modelData.key === "spare" || modelData.key === "used")
                  return shownDisk.protocol === "nvme"
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
