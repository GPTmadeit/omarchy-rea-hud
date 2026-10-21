import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Click-through HUD for REA jobs. A Claude Code hook (rea-hud-hook.py) keeps
// ~/.local/state/rea-hud/state.json current; this card drops down under the
// bar, top-center like the calendar and weather popups, while any
// mcp__rea__* call is in flight and retracts shortly after the last one ends.
Item {
  id: root

  property var omarchyPath
  property var shell
  property var manifest

  readonly property string home: Quickshell.env("HOME")
  readonly property string statePath: home + "/.local/state/rea-hud/state.json"
  readonly property int lingerMs: 6000

  property var hud: ({ active: [], recent: [], files: [] })
  property string lastText: ""
  property real nowMs: Date.now()
  property bool pinned: false
  // Paths and log entries already animated in, so a re-read of unchanged
  // state doesn't replay their entrance.
  property var seen: ({})

  readonly property var active: hud.active || []
  readonly property var recent: hud.recent || []
  readonly property var files: hud.files || []
  readonly property bool running: active.length > 0
  readonly property real lastEnded: recent.length > 0 ? recent[0].ended : 0
  readonly property bool failed: !running && recent.length > 0 && !recent[0].ok
  readonly property bool showing: pinned || running || (lastEnded > 0 && nowMs - lastEnded < lingerMs)
  readonly property color stateColor: failed ? Color.urgent : Color.accent
  readonly property color textColor: Color.popups.text

  // The oldest in-flight job is the headline; parallel calls show as a count.
  readonly property var job: running ? active[0] : (recent.length > 0 ? recent[0] : null)
  readonly property real elapsedMs: running ? nowMs - active[0].started : (job ? job.ms : 0)

  readonly property int pad: Style.space(16)
  readonly property int cardWidth: Style.space(540)

  // 0 = tucked under the bar, 1 = fully dropped. `intro` staggers sections in.
  property real drop: showing ? 1 : 0
  property real intro: 0

  Behavior on drop {
    NumberAnimation {
      duration: root.showing ? 520 : 300
      easing.type: root.showing ? Easing.OutQuint : Easing.InCubic
    }
  }

  onShowingChanged: {
    if (showing) introAnim.restart()
    else intro = 0
  }

  onRunningChanged: if (!running && recent.length > 0) flashAnim.restart()

  NumberAnimation {
    id: introAnim
    target: root
    property: "intro"
    from: 0; to: 1
    duration: 1100
    easing.type: Easing.OutCubic
  }

  function reveal(step) {
    return Math.max(0, Math.min(1, (root.intro - step * 0.11) / 0.35))
  }

  function parse(content) {
    var raw = String(content || "")
    root.nowMs = Date.now()
    if (raw === root.lastText) return
    root.lastText = raw
    try {
      var parsed = JSON.parse(raw)
      if (parsed && typeof parsed === "object") root.hud = parsed
    } catch (e) {}
  }

  function firstSight(key) {
    if (root.seen[key]) return false
    root.seen[key] = true
    return true
  }

  function humanize(tool) {
    return String(tool || "").split("_").map(function(w) {
      return w.length ? w.charAt(0).toUpperCase() + w.slice(1) : w
    }).join(" ")
  }

  function tilde(path) {
    var p = String(path || "")
    return p.indexOf(root.home) === 0 ? "~" + p.slice(root.home.length) : p
  }

  function basename(path) {
    var p = String(path || "")
    return p.slice(p.lastIndexOf("/") + 1)
  }

  function clock(ms) {
    var s = Math.max(0, ms) / 1000
    var m = Math.floor(s / 60)
    var rest = (s - m * 60).toFixed(1)
    return (m < 10 ? "0" : "") + m + ":" + (rest < 10 ? "0" : "") + rest
  }

  // Text that "decodes" into its value: unresolved characters cycle through
  // cipher glyphs and lock in left to right. Replays whenever the HUD opens.
  component Decode: Text {
    id: dec
    property string value: ""
    property int frame: 0
    property int frames: 16
    readonly property string glyphs: "0123456789ABCDEF<>/\\#$%&*+=?"
    readonly property bool armed: root.showing

    function render() {
      if (dec.frame >= dec.frames) { dec.text = dec.value; return }
      var keep = Math.floor(dec.value.length * dec.frame / dec.frames)
      var out = dec.value.slice(0, keep)
      for (var i = keep; i < dec.value.length; i++) {
        var c = dec.value.charAt(i)
        out += c === " " ? " " : dec.glyphs.charAt(Math.floor(Math.random() * dec.glyphs.length))
      }
      dec.text = out
    }
    function replay() { dec.frame = 0; dec.render(); scramble.restart() }

    textFormat: Text.PlainText
    font.family: Style.font.family
    onValueChanged: replay()
    onArmedChanged: if (armed) replay()
    Component.onCompleted: replay()

    Timer {
      id: scramble
      interval: 28
      repeat: true
      onTriggered: {
        dec.frame++
        dec.render()
        if (dec.frame >= dec.frames) stop()
      }
    }
  }

  component Label: Text {
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    font.letterSpacing: 2
    color: Color.muted
  }

  // L-shaped corner tick for the card's frame.
  component Corner: Item {
    property bool flipX: false
    property bool flipY: false
    width: Style.space(10)
    height: width
    Rectangle { x: parent.flipX ? parent.width - width : 0; y: parent.flipY ? parent.height - height : 0; width: parent.width; height: Math.max(1, Style.space(1.5)); color: root.stateColor }
    Rectangle { x: parent.flipX ? parent.width - width : 0; y: parent.flipY ? parent.height - height : 0; width: Math.max(1, Style.space(1.5)); height: parent.height; color: root.stateColor }
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.parse(text())
  }

  // The hook replaces the file atomically, which can drop the inotify watch;
  // a cheap re-read keeps the card honest regardless.
  Timer {
    interval: 750
    running: true
    repeat: true
    onTriggered: stateFile.reload()
  }

  Timer {
    interval: 100
    running: root.showing
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  IpcHandler {
    target: "rea-hud"
    function pin(): string { root.pinned = !root.pinned; return root.pinned ? "pinned" : "unpinned" }
    function state(): string { return root.running ? "running" : (root.showing ? "lingering" : "idle") }
    function ping(): string { return "ok" }
  }

  PanelWindow {
    id: panel
    visible: root.drop > 0.001
    // Top-only anchoring centers the surface horizontally; a zero exclusive
    // zone parks it just under the bar's reserved strip.
    anchors { top: true }
    margins { top: Style.gapsOut }
    implicitWidth: root.cardWidth
    implicitHeight: card.height + Style.space(4)
    color: "transparent"
    exclusiveZone: 0
    WlrLayershell.namespace: "rea-hud"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    // Display only: an empty input region keeps clicks going to the desktop.
    mask: Region {}

    Item {
      anchors.fill: parent
      clip: true

      BorderSurface {
        id: card
        width: root.cardWidth
        height: body.implicitHeight + card.borderTop + card.borderBottom + root.pad * 2
        y: -(1 - root.drop) * (height + Style.space(8))
        color: Color.popups.background
        borderSpec: Border.surfaceSpec("popups", "border", Util.alpha(root.stateColor, 0.95), Math.max(1, Style.space(2)))
        radius: Style.cornerRadius
        clip: true
        opacity: Math.min(1, root.drop * 1.5)

        Behavior on height { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

        // Faint grid behind everything for the instrument-panel feel.
        Repeater {
          model: Math.ceil(card.width / Style.space(18))
          Rectangle {
            x: index * Style.space(18)
            width: 1
            height: card.height
            color: Util.alpha(root.textColor, 0.03)
          }
        }

        // Scan line sweeping down the card while a job runs.
        Rectangle {
          id: scan
          width: card.width
          height: Style.space(48)
          visible: root.running
          gradient: Gradient {
            GradientStop { position: 0; color: "transparent" }
            GradientStop { position: 0.85; color: Util.alpha(root.stateColor, 0.07) }
            GradientStop { position: 1; color: Util.alpha(root.stateColor, 0.22) }
          }
          NumberAnimation on y {
            running: root.running
            from: -scan.height; to: card.height
            duration: 2600
            loops: Animation.Infinite
            easing.type: Easing.InOutSine
          }
        }

        // Completion flash, red on failure.
        Rectangle {
          id: flash
          anchors.fill: parent
          color: root.stateColor
          opacity: 0
          NumberAnimation {
            id: flashAnim
            target: flash
            property: "opacity"
            from: 0.22; to: 0
            duration: 700
            easing.type: Easing.OutCubic
          }
        }

        Item {
          id: corners
          anchors.fill: parent
          anchors.margins: card.borderTop + Style.space(4)
          SequentialAnimation on opacity {
            running: root.running
            loops: Animation.Infinite
            onRunningChanged: if (!running) corners.opacity = 0.8
            NumberAnimation { to: 0.25; duration: 900; easing.type: Easing.InOutSine }
            NumberAnimation { to: 1; duration: 900; easing.type: Easing.InOutSine }
          }
          Corner { anchors.left: parent.left; anchors.top: parent.top }
          Corner { anchors.right: parent.right; anchors.top: parent.top; flipX: true }
          Corner { anchors.left: parent.left; anchors.bottom: parent.bottom; flipY: true }
          Corner { anchors.right: parent.right; anchors.bottom: parent.bottom; flipX: true; flipY: true }
        }

        Column {
          id: body
          x: card.borderLeft + root.pad
          y: card.borderTop + root.pad
          width: card.width - card.borderLeft - card.borderRight - root.pad * 2
          spacing: Style.space(12)

          // ── Header: reticle, title, activity meter, status
          Item {
            width: parent.width
            height: Style.space(24)
            opacity: root.reveal(0)

            Item {
              id: reticle
              width: Style.space(22)
              height: width
              anchors.verticalCenter: parent.verticalCenter

              Rectangle {
                anchors.centerIn: parent
                width: parent.width * 0.8
                height: width
                color: "transparent"
                border.color: root.stateColor
                border.width: Math.max(1, Style.space(1.5))
                rotation: 45
                RotationAnimation on rotation {
                  running: root.running
                  from: 45; to: 405
                  duration: 2800
                  loops: Animation.Infinite
                }
              }
              Rectangle {
                anchors.centerIn: parent
                width: parent.width * 0.42
                height: width
                color: "transparent"
                border.color: Util.alpha(root.stateColor, 0.7)
                border.width: 1
                RotationAnimation on rotation {
                  running: root.running
                  from: 360; to: 0
                  duration: 1400
                  loops: Animation.Infinite
                }
              }
              Rectangle {
                anchors.centerIn: parent
                width: Style.space(4)
                height: width
                color: root.stateColor
                SequentialAnimation on opacity {
                  running: root.running
                  loops: Animation.Infinite
                  NumberAnimation { to: 0.15; duration: 450; easing.type: Easing.InOutSine }
                  NumberAnimation { to: 1; duration: 450; easing.type: Easing.InOutSine }
                }
              }
            }

            Row {
              anchors.left: reticle.right
              anchors.leftMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(10)
              Decode {
                id: reaTitle
                value: "REA"
                frames: 20
                font.pixelSize: Style.font.title
                font.bold: true
                font.letterSpacing: 4
                color: root.textColor
              }
              Decode {
                anchors.baseline: reaTitle.baseline
                value: "// reverse engineering link"
                frames: 24
                font.pixelSize: Style.font.caption
                color: Color.muted
              }
            }

            Row {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(12)

              Row {
                id: meter
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)
                property var levels: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
                Timer {
                  interval: 110
                  repeat: true
                  running: root.showing
                  onTriggered: {
                    var next = []
                    var t = Date.now() / 260
                    for (var i = 0; i < 16; i++) {
                      var wave = 0.5 + 0.5 * Math.sin(t + i * 0.55)
                      next.push(root.running ? 0.15 + 0.85 * (0.55 * wave + 0.45 * Math.random()) : 0.08)
                    }
                    meter.levels = next
                  }
                }
                Repeater {
                  model: 16
                  Item {
                    width: Style.space(2)
                    height: Style.space(16)
                    Rectangle {
                      anchors.bottom: parent.bottom
                      width: parent.width
                      height: Math.max(1, parent.height * meter.levels[index])
                      color: Util.alpha(root.stateColor, 0.3 + 0.7 * meter.levels[index])
                      Behavior on height { NumberAnimation { duration: 100 } }
                    }
                  }
                }
              }

              Rectangle {
                id: chip
                anchors.verticalCenter: parent.verticalCenter
                width: statusText.implicitWidth + Style.space(14)
                height: statusText.implicitHeight + Style.space(5)
                radius: Style.cornerRadius > 0 ? height / 2 : 0
                color: Util.alpha(root.stateColor, 0.16)
                border.color: Util.alpha(root.stateColor, 0.65)
                border.width: 1
                Behavior on width { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                Decode {
                  id: statusText
                  anchors.centerIn: parent
                  value: root.running ? "RUNNING" : (root.failed ? "FAILED" : "COMPLETE")
                  frames: 12
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  font.letterSpacing: 1.5
                  color: root.stateColor
                }
              }
            }
          }

          // ── Scan bar: sweeps while running, settles full when done
          Rectangle {
            id: track
            width: parent.width
            height: Math.max(2, Style.space(2))
            color: Util.alpha(root.textColor, 0.1)
            clip: true
            opacity: root.reveal(1)

            Rectangle {
              height: parent.height
              color: root.stateColor
              width: root.running ? 0 : parent.width
              Behavior on width { NumberAnimation { duration: 420; easing.type: Easing.OutCubic } }
            }
            Repeater {
              model: 2
              Rectangle {
                id: sweep
                visible: root.running
                width: track.width * (index === 0 ? 0.35 : 0.18)
                height: track.height
                gradient: Gradient {
                  orientation: Gradient.Horizontal
                  GradientStop { position: 0; color: "transparent" }
                  GradientStop { position: 0.8; color: root.stateColor }
                  GradientStop { position: 1; color: root.textColor }
                }
                NumberAnimation on x {
                  running: root.running
                  from: -sweep.width; to: track.width
                  duration: index === 0 ? 1300 : 2100
                  loops: Animation.Infinite
                  easing.type: Easing.InOutQuad
                }
              }
            }
          }

          // ── Job and target, side by side
          Item {
            width: parent.width
            height: Math.max(jobCol.implicitHeight, targetCol.visible ? targetCol.implicitHeight : 0)
            opacity: root.reveal(2)
            transform: Translate { y: (1 - root.reveal(2)) * -Style.space(6) }

            Column {
              id: jobCol
              width: targetCol.visible ? parent.width * 0.6 - Style.space(12) : parent.width
              spacing: Style.space(3)

              Item {
                width: parent.width
                height: jobLabel.implicitHeight
                Label { id: jobLabel; text: root.running ? "CURRENT JOB" : "LAST JOB" }
                Text {
                  anchors.right: parent.right
                  text: (root.active.length > 1 ? "+" + (root.active.length - 1) + " parallel   " : "") + "T+" + root.clock(root.elapsedMs)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  color: root.active.length > 1 ? root.stateColor : Color.muted
                }
              }
              Decode {
                width: parent.width
                value: root.job ? root.humanize(root.job.tool) : "Idle"
                font.pixelSize: Style.font.subtitle
                font.bold: true
                color: root.textColor
                elide: Text.ElideRight
              }
              Decode {
                width: parent.width
                visible: value !== ""
                value: root.job && root.job.detail ? "› " + root.job.detail : ""
                font.pixelSize: Style.font.bodySmall
                color: Util.alpha(root.textColor, 0.7)
                elide: Text.ElideRight
              }
              Text {
                width: parent.width
                visible: root.failed && !!root.hud.lastError
                text: root.hud.lastError ? root.hud.lastError.error : ""
                textFormat: Text.PlainText
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                color: Color.urgent
                elide: Text.ElideRight
                maximumLineCount: 2
                wrapMode: Text.Wrap
              }
            }

            Rectangle {
              visible: targetCol.visible
              x: parent.width * 0.6
              width: 1
              height: parent.height
              color: Util.alpha(root.textColor, 0.1)
            }

            Column {
              id: targetCol
              visible: !!root.hud.target
              x: parent.width * 0.6 + Style.space(12)
              width: parent.width * 0.4 - Style.space(12)
              spacing: Style.space(3)
              Label { text: "TARGET" }
              Decode {
                width: parent.width
                value: root.basename(root.hud.target)
                font.pixelSize: Style.font.subtitle
                font.bold: true
                color: root.stateColor
                elide: Text.ElideRight
              }
              Text {
                width: parent.width
                text: root.tilde(root.hud.target)
                textFormat: Text.PlainText
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                color: Color.muted
                elide: Text.ElideMiddle
              }
            }
          }

          // ── Files touched
          Column {
            width: parent.width
            spacing: Style.space(4)
            visible: root.files.length > 0
            opacity: root.reveal(3)
            transform: Translate { y: (1 - root.reveal(3)) * -Style.space(6) }

            Label { text: "FILES" }
            Repeater {
              model: root.files.slice(0, 5)
              Item {
                id: fileRow
                width: parent.width
                height: Style.space(16)
                property real enter: 1
                Component.onCompleted: {
                  if (root.firstSight("f:" + modelData.path)) { enter = 0; fileIn.start() }
                }
                NumberAnimation {
                  id: fileIn
                  target: fileRow
                  property: "enter"
                  to: 1
                  duration: 420
                  easing.type: Easing.OutCubic
                }

                // Highlight sweep behind a freshly added path.
                Rectangle {
                  width: parent.width * fileRow.enter
                  height: parent.height
                  color: Util.alpha(root.stateColor, 0.14 * (1 - fileRow.enter))
                }

                Row {
                  anchors.fill: parent
                  spacing: Style.space(8)
                  opacity: fileRow.enter
                  transform: Translate { x: (1 - fileRow.enter) * -Style.space(14) }
                  Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(15)
                    height: Style.space(13)
                    color: modelData.mode === "write" ? Util.alpha(Color.accent, 0.85) : "transparent"
                    border.color: Util.alpha(Color.accent, 0.7)
                    border.width: 1
                    Text {
                      anchors.centerIn: parent
                      text: modelData.mode === "write" ? "W" : "R"
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption - 1
                      font.bold: true
                      color: modelData.mode === "write" ? Color.popups.background : Color.accent
                    }
                  }
                  Text {
                    width: parent.width - Style.space(23)
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.tilde(modelData.path)
                    textFormat: Text.PlainText
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                    color: Util.alpha(root.textColor, index === 0 && root.running ? 1 : 0.65)
                    elide: Text.ElideMiddle
                  }
                }
              }
            }
          }

          // ── Log of finished jobs
          Column {
            width: parent.width
            spacing: Style.space(3)
            visible: root.recent.length > 0
            opacity: root.reveal(4)
            transform: Translate { y: (1 - root.reveal(4)) * -Style.space(6) }

            Rectangle { width: parent.width; height: 1; color: Util.alpha(root.textColor, 0.08) }
            Item { width: 1; height: Style.space(2) }
            Repeater {
              model: root.recent.slice(0, 3)
              Item {
                id: logRow
                width: parent.width
                height: logName.implicitHeight
                opacity: 1 - index * 0.25
                Rectangle {
                  id: logFlash
                  anchors.fill: parent
                  color: modelData.ok ? Color.accent : Color.urgent
                  opacity: 0
                }
                Component.onCompleted: {
                  if (root.firstSight("l:" + modelData.ended + modelData.tool)) logFlashAnim.start()
                }
                NumberAnimation {
                  id: logFlashAnim
                  target: logFlash
                  property: "opacity"
                  from: 0.3; to: 0
                  duration: 650
                  easing.type: Easing.OutCubic
                }
                Text {
                  id: logName
                  width: parent.width - logTime.width - Style.space(8)
                  text: (modelData.ok ? "✓  " : "✗  ") + root.humanize(modelData.tool)
                    + (modelData.detail ? "  · " + modelData.detail : "")
                  textFormat: Text.PlainText
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  color: modelData.ok ? Color.muted : Color.urgent
                  elide: Text.ElideRight
                }
                Text {
                  id: logTime
                  anchors.right: parent.right
                  text: (modelData.ms / 1000).toFixed(2) + "s"
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  color: Color.muted
                }
              }
            }
          }

          // ── Footer: decorative hex ticker and link indicator
          Item {
            width: parent.width
            height: Style.space(12)
            opacity: root.reveal(5) * 0.85

            Item {
              anchors.left: parent.left
              anchors.right: link.left
              anchors.rightMargin: Style.space(12)
              height: parent.height
              clip: true
              Text {
                id: ticker
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                property string stream: ""
                text: stream
                font.family: Style.font.family
                font.pixelSize: Style.font.caption - 1
                color: Util.alpha(root.stateColor, 0.45)
                Timer {
                  interval: 70
                  repeat: true
                  running: root.running
                  onTriggered: {
                    var b = Math.floor(Math.random() * 256).toString(16).toUpperCase()
                    ticker.stream = (ticker.stream + " " + (b.length < 2 ? "0" + b : b)).slice(-240)
                  }
                }
              }
            }

            Row {
              id: link
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(6)
              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(5)
                height: width
                radius: width / 2
                color: root.stateColor
                SequentialAnimation on opacity {
                  running: root.showing
                  loops: Animation.Infinite
                  NumberAnimation { to: 0.2; duration: 700 }
                  NumberAnimation { to: 1; duration: 700 }
                }
              }
              Text {
                text: "MCP LINK"
                font.family: Style.font.family
                font.pixelSize: Style.font.caption - 1
                font.letterSpacing: 2
                color: Color.muted
              }
            }
          }
        }
      }
    }
  }
}
