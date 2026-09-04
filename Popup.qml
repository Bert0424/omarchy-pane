import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Tuning popup for the Rain overlay. Reads/writes through the host BarWidget
// (`widget.settings` / `widget.setKey`).
Panel {
  id: root
  moduleName: "bert.pane"
  ipcTarget: "bert.pane"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var widget: null
  readonly property var barIdentity: hostWidget || root

  function open() { root.controller.show() }
  function openFromHotkey() { root.open() }
  function close() { root.controller.hide() }
  function toggle() { root.opened ? root.close() : root.open() }
  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  readonly property var cfg: (widget && widget.settings) ? widget.settings : ({})
  function val(k, dflt) { return cfg[k] !== undefined ? cfg[k] : dflt }
  function put(k, v) { if (widget && widget.setKey) widget.setKey(k, v) }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: false
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(col.width + Style.space(36))
    contentHeight: panel.fittedContentHeight(col.implicitHeight + Style.space(36))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: col
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.margins: Style.space(18)
        spacing: Style.space(12)
        width: Style.space(300)

        Text {
          text: "🌧  Pane"
          textFormat: Text.PlainText
          color: root.bar ? root.bar.foreground : Color.foreground
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.title
          font.bold: true
        }

        Toggle {
          width: parent.width
          label: "Show weather"
          checked: root.val("enabled", true)
          onClicked: root.put("enabled", !checked)
        }

        Dropdown {
          width: parent.width
          label: "Conditions"
          value: root.val("intensity", "Rain")
          options: ["Drizzle", "Rain", "Downpour", "Thunderstorm", "Snow"]
          onChanged: root.put("intensity", value)
        }

        Dropdown {
          width: parent.width
          label: "Density"
          value: root.val("density", "Normal")
          options: ["Sparse", "Normal", "Heavy"]
          onChanged: root.put("density", value)
        }

        Dropdown {
          width: parent.width
          label: "Wind"
          value: root.val("wind", "None")
          options: ["None", "Light", "Gusty"]
          onChanged: root.put("wind", value)
        }

        Dropdown {
          width: parent.width
          label: "Layer"
          value: root.val("layer", "In front of windows")
          options: ["In front of windows", "On the desktop", "Above everything"]
          onChanged: root.put("layer", value)
        }

        Toggle {
          width: parent.width
          label: "Falling rain"
          description: "Streaks crossing the screen"
          checked: root.val("streaks", true)
          onClicked: root.put("streaks", !checked)
        }

        Toggle {
          width: parent.width
          label: "Droplets on the glass"
          description: "Beads that cling, then run down leaving a trail"
          checked: root.val("beads", true)
          onClicked: root.put("beads", !checked)
        }

        Toggle {
          width: parent.width
          label: "Pause over fullscreen windows"
          description: "Stops entirely for games and video"
          checked: root.val("pauseFullscreen", true)
          onClicked: root.put("pauseFullscreen", !checked)
        }

        Toggle {
          width: parent.width
          label: "Lightning"
          description: "Thunderstorm only"
          checked: root.val("lightning", true)
          onClicked: root.put("lightning", !checked)
        }
      }
    }
  }
}
