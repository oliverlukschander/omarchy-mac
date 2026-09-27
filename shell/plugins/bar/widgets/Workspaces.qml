import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

// The workspaces of the display this bar sits on. Each display owns ten ids
// (default/hypr/displays.lua): its block in displays.json, keyed by EDID
// description, or by connector for the internal panel. Slots 1-5 always
// show, 6-10 while in use. With two or more displays, the display's number
// (D1 is the leftmost) comes first.
BarWidget {
  id: root
  moduleName: "omarchy.workspaces"

  readonly property var monitor: QsWindow.window ? Hyprland.monitorFor(QsWindow.window.screen) : null
  property var blocks: ({})

  function displays() {
    var result = []
    var values = Hyprland.monitors.values
    for (var i = 0; i < values.length; i++) {
      if (values[i].name !== "FALLBACK" && values[i].name.indexOf("HEADLESS") !== 0) result.push(values[i])
    }
    result.sort(function(a, b) { return a.x !== b.x ? a.x - b.x : a.y - b.y })
    return result
  }

  function block() {
    if (!monitor) return 0
    var keys = monitor.description ? ["desc:" + monitor.description, "desc:" + monitor.description + "@" + monitor.name] : [monitor.name]
    for (var i = 0; i < keys.length; i++) {
      if (blocks[keys[i]] !== undefined) return blocks[keys[i]]
    }
    return 0
  }

  function workspaceById(id) {
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      if (values[i].id === id) return values[i]
    }
    return null
  }

  function workspaceIds() {
    var base = block() * 10
    var ids = []
    for (var slot = 1; slot <= 10; slot++) {
      if (slot <= 5 || workspaceById(base + slot) !== null) ids.push(base + slot)
    }
    return ids
  }

  function focusWorkspace(id) {
    if (!root.bar) return
    root.bar.run("hyprctl dispatch " + Util.shellQuote("hl.dsp.focus({ workspace = \"" + id + "\" })"))
  }

  FileView {
    path: (root.bar ? root.bar.stateHome : Quickshell.env("HOME") + "/.local/state") + "/omarchy/displays.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var parsed = {}
      try {
        var displays = JSON.parse(text()).displays || {}
        for (var key in displays) parsed[key] = displays[key].block
      } catch (e) {}
      root.blocks = parsed
    }
  }

  readonly property real trailingGap: root.vertical ? 0 : Style.spaceReal(1.5)

  implicitWidth: grid.implicitWidth + trailingGap
  implicitHeight: grid.implicitHeight

  GridLayout {
    id: grid
    anchors.fill: parent
    anchors.rightMargin: root.trailingGap
    columns: root.vertical ? 1 : root.workspaceIds().length + (label.visible ? 1 : 0)
    columnSpacing: root.vertical ? 0 : Style.space(1)
    rowSpacing: root.vertical ? Style.space(2) : 0

    WidgetButton {
      id: label
      visible: root.displays().length > 1
      bar: root.bar
      text: "D" + (root.displays().indexOf(root.monitor) + 1)
      interactive: false
      opacity: root.monitor && root.monitor.focused ? 1 : 0.5
      horizontalMargin: 6
      verticalPadding: 6
      fixedHeight: root.barSize
    }

    Repeater {
      model: root.workspaceIds()

      WidgetButton {
        required property int modelData

        readonly property var workspace: root.workspaceById(modelData)
        readonly property bool occupied: workspace !== null && workspace.toplevels.values.length > 0
        readonly property bool shown: root.monitor !== null && root.monitor.activeWorkspace !== null && root.monitor.activeWorkspace.id === modelData

        bar: root.bar
        text: shown ? "󱓻" : String(modelData % 10)
        // Full for workspaces with windows and the one in front on the
        // focused display; clearly dimmed for empty slots.
        opacity: occupied || (shown && root.monitor.focused) ? 1 : (shown ? 0.7 : 0.35)
        horizontalMargin: 6
        verticalPadding: 6
        fixedWidth: root.vertical ? root.barSize : Style.space(20)
        fixedHeight: root.barSize
        onPressed: function() { root.focusWorkspace(modelData) }
      }
    }
  }
}
