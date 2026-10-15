// Pure view. The poll, the persisted state and the notification live in
// Service.qml, which the shell instantiates once; this file is rendered once
// per bar and must therefore stay free of side effects.
import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "io.github.qadram.nvme-health"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  // Injected by BarWidget, which resolves it through the plugin shell facade.
  property var service: null

  readonly property var disks: service ? service.disks : []
  readonly property var worst: service ? service.worst : null
  readonly property bool loading: service ? service.loading === true : false
  readonly property string lastError: service ? String(service.lastError || "") : ""
  readonly property var status: service ? service.status : null
  readonly property bool warning: service ? service.warning === true : false

  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property color contentDim: Qt.darker(contentForeground, 1.5)
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

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
    if (service) service.refresh()
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

  function diskColor(d) {
    if (!d || d.available === false) return root.contentDim
    if (d.warning === true || Model.severityRank(d) >= 3)
      return root.bar ? root.bar.urgent : Color.urgent
    return root.contentForeground
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
          visible: root.service === null
          text: "This bar does not give plugins access to their own service, "
            + "so no SMART data can be read. Known upstream: omarchy#11796."
          color: root.bar ? root.bar.urgent : Color.urgent
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.bodySmall
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
              text: Model.shortDevice(modelData)
              color: root.diskColor(modelData)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: modelData === root.worst
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
