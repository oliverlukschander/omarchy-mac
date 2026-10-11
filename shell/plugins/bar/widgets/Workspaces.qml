import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Ui

// The workspaces of the display this bar sits on. Each display owns ten ids
// (default/hypr/displays.lua); the bar shows the block of the workspace in
// front, which is the display's own unless it shows another display's (the
// laptop's in clamshell, or a lost display's). Before it shows any, its
// block comes from displays.json, by connector or by EDID description.
// Slots 1-5 always show, 6-10 while in use. With two or more displays, the
// display's number (display 1 is the leftmost), on a small monitor icon,
// comes first. With display-workspaces-off every bar shows the global
// workspaces 1-10, as without this module.
BarWidget {
  id: root
  moduleName: "omarchy.workspaces"

  readonly property var monitor: QsWindow.window ? Hyprland.monitorFor(QsWindow.window.screen) : null
  property bool globalWorkspaces: false
  property var blocks: ({})
  property var connectors: ({})

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
    if (!monitor || globalWorkspaces) return 0
    var shown = monitor.activeWorkspace ? monitor.activeWorkspace.id : 0
    if (shown > 0) return Math.floor((shown - 1) / 10)
    var own = connectors[monitor.name]
    if (own === undefined) own = blocks[monitor.description ? "desc:" + monitor.description : monitor.name]
    return own === undefined ? 0 : own
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

  // The focused workspace shows its layout: a square tiles, a circle scrolls,
  // and a triangle floats. Clicking it cycles to the next one, as Super + L does.
  property string focusedMode: "dwindle"
  property bool modeStale: false

  function modeGlyph(mode) {
    if (mode === "scrolling") return "\uDB81\uDF65"
    if (mode === "floating") return "\uDB81\uDD36"
    return "\uDB85\uDCFB"
  }

  // A layout only changes through the layout commands, which ask for a refresh,
  // or a config reload, so each workspace's mode is read once and cached rather
  // than running the script on every workspace switch.
  property var modeCache: ({})
  property int modeGeneration: 0
  property int modeProcWorkspace: -1
  property int modeProcGeneration: 0

  function focusedWorkspaceId() {
    return Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : -1
  }

  function showFocusedMode() {
    var mode = root.modeCache[root.focusedWorkspaceId()]
    if (mode !== undefined) root.focusedMode = mode
    else readMode()
  }

  function readMode() {
    if (modeProc.running) {
      root.modeStale = true
      return
    }
    var id = root.focusedWorkspaceId()
    if (id === -1) return
    root.modeProcWorkspace = id
    root.modeProcGeneration = root.modeGeneration
    modeProc.command = ["omarchy-hyprland-workspace-layout-current", String(id)]
    modeProc.running = true
  }

  function refresh() {
    root.modeCache = ({})
    root.modeGeneration++
    readMode()
  }

  function cycleLayout() {
    if (root.bar) root.bar.run("omarchy-hyprland-workspace-layout-toggle")
  }

  Component.onCompleted: refresh()

  Connections {
    target: Hyprland
    function onFocusedWorkspaceChanged() { root.showFocusedMode() }
    function onRawEvent(event) {
      if (event && String(event.name) === "configreloaded") root.refresh()
    }
  }

  Process {
    id: modeProc
    stdout: StdioCollector {
      onStreamFinished: {
        var mode = text.trim()
        // A read that started before a refresh may predate the change.
        if (!mode || root.modeProcGeneration !== root.modeGeneration) return
        root.modeCache[root.modeProcWorkspace] = mode
        if (root.modeProcWorkspace === root.focusedWorkspaceId()) root.focusedMode = mode
      }
    }
    onExited: {
      if (!root.modeStale) return
      root.modeStale = false
      // Deferred: the process still reports running while it signals exit.
      Qt.callLater(root.showFocusedMode)
    }
  }

  // Super + L and the default layout change the mode without a focus change,
  // so they ask every bar to read it again.
  ShellIpc {
    target: "omarchy.workspaces"

    function refresh(): void { root.broadcast("refresh") }
  }

  FileView {
    path: (root.bar ? root.bar.stateHome : Quickshell.env("HOME") + "/.local/state") + "/omarchy/displays.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var state = {}
      try {
        state = JSON.parse(text()) || {}
      } catch (e) {}
      var parsed = {}
      var displays = state.displays || {}
      for (var key in displays) parsed[key] = displays[key].block
      root.globalWorkspaces = state.global_workspaces === true
      root.blocks = parsed
      root.connectors = state.connectors || {}
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
      labelVisible: false
      hasVisualContent: true
      interactive: false
      opacity: root.monitor && root.monitor.focused ? 1 : 0.5
      horizontalMargin: 6
      verticalPadding: 6
      fixedWidth: root.vertical ? -1 : badge.width + scaledHorizontalMargin * 2
      fixedHeight: root.barSize

      // As tall as the Omarchy logo in the menu button.
      TextMetrics {
        id: logo
        font.family: "omarchy"
        font.pixelSize: label.fontSize
        text: "\ue900"
      }

      DisplayBadge {
        id: badge
        anchors.centerIn: parent
        number: root.displays().indexOf(root.monitor) + 1
        size: Math.round(logo.tightBoundingRect.height / 0.72)
        color: label.foreground
        fontFamily: label.fontFamily
      }
    }

    Repeater {
      model: root.workspaceIds()

      WidgetButton {
        required property int modelData

        readonly property var workspace: root.workspaceById(modelData)
        readonly property bool occupied: workspace !== null && workspace.toplevels.values.length > 0
        readonly property bool shown: root.monitor !== null && root.monitor.activeWorkspace !== null && root.monitor.activeWorkspace.id === modelData
        readonly property bool focused: shown && root.monitor.focused

        bar: root.bar
        // The focused workspace shows its layout; the one in front on another
        // display a plain marker.
        text: focused ? root.modeGlyph(root.focusedMode) : (shown ? "\uDB85\uDCFB" : String(modelData % 10))
        // Full for workspaces with windows and the one in front on the
        // focused display; clearly dimmed for empty slots.
        opacity: occupied || focused ? 1 : (shown ? 0.7 : 0.35)
        horizontalMargin: 6
        verticalPadding: 6
        fixedWidth: root.vertical ? root.barSize : Style.space(20)
        fixedHeight: root.barSize
        onPressed: function() {
          if (focused) root.cycleLayout()
          else root.focusWorkspace(modelData)
        }
      }
    }
  }
}
