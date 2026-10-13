import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import Quickshell.Services.Pipewire
import qs.Ui
import qs.Commons

// Soundscope: a live spectrum in the bar, and a popup with a large visualizer
// (bars or wave) plus a left/right balance control.
//
// Spectrum data comes from a private cava process (cava.conf next to this
// file) writing raw ASCII frames to stdout. Balance is applied as per-channel
// volume on the EasyEffects input sink when EasyEffects is running, because
// nothing else touches that sink's volume -- the volume keys and the audio
// panel resolve through it to the physical output and set every channel to
// the same level there, which would wipe a balance stored on that sink.
Panel {
  id: root
  moduleName: "titas.soundscope"
  ipcTarget: "titas.soundscope"

  // ---------------------------------------------------------------- settings
  readonly property int miniBars: Math.max(4, Math.min(24, Number(setting("bars", 12))))
  readonly property real panelOpacity: Math.max(0.3, Math.min(1, Number(setting("panelOpacity", 0.82))))

  // ---------------------------------------------------------------- spectrum
  readonly property int bandCount: 48
  property var levels: zeroLevels(bandCount)
  property bool cavaAvailable: false
  property bool cavaChecked: false
  property bool hasSignal: false
  property double lastFrameAt: 0

  readonly property string cavaConfig: decodeURIComponent(String(Qt.resolvedUrl("cava.conf")).replace(/^file:\/\//, ""))

  // ----------------------------------------------------------------- state
  property real balance: 0          // -1 = full left .. 0 = centre .. 1 = full right
  property string vizStyle: "bars"  // "bars" | "wave"
  property bool stateLoaded: false
  readonly property string stateFile: Quickshell.env("HOME") + "/.local/state/soundscope.json"

  // ----------------------------------------------------------------- audio
  readonly property var nodes: Pipewire.nodes ? Pipewire.nodes.values : []
  readonly property var sink: Pipewire.defaultAudioSink
  readonly property bool easyEffectsRunning: {
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (n && n.isSink && !n.isStream && String(n.name) === "easyeffects_sink") return true
    }
    return false
  }
  readonly property string balanceSinkName: easyEffectsRunning ? "easyeffects_sink" : (sink ? String(sink.name) : "")

  readonly property var players: Mpris.players ? Mpris.players.values : []
  readonly property var player: {
    for (var i = 0; i < players.length; i++) if (players[i] && players[i].isPlaying) return players[i]
    return players.length > 0 ? players[0] : null
  }
  readonly property string nowPlaying: {
    if (!player || !player.trackTitle) return "Nothing playing"
    return player.trackArtist ? player.trackArtist + " — " + player.trackTitle : player.trackTitle
  }

  // ---------------------------------------------------------------- colors
  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color low: Color.accent
  readonly property color high: Qt.lighter(Color.foreground, 1.08)

  // ------------------------------------------------------------- functions
  function zeroLevels(n) {
    var a = []
    for (var i = 0; i < n; i++) a.push(0)
    return a
  }

  function mix(a, b, t) {
    t = Math.max(0, Math.min(1, t))
    return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, a.a + (b.a - a.a) * t)
  }

  function ingest(line) {
    var parts = String(line).split(";")
    if (parts.length < bandCount) return
    var next = new Array(bandCount)
    var any = false
    for (var i = 0; i < bandCount; i++) {
      var v = Math.min(1, Math.max(0, (parseInt(parts[i], 10) || 0) / 1000))
      next[i] = v
      if (v > 0.01) any = true
    }
    levels = next
    hasSignal = any
    lastFrameAt = Date.now()
  }

  // Groups of adjacent bands -> one mini bar (max keeps transients visible).
  readonly property var miniLevels: {
    var out = []
    var n = miniBars
    for (var i = 0; i < n; i++) {
      var from = Math.floor(i * bandCount / n)
      var to = Math.max(from + 1, Math.floor((i + 1) * bandCount / n))
      var m = 0
      for (var j = from; j < to; j++) m = Math.max(m, levels[j] || 0)
      out.push(m)
    }
    return out
  }

  function channelGains(b) {
    return { left: b > 0 ? 1 - b : 1, right: b < 0 ? 1 + b : 1 }
  }

  readonly property string balanceLabel: {
    var pct = Math.round(Math.abs(balance) * 100)
    if (pct === 0) return "Centered"
    return (balance < 0 ? "Left " : "Right ") + pct
  }

  readonly property string gainLabel: {
    var g = channelGains(balance)
    return "L " + Math.round(g.left * 100) + "%  ·  R " + Math.round(g.right * 100) + "%"
  }

  function setBalance(v) {
    var snapped = Math.round(Math.max(-1, Math.min(1, v)) * 100) / 100
    if (Math.abs(snapped) < 0.015) snapped = 0  // a gentle detent at centre
    if (snapped === balance) return
    balance = snapped
    applyTimer.restart()
    saveTimer.restart()
  }

  function applyBalance() {
    if (!stateLoaded || balanceSinkName === "") return
    var g = channelGains(balance)
    balanceProc.command = ["pactl", "set-sink-volume", balanceSinkName,
                           Math.round(g.left * 100) + "%", Math.round(g.right * 100) + "%"]
    if (balanceProc.running) applyTimer.restart()
    else balanceProc.running = true
  }

  function setStyle(s) {
    if (s === vizStyle) return
    vizStyle = s
    saveTimer.restart()
  }

  onBalanceSinkNameChanged: applyTimer.restart()

  // EasyEffects rebuilds its sink on restart; re-apply whenever it appears.
  onEasyEffectsRunningChanged: applyTimer.restart()

  // Scriptable controls, e.g. for keybindings:
  //   omarchy-shell soundscope set -0.2 | nudge 0.05 | center | style wave
  IpcHandler {
    target: "soundscope"

    function set(value: real): void { root.setBalance(value) }
    function nudge(delta: real): void { root.setBalance(root.balance + delta) }
    function center(): void { root.setBalance(0) }
    function style(name: string): void { if (name === "bars" || name === "wave") root.setStyle(name) }
    function get(): string { return root.balanceLabel + " (" + root.gainLabel + ")" }
  }

  // ------------------------------------------------------------ processes
  Process {
    id: cavaCheck
    command: ["sh", "-c", "command -v cava"]
    onExited: function(code) {
      root.cavaChecked = true
      root.cavaAvailable = code === 0
      if (root.cavaAvailable && !cava.running) cava.running = true
    }
  }

  Process {
    id: cava
    command: ["cava", "-p", root.cavaConfig]
    stdout: SplitParser {
      onRead: function(data) { root.ingest(data) }
    }
    onExited: {
      root.hasSignal = false
      cavaRestart.restart()
    }
  }

  Process {
    id: balanceProc
  }

  Timer {
    // Look for cava until it shows up, so installing it needs no reload.
    interval: 15000
    running: !root.cavaAvailable
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!cavaCheck.running) cavaCheck.running = true
  }

  Timer {
    id: cavaRestart
    interval: 3000
    onTriggered: if (!cava.running) cavaCheck.running = true
  }

  Timer {
    // cava goes quiet (sleep_timer) during silence; let the bars fall.
    interval: 60
    running: root.hasSignal || root.levels.some(function(v) { return v > 0 })
    repeat: true
    onTriggered: {
      if (Date.now() - root.lastFrameAt < 250) return
      var next = root.levels.map(function(v) { return v < 0.01 ? 0 : v * 0.7 })
      root.levels = next
      if (!next.some(function(v) { return v > 0 })) root.hasSignal = false
    }
  }

  Timer {
    id: applyTimer
    interval: 40
    onTriggered: root.applyBalance()
  }

  Timer {
    id: saveTimer
    interval: 400
    onTriggered: stateView.setText(JSON.stringify({ balance: root.balance, style: root.vizStyle }, null, 2) + "\n")
  }

  FileView {
    id: stateView
    path: root.stateFile
    printErrors: false
    onLoaded: {
      try {
        var s = JSON.parse(text())
        if (typeof s.balance === "number") root.balance = Math.max(-1, Math.min(1, s.balance))
        if (s.style === "bars" || s.style === "wave") root.vizStyle = s.style
      } catch (e) {}
      root.stateLoaded = true
      applyTimer.restart()
    }
    onLoadFailed: {
      root.stateLoaded = true
      applyTimer.restart()
    }
  }

  PwObjectTracker { objects: root.sink ? [root.sink] : [] }

  PwNodePeakMonitor {
    id: peaks
    node: root.sink
    enabled: root.opened && !!root.sink
  }

  // ------------------------------------------------------------ bar button
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property real miniBarWidth: Style.spaceReal(3)
  readonly property real miniGap: Style.spaceReal(2)
  readonly property real miniLength: miniBars * miniBarWidth + (miniBars - 1) * miniGap

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    fixedWidth: vertical ? -1 : root.miniLength + Style.space(14)
    fixedHeight: vertical ? root.miniLength + Style.space(14) : -1
    tooltipText: root.opened ? "" : "Soundscope · Balance: " + root.balanceLabel
    onPressed: function(b) {
      if (b === Qt.RightButton) root.setBalance(0)
      else if (b === Qt.MiddleButton) root.setStyle(root.vizStyle === "bars" ? "wave" : "bars")
      else root.toggle()
    }

    Item {
      id: mini
      anchors.centerIn: parent
      width: root.miniLength
      height: Math.round(button.barSize * 0.56)
      rotation: button.vertical ? 90 : 0

      Row {
        anchors.centerIn: parent
        spacing: root.miniGap

        Repeater {
          model: root.miniBars

          Rectangle {
            required property int index
            readonly property real level: root.miniLevels[index] || 0
            anchors.verticalCenter: parent.verticalCenter
            width: root.miniBarWidth
            height: Math.max(width, mini.height * level)
            radius: width / 2
            color: root.hasSignal ? root.mix(root.low, root.high, level * 1.4) : root.fg
            opacity: root.hasSignal ? 0.55 + 0.45 * Math.min(1, level * 2) : 0.35

            Behavior on height { NumberAnimation { duration: 70; easing.type: Easing.OutQuad } }
          }
        }
      }
    }
  }

  // ----------------------------------------------------------------- panel
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(content.implicitHeight, Style.space(600))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) { if (dx !== 0) root.setBalance(root.balance + dx * 0.02) }
      onActivateRequested: root.setBalance(0)
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "c" || t === "C" || t === "0") root.setBalance(0)
        else if (t === "b" || t === "B") root.setStyle("bars")
        else if (t === "w" || t === "W") root.setStyle("wave")
      }

      // The theme's popup surface is opaque; give this card the translucency
      // the user's Hyprland windows have.
      Component.onCompleted: {
        var p = keyCatcher.parent
        while (p && !("borderSpec" in p)) p = p.parent
        if (p) p.color = Qt.binding(function() { return Util.alpha(Color.popups.background, root.panelOpacity) })
      }

      Column {
        id: content
        width: parent.width
        spacing: Style.space(14)

        // ---------- header ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(headIcon.implicitHeight, headText.implicitHeight, styleSwitch.implicitHeight)

          Text {
            id: headIcon
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "󰋋"
            color: Color.accent
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.display
          }

          Column {
            id: headText
            anchors.left: headIcon.right
            anchors.leftMargin: Style.space(12)
            anchors.right: styleSwitch.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: "Soundscope"
              color: root.fg
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
            }
            Text {
              width: parent.width
              text: root.nowPlaying
              elide: Text.ElideRight
              color: Qt.darker(root.fg, 1.4)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          ButtonGroup {
            id: styleSwitch
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            focusable: false
            options: [{ value: "bars", label: "Bars" }, { value: "wave", label: "Wave" }]
            value: root.vizStyle
            foreground: root.fg
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            fontSize: Style.font.caption
            onChanged: function(v) { root.setStyle(v) }
          }
        }

        // ---------- visualizer ----------
        Rectangle {
          id: stage
          width: parent.width
          height: Style.space(170)
          radius: Math.max(Style.cornerRadius, Style.space(6))
          color: Util.alpha(root.fg, 0.045)
          border.width: 1
          border.color: Util.alpha(root.fg, 0.07)
          clip: true

          readonly property real pad: Style.space(10)
          readonly property real reflection: Style.space(34)
          readonly property real floorY: height - pad - reflection

          // Bars: gradient columns with a soft reflection under the baseline.
          Item {
            anchors.fill: parent
            visible: root.vizStyle === "bars"

            Row {
              id: barRow
              x: stage.pad
              width: stage.width - stage.pad * 2
              height: stage.floorY - stage.pad
              y: stage.pad
              spacing: Style.spaceReal(2)
              readonly property real barW: (width - spacing * (root.bandCount - 1)) / root.bandCount

              Repeater {
                model: root.bandCount

                Item {
                  required property int index
                  readonly property real level: root.levels[index] || 0
                  width: barRow.barW
                  height: barRow.height

                  Rectangle {
                    anchors.bottom: parent.bottom
                    width: parent.width
                    height: Math.max(Style.spaceReal(2), parent.height * parent.level)
                    radius: Math.min(width / 2, Style.space(3))
                    gradient: Gradient {
                      GradientStop { position: 0.0; color: root.high }
                      GradientStop { position: 1.0; color: root.low }
                    }
                    opacity: root.hasSignal ? 1 : 0.25
                  }

                  Rectangle {
                    y: parent.height + Style.spaceReal(3)
                    width: parent.width
                    height: stage.reflection * parent.level
                    radius: Math.min(width / 2, Style.space(3))
                    gradient: Gradient {
                      GradientStop { position: 0.0; color: Util.alpha(root.low, 0.35) }
                      GradientStop { position: 1.0; color: Util.alpha(root.low, 0.0) }
                    }
                  }
                }
              }
            }
          }

          // Wave: a smooth curve mirrored around the centre line.
          Canvas {
            id: wave
            anchors.fill: parent
            anchors.margins: stage.pad
            visible: root.vizStyle === "wave"
            renderTarget: Canvas.FramebufferObject

            Connections {
              target: root
              function onLevelsChanged() { if (wave.visible && root.opened) wave.requestPaint() }
            }
            onVisibleChanged: requestPaint()

            onPaint: {
              var ctx = getContext("2d")
              ctx.reset()
              var w = width, h = height, cy = h / 2
              var n = root.bandCount
              var lv = root.levels
              var amp = h / 2 * 0.92

              function curve(sign) {
                var px = 0, py = cy - sign * Math.max(1, (lv[0] || 0) * amp)
                ctx.lineTo(px, py)
                for (var i = 1; i < n; i++) {
                  var x = i * w / (n - 1)
                  var y = cy - sign * Math.max(1, (lv[i] || 0) * amp)
                  ctx.quadraticCurveTo(px, py, (px + x) / 2, (py + y) / 2)
                  px = x; py = y
                }
                ctx.lineTo(px, py)
              }

              // Filled body.
              var g = ctx.createLinearGradient(0, 0, 0, h)
              g.addColorStop(0.0, Util.alpha(root.high, 0.85))
              g.addColorStop(0.5, Util.alpha(root.low, root.hasSignal ? 0.35 : 0.15))
              g.addColorStop(1.0, Util.alpha(root.high, 0.85))
              ctx.beginPath()
              ctx.moveTo(0, cy)
              curve(1)
              ctx.lineTo(w, cy)
              ctx.lineTo(0, cy)
              ctx.moveTo(0, cy)
              curve(-1)
              ctx.lineTo(w, cy)
              ctx.closePath()
              ctx.fillStyle = g
              ctx.fill()

              // Crisp edges.
              ctx.lineWidth = 1.6
              ctx.strokeStyle = Util.alpha(root.high, root.hasSignal ? 0.95 : 0.3)
              ctx.beginPath(); ctx.moveTo(0, cy); curve(1); ctx.stroke()
              ctx.beginPath(); ctx.moveTo(0, cy); curve(-1); ctx.stroke()

              // Centre line.
              ctx.lineWidth = 1
              ctx.strokeStyle = Util.alpha(root.low, 0.35)
              ctx.beginPath(); ctx.moveTo(0, cy); ctx.lineTo(w, cy); ctx.stroke()
            }
          }

          Text {
            anchors.centerIn: parent
            width: parent.width - Style.space(24)
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            visible: !root.cavaAvailable || !root.hasSignal
            text: !root.cavaChecked ? ""
                : !root.cavaAvailable ? "Install cava to start the visualizer:\nsudo pacman -S cava"
                : "Play something to see it move"
            color: Qt.darker(root.fg, 1.3)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }

          Text {
            anchors.left: parent.left
            anchors.bottom: parent.bottom
            anchors.margins: Style.space(8)
            text: "L"
            color: Util.alpha(root.fg, 0.35)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }
          Text {
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.margins: Style.space(8)
            text: "R"
            color: Util.alpha(root.fg, 0.35)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        PanelSeparator { foreground: root.fg }

        // ---------- balance ----------
        Column {
          width: parent.width
          spacing: Style.space(8)

          Item {
            width: parent.width
            implicitHeight: balanceTitle.implicitHeight

            Text {
              id: balanceTitle
              anchors.left: parent.left
              text: "Balance"
              color: root.fg
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
            }
            Text {
              anchors.right: parent.right
              anchors.baseline: balanceTitle.baseline
              text: root.balanceLabel
              color: root.balance === 0 ? Qt.darker(root.fg, 1.4) : Color.accent
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          Row {
            width: parent.width
            spacing: Style.space(10)

            Text {
              id: leftTag
              anchors.verticalCenter: parent.verticalCenter
              text: "L"
              color: root.fg
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
            }

            PanelSlider {
              id: balanceSlider
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - leftTag.width - rightTag.width - parent.spacing * 2
              bar: root.bar
              minimum: -1
              maximum: 1
              step: 0.02
              tickCount: 3
              fillColor: "transparent"
              value: root.balance
              onMoved: function(v) { root.setBalance(v) }
              onRightClicked: root.setBalance(0)
            }

            Text {
              id: rightTag
              anchors.verticalCenter: parent.verticalCenter
              text: "R"
              color: root.fg
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
            }
          }

          // Live output level per channel: what actually reaches each ear.
          Repeater {
            model: [{ tag: "L", ch: 0 }, { tag: "R", ch: 1 }]

            Row {
              required property var modelData
              width: parent.width
              spacing: Style.space(10)

              readonly property real peak: {
                var p = peaks.peaks
                if (p && p.length > modelData.ch) return p[modelData.ch]
                return peaks.peak
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                width: leftTag.width
                text: modelData.tag
                color: Util.alpha(root.fg, 0.5)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
              }

              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - leftTag.width - parent.spacing
                height: Style.space(5)
                radius: height / 2
                color: Util.alpha(root.fg, 0.1)

                Rectangle {
                  height: parent.height
                  radius: parent.radius
                  width: parent.width * Math.max(0, Math.min(1, parent.parent.peak))
                  gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0.0; color: root.low }
                    GradientStop { position: 1.0; color: root.high }
                  }
                  Behavior on width { NumberAnimation { duration: 80 } }
                }
              }
            }
          }

          Item {
            width: parent.width
            implicitHeight: Math.max(gainText.implicitHeight, centerButton.implicitHeight)

            Text {
              id: gainText
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: root.gainLabel + (root.easyEffectsRunning ? "  ·  via EasyEffects" : "")
              color: Qt.darker(root.fg, 1.4)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }

            Button {
              id: centerButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: "Center"
              bordered: true
              foreground: root.fg
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              fontSize: Style.font.caption
              enabled: root.balance !== 0
              opacity: enabled ? 1 : 0.4
              onClicked: root.setBalance(0)
            }
          }
        }
      }
    }
  }
}
