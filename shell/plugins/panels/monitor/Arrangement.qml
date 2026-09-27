import QtQuick
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import "Model.js" as Model

// The displays drawn to scale, as the display module arranged them. Drag one
// to rearrange: on release it snaps flush against its nearest neighbour and
// the module moves it there and remembers it.
Item {
  id: root

  property var bar
  property string mainName: ""
  property bool dragging: false

  implicitHeight: Style.space(130)

  // Logical rects, sorted into display numbers (D1 is the leftmost).
  readonly property var displays: {
    var result = []
    var values = Hyprland.monitors.values
    for (var i = 0; i < values.length; i++) {
      var m = values[i]
      if (m.name === "FALLBACK" || m.name.indexOf("HEADLESS") === 0 || m.scale <= 0) continue
      var turned = m.lastIpcObject && m.lastIpcObject.transform % 2 === 1
      var w = Math.round((turned ? m.height : m.width) / m.scale)
      var h = Math.round((turned ? m.width : m.height) / m.scale)
      result.push({ name: m.name, x: m.x, y: m.y, w: w, h: h })
    }
    result.sort(function(a, b) { return a.x !== b.x ? a.x - b.x : a.y - b.y })
    return result
  }

  readonly property var bounds: {
    var b = { x: 0, y: 0, w: 1, h: 1 }
    if (displays.length === 0) return b
    var left = Infinity, top = Infinity, right = -Infinity, bottom = -Infinity
    for (var i = 0; i < displays.length; i++) {
      left = Math.min(left, displays[i].x)
      top = Math.min(top, displays[i].y)
      right = Math.max(right, displays[i].x + displays[i].w)
      bottom = Math.max(bottom, displays[i].y + displays[i].h)
    }
    return { x: left, y: top, w: right - left, h: bottom - top }
  }

  // Room around the displays so one can be dragged to any side.
  readonly property real zoom: Math.min(width / (bounds.w * 1.6), height / (bounds.h * 1.6))
  readonly property real originX: (width - bounds.w * zoom) / 2
  readonly property real originY: (height - bounds.h * zoom) / 2

  function drop(index, viewX, viewY) {
    var moving = displays[index]
    var others = []
    for (var i = 0; i < displays.length; i++) {
      if (i !== index) others.push(displays[i])
    }
    if (others.length === 0) return
    var spot = Model.snapPosition(others, {
      x: Math.round((viewX - originX) / zoom + bounds.x),
      y: Math.round((viewY - originY) / zoom + bounds.y),
      w: moving.w,
      h: moving.h
    })
    moveProc.command = ["hyprctl", "eval", "omarchy_displays.move(\"" + moving.name + "\", " + spot.x + ", " + spot.y + ")"]
    moveProc.running = true
  }

  Process {
    id: moveProc
    onRunningChanged: if (!running) Hyprland.refreshMonitors()
  }

  Repeater {
    model: root.displays

    Rectangle {
      id: tile
      required property var modelData
      required property int index

      readonly property real homeX: root.originX + (modelData.x - root.bounds.x) * root.zoom
      readonly property real homeY: root.originY + (modelData.y - root.bounds.y) * root.zoom

      x: homeX
      y: homeY
      width: modelData.w * root.zoom
      height: modelData.h * root.zoom
      radius: Style.space(4)
      color: Qt.alpha(root.bar.foreground, handle.drag.active ? 0.22 : 0.12)
      border.width: 1
      border.color: modelData.name === root.mainName ? Color.accent : Qt.alpha(root.bar.foreground, 0.5)

      Text {
        anchors.centerIn: parent
        text: "D" + (tile.index + 1) + (tile.modelData.name === root.mainName ? " ★" : "")
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
      }

      MouseArea {
        id: handle
        anchors.fill: parent
        cursorShape: Qt.OpenHandCursor
        drag.target: tile
        // The panel scrolls when it's taller than the screen; a drag here
        // moves the display, not the panel.
        preventStealing: true
        onPressed: root.dragging = true
        onCanceled: root.dragging = false
        onReleased: {
          root.dragging = false
          if (tile.x !== tile.homeX || tile.y !== tile.homeY) root.drop(tile.index, tile.x, tile.y)
          tile.x = Qt.binding(function() { return tile.homeX })
          tile.y = Qt.binding(function() { return tile.homeY })
        }
      }
    }
  }
}
