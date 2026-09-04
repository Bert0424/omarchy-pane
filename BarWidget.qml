import QtQuick
import qs.Commons
import qs.Ui

// Bar pill for the Rain overlay. Left click opens the tuning popup; middle
// click quick-toggles the weather on/off. Settings persist through the
// standard bar-widget `settings` object and are pushed to the running
// service (Pane.qml) via applyConfig().
BarWidget {
  id: root
  moduleName: "bert.pane"

  readonly property var service: bar && bar.shell ? bar.shell.serviceFor(moduleName) : null

  readonly property var defaults: ({
    enabled: true,
    intensity: "Rain",
    density: "Normal",
    wind: "None",
    layer: "In front of windows",
    streaks: true,
    beads: true,
    lightning: true,
    pauseFullscreen: true
  })

  function effective() {
    var out = {}
    var s = root.settings || {}
    for (var k in defaults) out[k] = (s[k] !== undefined ? s[k] : defaults[k])
    return out
  }

  function pushConfig() {
    if (service && service.applyConfig) service.applyConfig(effective())
  }

  // Persist one changed key to shell.json and re-push to the service.
  function setKey(key, value) {
    var entry = { id: root.moduleName }
    var s = root.settings || {}
    for (var k in s) if (k !== "id") entry[k] = s[k]
    entry[key] = value
    root.settings = entry
    if (bar && bar.shell && typeof bar.shell.updateEntryInline === "function")
      bar.shell.updateEntryInline(root.moduleName, entry)
    pushConfig()
  }

  function injectPanel() {
    var t = panelLoader.item
    if (!t) return
    if ("bar" in t) t.bar = root.bar
    if ("anchorItem" in t) t.anchorItem = button
    if ("hostWidget" in t) t.hostWidget = root
    if ("widget" in t) t.widget = root
  }

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  function open() { if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey() }
  function close() { if (panelLoader.item && panelLoader.item.close) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle() }

  // The pill wears whatever is currently falling.
  readonly property string glyph: {
    var c = effective().intensity
    return c === "Snow" ? "❄"
         : c === "Thunderstorm" ? "⛈"
         : c === "Drizzle" ? "☂"
         : "🌧"
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: { injectPanel(); pushConfig() }
  onSettingsChanged: pushConfig()
  onServiceChanged: pushConfig()
  Component.onCompleted: pushConfig()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Popup.qml")
    visible: false
    onLoaded: { root.injectPanel(); Qt.callLater(root.injectPanel) }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.glyph
    horizontalMargin: 8.75
    dimmed: !root.effective().enabled
    tooltipText: root.effective().enabled
               ? "Pane — " + root.effective().intensity.toLowerCase()
               : "Pane (off)"

    onPressed: function (b) {
      if (!root.bar) return
      if (b === Qt.MiddleButton) root.setKey("enabled", !root.effective().enabled)
      else root.togglePanel()
    }
  }
}
