import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.qadram.nvme-health"

  // One service instance backs every bar. Resolved through the plugin shell
  // facade, which only hands a plugin its own service.
  readonly property var service: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor(root.moduleName)
    : null

  // A third-party replacement bar hands plugins a service-less facade, so the
  // lookup returns null by design (omacom/omarchy#11796, #13289). Say so with
  // "?" instead of rendering a bare icon that silently does nothing.
  readonly property string labelText: service ? String(service.label || "") : "?"
  readonly property bool warning: service ? service.warning === true : false

  readonly property bool opened: panelLoader.item
    ? panelLoader.item.opened === true
    : false
  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true
    : false

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

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function toggle() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function refresh() {
    if (service) service.refresh()
  }

  // The settings live on this bar entry, not on the service. Every bar pushes
  // the same values, so the writes are idempotent.
  function pushSettings() {
    if (service && typeof service.configure === "function")
      service.configure(root.refreshIntervalSec, root.configuredDevice, root.notifyEnabled)
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("service" in target) target.service = root.service
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: {
    injectPanel()
    pushSettings()
  }
  onSettingsChanged: {
    injectPanel()
    pushSettings()
  }
  onServiceChanged: {
    injectPanel()
    pushSettings()
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.labelText !== "" ? ("󰋊 " + root.labelText) : "󰋊"
    tooltipText: "Disk SMART health"
    active: root.warning || root.opened
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) root.refresh()
      else if (buttonCode === Qt.LeftButton) root.toggle()
    }
  }
}
