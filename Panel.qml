import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Ui
import qs.Commons
import qs.Commons as Commons

// Control: one bar icon that opens (on hover, or pinned by a click) a control
// centre built from Omarchy's own panel parts, so it follows the theme:
// Wi-Fi and Bluetooth tiles, quick toggles, and sound / microphone /
// brightness sliders, with shortcuts into the full panels of widgets that are
// kept on the bar but hidden ("hidden": true in shell.json).
Panel {
  id: root
  moduleName: "ebirkhoff.control"

  // ------------------------------------------------------------- state
  property bool wifiOn: false
  property string ssid: ""
  property bool ethernet: false
  property bool btOn: false
  property string btDevice: ""
  property real volume: 0
  property bool volumeMuted: false
  property real mic: 0
  property bool micMuted: false
  property int brightness: -1          // -1: no controllable backlight
  property bool nightLight: false
  property bool dnd: false
  property bool stayAwake: false
  // While the user drags a slider, polling must not snap it back.
  property double volumeHold: 0
  property double micHold: 0
  property double brightnessHold: 0
  function held(until) { return Date.now() < until }

  // ------------------------------------------------------- Pipeworks
  // With Pipeworks running, "the volume" is its first output strip (Main) and
  // "the microphone" its first input strip, not PipeWire's default devices,
  // which sit outside the mix. State comes from the config.json the daemon
  // writes; changes go over D-Bus like Pipeworks' own panel does.
  readonly property string pwBus: "io.github.pipeworks.Pipeworks"
  readonly property string pwPath: "/io/github/pipeworks/Pipeworks"
  property var pwConfig: ({})
  property bool pwRunning: false
  readonly property var pwOutput: pwConfig.outputs instanceof Array && pwConfig.outputs.length > 0 ? pwConfig.outputs[0] : null
  readonly property var pwInput: pwConfig.inputs instanceof Array && pwConfig.inputs.length > 0 ? pwConfig.inputs[0] : null
  readonly property bool pwOut: pwRunning && !!pwOutput
  readonly property bool pwIn: pwRunning && !!pwInput
  readonly property bool pwVolumeLocked: pwConfig.volume_locked === true

  FileView {
    path: Quickshell.env("HOME") + "/.config/pipeworks/config.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try { root.pwConfig = JSON.parse(text()) } catch (e) { return }
      root.syncPipeworks()
    }
  }
  function pwNumber(map, id, fallback) {
    var n = map && id !== undefined ? Number(map[id]) : NaN
    return isNaN(n) ? fallback : Math.max(0, Math.min(100, n))
  }
  function syncPipeworks() {
    if (root.pwOut) {
      var oid = String(root.pwOutput.id)
      if (!root.held(root.volumeHold)) root.volume = root.pwNumber(root.pwConfig.output_volume, oid, 100)
      root.volumeMuted = !!(root.pwConfig.output_muted && root.pwConfig.output_muted[oid])
    }
    if (root.pwIn) {
      var iid = String(root.pwInput.id)
      if (!root.held(root.micHold)) root.mic = root.pwNumber(root.pwConfig.volume, iid, 100)
      root.micMuted = !!(root.pwConfig.muted && root.pwConfig.muted[iid])
    }
  }
  // The flags, not pwRunning itself: a handler on pwRunning runs before the
  // bindings that depend on it have caught up.
  onPwOutChanged: syncPipeworks()
  onPwInChanged: syncPipeworks()
  Process {
    id: pwPing
    command: ["gdbus", "call", "--session", "--dest", root.pwBus, "--object-path", root.pwPath,
              "--method", "org.freedesktop.DBus.Peer.Ping"]
    onExited: function(code) { root.pwRunning = code === 0 }
  }
  Timer { interval: 5000; repeat: true; running: true; triggeredOnStart: true; onTriggered: if (!pwPing.running) pwPing.running = true }

  // Strip ids are user text heading into a GVariant literal.
  function pwQuoted(value) { return "'" + String(value).replace(/\\/g, "\\\\").replace(/'/g, "\\'") + "'" }
  // One call at a time, in order; a queued volume for the same strip is
  // replaced by the newer one so a fast drag does not build a backlog.
  property var pwQueue: []
  Process { id: pwAction; onRunningChanged: if (!running) root.pwDrain() }
  function pwDrain() {
    if (pwAction.running || root.pwQueue.length === 0) return
    pwAction.command = root.pwQueue.shift().argv
    pwAction.running = true
  }
  function pwActivate(name, parameter, key) {
    var call = { key: key || "", argv: ["gdbus", "call", "--session", "--dest", root.pwBus, "--object-path", root.pwPath,
                 "--method", "org.gtk.Actions.Activate", name, parameter, "{}"] }
    var q = root.pwQueue.filter(function(c) { return !key || c.key !== key })
    q.push(call)
    root.pwQueue = q
    root.pwDrain()
  }
  function setOutputVolume(percent) {
    if (root.pwOut) {
      if (root.pwVolumeLocked) return
      root.pwActivate("set-output-volume", "[<(" + root.pwQuoted(root.pwOutput.id) + ", " + Number(percent).toFixed(1) + ")>]", "out-vol")
    } else root.run(["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", (percent / 100).toFixed(2)])
  }
  function toggleOutputMute() {
    if (root.pwOut) root.pwActivate("toggle-output-mute", "[<" + root.pwQuoted(root.pwOutput.id) + ">]")
    else root.run(["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle"])
  }
  function setInputVolume(percent) {
    if (root.pwIn) {
      if (root.pwVolumeLocked) return
      root.pwActivate("set-volume", "[<(" + root.pwQuoted(root.pwInput.id) + ", " + Number(percent).toFixed(1) + ")>]", "in-vol")
    } else root.run(["wpctl", "set-volume", "@DEFAULT_AUDIO_SOURCE@", (percent / 100).toFixed(2)])
  }
  // Output devices Pipeworks can send Main to, from the state.json it writes.
  // It only polls for devices while someone is watching, so the panel asks it
  // to while open (renewed; the daemon drops a watch nobody renews).
  property var pwState: ({})
  FileView {
    path: Quickshell.env("HOME") + "/.config/pipeworks/state.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: { try { root.pwState = JSON.parse(text()) } catch (e) {} }
  }
  readonly property var pwOutputDevices: {
    var list = root.pwState.devices && root.pwState.devices.outputs instanceof Array ? root.pwState.devices.outputs : []
    return list.filter(function(d) { return d && typeof d.name === "string" && d.name !== "" }).slice(0, 24)
  }
  // Main's current device: the node its left port belongs to.
  readonly property string pwOutputSink: root.pwOutput && typeof root.pwOutput.port_l === "string"
    ? root.pwOutput.port_l.split(":")[0] : ""
  readonly property string pwOutputSinkLabel: {
    for (var i = 0; i < root.pwOutputDevices.length; i++)
      if (root.pwOutputDevices[i].name === root.pwOutputSink)
        return String(root.pwOutputDevices[i].description || root.pwOutputSink)
    return root.pwOutputSink !== "" ? root.pwOutputSink : "No device"
  }
  property bool devicesOpen: false
  onOpenedChanged: {
    if (!opened) { pinned = false; devicesOpen = false }
    if (pwRunning) pwActivate("set-state-watch", "[<" + (opened ? "true" : "false") + ">]", "watch")
  }
  Timer {
    interval: 5000; repeat: true; running: root.opened && root.pwRunning
    onTriggered: root.pwActivate("set-state-watch", "[<true>]", "watch")
  }
  function deviceIcon(name, description) {
    var n = (String(name) + " " + String(description)).toLowerCase()
    if (n.indexOf("bluez") >= 0) return "󰋋"          // headphones-bluetooth
    if (/headset|headphone|virtuoso|arctis|hyperx|usb/.test(n)) return "󰋋"
    if (n.indexOf("hdmi") >= 0 || n.indexOf("displayport") >= 0) return "󰍹" // monitor
    return "󰓃"                                          // speaker
  }
  function retargetMain(sink) {
    if (!root.pwOut || sink === root.pwOutputSink) { root.devicesOpen = false; return }
    root.pwActivate("retarget-output", "[<(" + root.pwQuoted(root.pwOutput.id) + ", " + root.pwQuoted(sink) + ")>]")
    root.devicesOpen = false
  }

  function unlockVolume() { root.pwActivate("set-volume-lock", "[<false>]") }
  function toggleInputMute() {
    if (root.pwIn) root.pwActivate("toggle-mute", "[<" + root.pwQuoted(root.pwInput.id) + ">]")
    else root.run(["omarchy-audio-input-mute"])
  }

  readonly property color fg: root.bar ? root.bar.foreground : Commons.Color.foreground
  readonly property color dim: Qt.rgba(fg.r, fg.g, fg.b, 0.6)
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family

  // Fixed script, no interpolated values: prints key=value lines.
  readonly property string probeScript: [
    "echo \"wifi=$(nmcli -t -f WIFI g 2>/dev/null)\"",
    "echo \"ssid=$(nmcli -t -f ACTIVE,SSID dev wifi 2>/dev/null | awk -F: '$1==\"yes\"{print substr($0,5); exit}')\"",
    "echo \"eth=$(nmcli -t -f TYPE,STATE dev 2>/dev/null | grep -c '^ethernet:connected')\"",
    "echo \"bt=$(bluetoothctl show 2>/dev/null | awk '/Powered:/{print $2; exit}')\"",
    "echo \"btdev=$(bluetoothctl devices Connected 2>/dev/null | head -n1 | cut -d' ' -f3-)\"",
    "echo \"vol=$(wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null)\"",
    "echo \"mic=$(wpctl get-volume @DEFAULT_AUDIO_SOURCE@ 2>/dev/null)\"",
    "echo \"bri=$(brightnessctl -m -c backlight 2>/dev/null | head -n1 | cut -d, -f4)\"",
    "echo \"night=$(omarchy-toggle-nightlight --status 2>/dev/null)\"",
    "echo \"idle=$(omarchy-toggle-idle status 2>/dev/null)\"",
    "echo \"dnd=$(omarchy-shell notifications isDnd 2>/dev/null)\""
  ].join("; ")

  function parseVolume(text) {
    var m = /Volume:\s*([0-9.]+)/.exec(String(text || ""))
    return { value: m ? Math.round(Math.min(1.5, Number(m[1])) * 100) : 0, muted: /MUTED/.test(String(text || "")) }
  }

  function applyProbe(text) {
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var eq = lines[i].indexOf("=")
      if (eq < 0) continue
      var key = lines[i].slice(0, eq), value = lines[i].slice(eq + 1).trim()
      if (key === "wifi") root.wifiOn = value === "enabled"
      else if (key === "ssid") root.ssid = value.replace(/\\:/g, ":").slice(0, 64)
      else if (key === "eth") root.ethernet = Number(value) > 0
      else if (key === "bt") root.btOn = value === "yes"
      else if (key === "btdev") root.btDevice = value.slice(0, 64)
      else if (key === "vol") { if (root.pwOut) continue; var v = parseVolume(value); if (!root.held(root.volumeHold)) root.volume = v.value; root.volumeMuted = v.muted }
      else if (key === "mic") { if (root.pwIn) continue; var m = parseVolume(value); if (!root.held(root.micHold)) root.mic = m.value; root.micMuted = m.muted }
      else if (key === "bri") { var b = parseInt(value, 10); if (!root.held(root.brightnessHold)) root.brightness = isNaN(b) ? -1 : b }
      else if (key === "night") root.nightLight = /"enabled"\s*:\s*true/.test(value)
      else if (key === "idle") root.stayAwake = /"enabled"\s*:\s*true/.test(value)
      else if (key === "dnd") root.dnd = value === "on"
    }
  }

  Process {
    id: probe
    command: ["bash", "-c", root.probeScript]
    stdout: StdioCollector { onStreamFinished: root.applyProbe(text) }
  }
  function refresh() { if (!probe.running) probe.running = true }
  function refreshSoon() { settleTimer.restart() }
  Timer { id: settleTimer; interval: 700; onTriggered: root.refresh() }
  Timer { interval: 2000; repeat: true; running: root.opened; triggeredOnStart: true; onTriggered: root.refresh() }

  function run(argv) { Quickshell.execDetached(argv) }
  // Full panels of the widgets this one stands in for.
  function openPanel(id) {
    root.close()
    run(["omarchy-shell", "-q", "shell", "summon", id, "{}"])
  }

  // ----------------------------------------------- hover open / close
  // Hover opens it; leaving both the icon and the card closes it. A click on
  // the icon pins it open until the next click (or a click elsewhere).
  property bool pinned: false
  property bool iconHovered: false
  property bool cardHovered: false
  onIconHoveredChanged: hoverChanged()
  onCardHoveredChanged: hoverChanged()
  function hoverChanged() {
    if (iconHovered && !opened) openTimer.restart()
    if (iconHovered || cardHovered) closeTimer.stop()
    else { openTimer.stop(); if (opened && !pinned) closeTimer.restart() }
  }
  Timer { id: openTimer; interval: 140; onTriggered: if (root.iconHovered && !root.opened) root.open() }
  Timer { id: closeTimer; interval: 380; onTriggered: if (!root.iconHovered && !root.cardHovered && !root.pinned) root.close() }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  HoverHandler { onHoveredChanged: root.iconHovered = hovered }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰙪"
    onPressed: function(b) {
      if (b !== Qt.LeftButton) return
      if (root.opened && root.pinned) { root.close(); return }
      root.pinned = true
      if (!root.opened) root.open()
    }
  }

  // Only the card takes the pointer while hover-opened, so the bar underneath
  // keeps reporting hover on the icon; pinned, the whole screen does, so a
  // click anywhere else dismisses it like any other panel.
  Region {
    id: cardRegion
    x: panel.cardOrigin.x; y: panel.cardOrigin.y
    width: panel.contentWidth; height: panel.drawnHeight
  }
  Region { id: fullRegion; width: panel.screenW; height: panel.screenH }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    mask: root.pinned ? fullRegion : cardRegion
    // A hover panel must not take keyboard focus from the window you are in.
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight, Style.space(620))

    content: Item {
      id: body
      implicitHeight: column.implicitHeight
      HoverHandler { onHoveredChanged: root.cardHovered = hovered }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(12)

        // ---------- connectivity tiles ----------
        Row {
          width: parent.width
          spacing: Style.space(10)

          Tile {
            width: (parent.width - parent.spacing) / 2
            on: root.wifiOn
            icon: !root.wifiOn ? "󰤭" : (root.ssid !== "" ? "󰤨" : (root.ethernet ? "󰈀" : "󰤯"))
            label: "Wi-Fi"
            detail: !root.wifiOn ? "Off" : (root.ssid !== "" ? root.ssid : (root.ethernet ? "Ethernet" : "Not connected"))
            onToggle: { root.wifiOn = !root.wifiOn; root.run(["nmcli", "radio", "wifi", root.wifiOn ? "on" : "off"]); root.refreshSoon() }
            onMore: root.openPanel("omarchy.network")
          }
          Tile {
            width: (parent.width - parent.spacing) / 2
            on: root.btOn
            icon: root.btOn ? (root.btDevice !== "" ? "󰂱" : "󰂯") : "󰂲"
            label: "Bluetooth"
            detail: !root.btOn ? "Off" : (root.btDevice !== "" ? root.btDevice : "On")
            onToggle: { root.btOn = !root.btOn; root.run(["omarchy-bluetooth-power", root.btOn ? "on" : "off"]); root.refreshSoon() }
            onMore: root.openPanel("omarchy.bluetooth")
          }
        }

        // ---------- quick toggles ----------
        Row {
          width: parent.width
          spacing: Style.space(10)

          Chip {
            width: (parent.width - parent.spacing * 2) / 3
            on: root.nightLight; icon: "󰖔"; label: "Night light"
            onToggle: { root.nightLight = !root.nightLight; root.run(["omarchy-toggle-nightlight"]); root.refreshSoon() }
          }
          Chip {
            width: (parent.width - parent.spacing * 2) / 3
            on: root.dnd; icon: root.dnd ? "󰂛" : "󰂚"; label: "Do not disturb"
            onToggle: { root.dnd = !root.dnd; root.run(["omarchy-toggle-notification-silencing"]); root.refreshSoon() }
          }
          Chip {
            width: (parent.width - parent.spacing * 2) / 3
            on: root.stayAwake; icon: "󰅶"; label: "Stay awake"
            onToggle: { root.stayAwake = !root.stayAwake; root.run(["omarchy-toggle-idle"]); root.refreshSoon() }
          }
        }

        PanelSeparator { width: parent.width; foreground: root.fg }

        // ---------- sliders ----------
        SliderRow {
          id: volumeRow
          width: parent.width
          title: root.pwOut ? "Sound · " + String(root.pwOutput.label || root.pwOutput.id) : "Sound"
          icon: root.volumeMuted || root.volume === 0 ? "󰝟" : (root.volume < 34 ? "󰕿" : (root.volume < 67 ? "󰖀" : "󰕾"))
          muted: root.volumeMuted
          value: root.volume
          maximum: 100
          actionIcon: "󰘮"; actionTip: "Pipeworks mixer"
          sliderRef: volumeSlider
          locked: root.pwOut && root.pwVolumeLocked
          onIconClicked: { root.volumeMuted = !root.volumeMuted; root.toggleOutputMute() }
          onAction: root.openPanel("pipeworks.mixer")
          PanelSlider {
            id: volumeSlider
            bar: root.bar
            anchors.fill: parent
            minimum: 0; maximum: 100; step: 1; integer: true
            value: root.volume
            onMoved: function(v) { root.volumeHold = Date.now() + 1500; root.volume = v; volumeApply.restart() }
            onReleased: function(v) { root.volumeHold = Date.now() + 1500; root.volume = v; volumeApply.restart() }
          }
        }
        // ---------- Main's output device (Pipeworks) ----------
        Column {
          width: parent.width
          visible: root.pwOut
          spacing: Style.space(4)

          Rectangle {
            width: parent.width
            height: Style.space(36)
            radius: Style.cornerRadius
            color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, deviceArea.containsMouse || root.devicesOpen ? 0.12 : 0.07)
            Behavior on color { ColorAnimation { duration: Style.duration(140) } }
            MouseArea { id: deviceArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.devicesOpen = !root.devicesOpen }
            PlainText {
              id: deviceGlyph
              anchors.left: parent.left; anchors.leftMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              text: root.deviceIcon(root.pwOutputSink, root.pwOutputSinkLabel)
              font.pixelSize: Style.font.icon
            }
            PlainText {
              anchors.left: deviceGlyph.right; anchors.leftMargin: Style.space(10)
              anchors.right: deviceChevron.left; anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              text: root.pwOutputSinkLabel
              font.pixelSize: Style.font.body
            }
            PlainText {
              id: deviceChevron
              anchors.right: parent.right; anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              text: root.devicesOpen ? "󰅃" : "󰅀"
              color: root.dim; font.pixelSize: Style.font.caption
            }
          }

          Repeater {
            model: root.devicesOpen ? root.pwOutputDevices : []
            Rectangle {
              required property var modelData
              readonly property bool current: modelData.name === root.pwOutputSink
              width: parent ? parent.width : 0
              height: Style.space(34)
              radius: Style.cornerRadius
              color: current ? Qt.rgba(Commons.Color.accent.r, Commons.Color.accent.g, Commons.Color.accent.b, 0.22)
                             : (pickArea.containsMouse ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.10) : "transparent")
              MouseArea { id: pickArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.retargetMain(modelData.name) }
              PlainText {
                id: pickGlyph
                anchors.left: parent.left; anchors.leftMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                text: root.deviceIcon(modelData.name, modelData.description)
                color: current ? Commons.Color.accent : root.fg
                font.pixelSize: Style.font.icon
              }
              PlainText {
                anchors.left: pickGlyph.right; anchors.leftMargin: Style.space(10)
                anchors.right: pickCheck.left; anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                text: String(modelData.description || modelData.name)
                font.pixelSize: Style.font.body
              }
              PlainText {
                id: pickCheck
                anchors.right: parent.right; anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                visible: current
                text: "󰄬"
                color: Commons.Color.accent; font.pixelSize: Style.font.caption
              }
            }
          }
          PlainText {
            visible: root.devicesOpen && root.pwOutputDevices.length === 0
            width: parent.width
            text: "Looking for devices…"
            color: root.dim; font.pixelSize: Style.font.caption
          }
        }

        Timer { id: volumeApply; interval: 40; onTriggered: root.setOutputVolume(root.volume) }

        SliderRow {
          width: parent.width
          title: root.pwIn ? "Microphone · " + String(root.pwInput.label || root.pwInput.id) : "Microphone"
          icon: root.micMuted ? "󰍭" : "󰍬"
          muted: root.micMuted
          value: root.mic
          maximum: 100
          sliderRef: micSlider
          locked: root.pwIn && root.pwVolumeLocked
          onIconClicked: { root.micMuted = !root.micMuted; root.toggleInputMute() }
          PanelSlider {
            id: micSlider
            bar: root.bar
            anchors.fill: parent
            minimum: 0; maximum: 100; step: 1; integer: true
            value: root.mic
            onMoved: function(v) { root.micHold = Date.now() + 1500; root.mic = v; micApply.restart() }
            onReleased: function(v) { root.micHold = Date.now() + 1500; root.mic = v; micApply.restart() }
          }
        }
        Timer { id: micApply; interval: 40; onTriggered: root.setInputVolume(root.mic) }

        SliderRow {
          width: parent.width
          visible: root.brightness >= 0
          title: "Brightness"
          icon: root.brightness < 34 ? "󰃞" : (root.brightness < 67 ? "󰃟" : "󰃠")
          value: Math.max(0, root.brightness)
          maximum: 100
          actionIcon: "󰍺"; actionTip: "Displays"
          sliderRef: brightnessSlider
          onAction: root.openPanel("crmne.hyprmoncfg")
          PanelSlider {
            id: brightnessSlider
            bar: root.bar
            anchors.fill: parent
            minimum: 1; maximum: 100; step: 1; integer: true
            value: Math.max(1, root.brightness)
            onMoved: function(v) { root.brightnessHold = Date.now() + 1500; root.brightness = v; brightnessApply.restart() }
            onReleased: function(v) { root.brightnessHold = Date.now() + 1500; root.brightness = v; brightnessApply.restart() }
          }
        }
        Timer { id: brightnessApply; interval: 40; onTriggered: root.run(["brightnessctl", "-q", "-c", "backlight", "set", Math.round(root.brightness) + "%"]) }
      }
    }
  }

  // ---------------------------------------------------------- pieces

  component PlainText: Text {
    textFormat: Text.PlainText
    color: root.fg
    font.family: root.fontFamily
    elide: Text.ElideRight
  }

  // A big tile: the round icon toggles, the rest opens the full panel.
  component Tile: Rectangle {
    id: tile
    property bool on: false
    property string icon: ""
    property string label: ""
    property string detail: ""
    signal toggle()
    signal more()
    height: Style.space(60)
    radius: Style.cornerRadius
    color: tileArea.containsMouse ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.12) : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.07)
    Behavior on color { ColorAnimation { duration: Style.duration(140) } }

    MouseArea { id: tileArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: tile.more() }

    Rectangle {
      id: knob
      anchors.left: parent.left; anchors.leftMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(36); height: width; radius: width / 2
      color: tile.on ? Commons.Color.accent : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.12)
      Behavior on color { ColorAnimation { duration: Style.duration(160) } }
      PlainText {
        anchors.centerIn: parent
        text: tile.icon
        color: tile.on ? Commons.Color.background : root.fg
        font.pixelSize: Style.font.icon
      }
      MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: tile.toggle() }
    }
    Column {
      anchors.left: knob.right; anchors.leftMargin: Style.space(10)
      anchors.right: chevron.left; anchors.rightMargin: Style.space(4)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(1)
      PlainText { width: parent.width; text: tile.label; font.pixelSize: Style.font.body; font.bold: true }
      PlainText { width: parent.width; text: tile.detail; color: root.dim; font.pixelSize: Style.font.caption }
    }
    PlainText {
      id: chevron
      anchors.right: parent.right; anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: "󰅂"; color: root.dim; font.pixelSize: Style.font.caption
    }
  }

  // A small toggle: icon over label, accent when on.
  component Chip: Rectangle {
    id: chip
    property bool on: false
    property string icon: ""
    property string label: ""
    signal toggle()
    height: Style.space(58)
    radius: Style.cornerRadius
    color: chip.on ? Qt.rgba(Commons.Color.accent.r, Commons.Color.accent.g, Commons.Color.accent.b, chipArea.containsMouse ? 0.32 : 0.24)
                   : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, chipArea.containsMouse ? 0.12 : 0.07)
    Behavior on color { ColorAnimation { duration: Style.duration(140) } }
    MouseArea { id: chipArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: chip.toggle() }
    Column {
      anchors.centerIn: parent
      width: parent.width - Style.space(8)
      spacing: Style.space(3)
      PlainText {
        anchors.horizontalCenter: parent.horizontalCenter
        text: chip.icon; font.pixelSize: Style.font.icon
        color: chip.on ? Commons.Color.accent : root.fg
      }
      PlainText {
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        text: chip.label; font.pixelSize: Style.font.caption
        color: chip.on ? root.fg : root.dim
      }
    }
  }

  // Header (title + value) over [icon | slider | shortcut].
  component SliderRow: Column {
    id: srow
    property string title: ""
    property string icon: ""
    property bool muted: false
    property real value: 0
    property real maximum: 100
    property string actionIcon: ""
    property string actionTip: ""
    property Item sliderRef: null
    // Pipeworks' volume lock: only its control surface may change levels.
    property bool locked: false
    default property alias slot: sliderHolder.data
    signal iconClicked()
    signal action()
    spacing: Style.space(4)

    Item {
      width: parent.width
      implicitHeight: header.implicitHeight
      PanelSectionHeader {
        id: header
        text: srow.title
        foreground: root.fg
        fontFamily: root.fontFamily
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
      }
      PlainText {
        anchors.right: parent.right; anchors.rightMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
        text: (srow.locked ? "󰌾  " : "") + (srow.muted ? "Muted" : Commons.I18n.formatNumber(Math.round(srow.sliderRef && srow.sliderRef.dragging ? srow.sliderRef.liveValue : srow.value)) + "%")
        color: srow.locked && lockArea.containsMouse ? root.fg : root.dim; font.pixelSize: Style.font.caption; font.bold: true
        MouseArea {
          id: lockArea
          anchors.fill: parent
          enabled: srow.locked
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.unlockVolume()
        }
      }
    }
    Item {
      width: parent.width
      height: Style.space(30)
      PanelActionButton {
        id: leadIcon
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        iconText: srow.icon
        foreground: srow.muted ? root.dim : root.fg
        fontFamily: root.fontFamily
        onClicked: srow.iconClicked()
      }
      Item {
        id: sliderHolder
        anchors.left: leadIcon.right; anchors.leftMargin: Style.space(8)
        anchors.right: actionButton.left; anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        height: parent.height
        opacity: srow.muted || srow.locked ? 0.45 : 1
        enabled: !srow.locked
      }
      PanelActionButton {
        id: actionButton
        visible: srow.actionIcon !== ""
        width: visible ? implicitWidth : 0
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        iconText: srow.actionIcon
        tooltipText: srow.actionTip
        foreground: root.fg
        fontFamily: root.fontFamily
        onClicked: srow.action()
      }
    }
  }
}
