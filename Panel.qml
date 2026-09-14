import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Kcd.js" as Kcd

// Night Drive dashboard for kcd (redesigned per REVIEW.md + design.svg):
// auto-selected paired phone, battery, compact 120px media card with transport
// cluster and Canvas wave seeker, quick-action tiles, version footer.
Panel {
  id: root
  moduleName: "bet.kcd"
  ipcTarget: "bet.kcd"
  manageIpc: false

  property var anchorItem: null
  property bool openedFromHotkey: false

  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ---- IO engine (Step 4 split): all kcd state, processes and
  // timers live in KcdIo. This root keeps panel chrome, the BarWidget
  // contract, and thin wrappers.
  KcdIo {
    id: io
    panelOpen: root.opened
  }

  // Read-only views the UI sections and BarWidget.qml consume.
  readonly property string barLabel: io.barLabel
  readonly property string barTooltip: io.barTooltip
  readonly property bool liveConnected: io.liveConnected
  readonly property var autoDevice: io.autoDevice
  readonly property string pairedName: io.pairedName
  readonly property string deviceId: io.deviceId
  readonly property string deviceName: io.deviceName
  readonly property int batteryCharge: io.batteryCharge
  readonly property bool batteryCharging: io.batteryCharging
  readonly property var track: io.track
  readonly property double displayPos: io.displayPos
  readonly property double trackLength: io.trackLength
  readonly property string lastSeenText: io.lastSeenText
  readonly property string kcdVersion: io.kcdVersion
  readonly property bool hasTrack: io.hasTrack
  readonly property bool usableArt: io.usableArt
  readonly property bool playing: io.playing
  readonly property string uiState: io.uiState
  readonly property bool pairing: io.pairing
  readonly property bool startingDaemon: io.startingDaemon

  // Thin wrappers — functions can't alias.
  function refresh(forceDevices) { io.refresh(forceDevices) }
  function togglePairing() { io.togglePairing() }
  function startDaemon() { io.startDaemon() }
  function runTile(tile) { io.runTile(tile) }
  function mediaAction(action) { io.mediaAction(action) }
  // shareFile() splits at the panel boundary: guard + close here (UI),
  // pick-and-send in io (process spawn).
  function shareFile() {
    if (root.deviceId === "") return
    root.close()
    io.shareFile(root.deviceId, root.deviceName)
  }

  // shareScreenshot() splits at the same boundary: guard + close here
  // (UI), capture-and-send in io (process spawn).
  function shareScreenshot() {
    if (root.deviceId === "") return
    root.close()
    io.screenshotShare(root.deviceId, root.deviceName)
  }

  // ---- Panel theming (consumed by the UI sections below).
  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property color contentDim: Qt.darker(contentForeground, 1.5)
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
    root.refresh(false)
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    root.refresh(false)
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function closeForPopoutSwitch() {
    if (root.controller && typeof root.controller.hide === "function") root.controller.hide()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
    else if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  // ---- IO: one-shot hydration (CLI) + live stream (kcd watch).
  Component.onCompleted: root.refresh()


  // Footer gear: edit kcd.toml in Neovim via the user's terminal
  // ($TERMINAL, falling back to xdg-terminal-exec).
  function openSettings() {
    var term = Quickshell.env("TERMINAL")
    if (!term) term = "xdg-terminal-exec"
    Quickshell.execDetached([term, "nvim", Kcd.configTomlPath(Quickshell.env("HOME"), Quickshell.env("XDG_CONFIG_HOME"))])
  }

  // Local interpolation so the wave playhead creeps while playing:

  // ================= MAIN INTERFACE =================
  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(dashColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: dashScroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: dashColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: dashColumn
          width: dashScroll.width
          spacing: Style.space(12)

          // ---- 1. Header (ready state only; Step 2 split)
          PanelHeader {
            width: parent.width
            visible: root.uiState === "ready"
            deviceName: root.deviceName
            liveConnected: root.liveConnected
            batteryCharge: root.batteryCharge
            batteryCharging: root.batteryCharging
            networkTooltip: root.liveConnected
              ? (root.autoDevice && root.autoDevice.signal ? "Phone network: " + root.autoDevice.signal.label : "Phone on local network")
              : "Phone offline"
            lastSeenText: root.lastSeenText
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
          }


          // ---- 2. Compact media card (Step 3 split)
          MediaCard {
            width: parent.width
            visible: root.uiState === "ready"
            hasTrack: root.hasTrack
            track: root.track
            usableArt: root.usableArt
            playing: root.playing
            liveConnected: root.liveConnected
            displayPos: root.displayPos
            trackLength: root.trackLength
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            onMediaAction: function(action) { root.mediaAction(action) }
          }


          // ---- 3. Quick actions (ready state only; Step 1 split)
          QuickActionsRow {
            width: parent.width
            visible: root.uiState === "ready"
            liveConnected: root.liveConnected
            deviceName: root.deviceName
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            onTileTapped: function(tile) { root.runTile(tile) }
            onShareRequested: root.shareFile()
            onScreenshotRequested: root.shareScreenshot()
          }

          // ---- State panels (exactly one is ever visible)
          KcdMissing {
            visible: root.uiState === "missing"
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            onRetryRequested: root.refresh()
          }

          KcdUnpaired {
            visible: root.uiState === "down" || root.uiState === "unpaired" || root.uiState === "offline"
            mode: root.uiState === "down" ? "down" : (root.uiState === "offline" ? "offline" : "unpaired")
            deviceName: root.pairedName
            pairing: root.pairing
            startingDaemon: root.startingDaemon
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            onRetryRequested: root.refresh()
            onPairRequested: root.togglePairing()
            onDaemonStartRequested: root.startDaemon()
          }

          // ---- 4. Footer (live engine version, manifest fallback)
          Item {
            width: parent.width
            height: Math.max(footerLeft.height, footerRight.height)

            Row {
              id: footerLeft
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)

              Text {
                id: settingsGlyph
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: ""
                color: settingsMouse.containsMouse ? root.contentForeground : root.contentDim
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.body

                MouseArea {
                  id: settingsMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.openSettings()
                }

                PanelToolTip {
                  visible: settingsMouse.containsMouse
                  text: "Open kcd.toml in Neovim"
                  fontFamily: root.contentFontFamily
                }
              }

              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: "KDE Connect"
                color: root.contentDim
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
                font.bold: true
              }
            }

            Text {
              id: footerRight
              textFormat: Text.PlainText
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: "kcd " + root.kcdVersion
              color: versionMouse.containsMouse ? root.contentForeground : root.contentDim
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption

              MouseArea {
                id: versionMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: Qt.openUrlExternally("https://github.com/bethropolis/kcd")
              }

              PanelToolTip {
                visible: versionMouse.containsMouse
                text: "Open kcd on GitHub"
                fontFamily: root.contentFontFamily
              }
            }
          }
        }
      }
    }
  }
}
