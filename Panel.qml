import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar widget plus its drop-down panel. The bar shows the issue glyph with the
// number of items waiting on you, in the urgent color while that is above
// zero or GitHub could not be reached. The panel lists them newest activity
// first: needs you, then waiting on them, then dismissed.
Panel {
  id: root
  moduleName: "io.github.davidboulay.maintainer-inbox"
  ipcTarget: "io.github.davidboulay.maintainer-inbox"
  manageIpc: false

  property int cursor: 0
  property bool cursorActive: false
  property bool showSettings: false
  property bool showWaiting: false
  property bool showDismissed: false
  property bool showMuted: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string glyph: "" // nf-oct-issue_opened
  readonly property string barText: inbox.stale ? glyph + " !"
    : (inbox.needsCount > 0 ? glyph + " " + inbox.needsCount : glyph)

  // Keyboard order: what is on screen, top to bottom.
  readonly property var rows: inbox.needsOwned
    .concat(inbox.needsReplies)
    .concat(showWaiting ? inbox.waiting : [])
    .concat(showDismissed ? inbox.dismissed : [])
    .concat(showMuted ? inbox.muted : [])

  // Also read by the unified tray.
  readonly property bool attention: inbox.attention

  visible: !(inbox.hideWhenEmpty && inbox.loaded && !inbox.attention)
  implicitWidth: visible ? button.implicitWidth : 0
  implicitHeight: button.implicitHeight

  function selected() {
    if (rows.length === 0) return null
    return rows[Math.max(0, Math.min(cursor, rows.length - 1))]
  }

  function moveCursor(dy) {
    cursorActive = true
    if (rows.length === 0) return
    cursor = Math.max(0, Math.min(rows.length - 1, cursor + dy))
  }

  function age(iso) {
    var t = Date.parse(iso) / 1000
    if (!isFinite(t)) return ""
    var s = Math.max(0, inbox.nowSec - t)
    if (s < 3600) return Math.max(1, Math.round(s / 60)) + "m"
    if (s < 86400) return Math.round(s / 3600) + "h"
    if (s < 86400 * 60) return Math.round(s / 86400) + "d"
    return Math.round(s / (86400 * 30)) + "mo"
  }

  function detail(item) {
    var who = item.lastOtherAt === item.createdAt ? "opened by " : "last from "
    var repo = item.source === "participating" || item.repo.split("/")[0] !== inbox.viewer ? item.repo : item.repo.split("/")[1]
    var text = repo + " #" + item.number + " · " + who + item.lastOtherBy + " · " + age(item.lastOtherAt) + " ago"
    if (item.state === "waiting") text += " · you replied " + age(item.lastMineAt) + " ago"
    if (item.draft) text += " · draft"
    return text
  }

  function open() {
    inbox.refresh()
    root.controller.show()
  }

  function close() { root.controller.hide() }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function refresh() { inbox.refresh() }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root, direction)
    return false
  }

  Service {
    id: inbox
    settings: root.settings
    widgetId: root.moduleName
    openPanel: root.open
  }

  onOpenedChanged: if (!opened) { root.showSettings = false; root.cursorActive = false }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { inbox.refresh(); return "ok" }
    function status(): string { return inbox.summaryText }
    function count(): string { return String(inbox.needsCount) }
    function testNotification(): string { return inbox.testNotification() }
    function debug(): string {
      return JSON.stringify({ loaded: inbox.loaded, loading: inbox.loading, stale: inbox.stale, lastError: inbox.lastError,
        lastSuccessSec: inbox.lastSuccessSec, startedSec: inbox.startedSec, nowSec: inbox.nowSec,
        staleAfterMin: inbox.staleAfterMin, items: inbox.items.length, needs: inbox.needsCount })
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barText
    active: inbox.attention
    dimmed: !inbox.loaded && !inbox.stale
    tooltipText: inbox.summaryText
    onPressed: function (buttonCode) {
      if (buttonCode === Qt.MiddleButton) inbox.refresh()
      else root.toggle()
    }
  }

  component ItemRow: CursorSurface {
    id: row
    required property var item
    readonly property int rowIndex: root.rows.indexOf(item)

    width: parent ? parent.width : 0
    implicitHeight: rowLayout.implicitHeight + Style.space(12)
    foreground: root.foreground
    hasCursor: root.cursorActive && root.cursor === rowIndex

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      onEntered: { root.cursorActive = true; root.cursor = row.rowIndex }
      onClicked: inbox.openUrl(row.item.url)
    }

    RowLayout {
      id: rowLayout
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(10)

      Text {
        Layout.alignment: Qt.AlignVCenter
        textFormat: Text.PlainText
        text: row.item.kind === "pr" ? "" : "" // git-pull-request / issue-opened
        color: row.item.state === "needs" ? root.urgent : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.iconLarge
        renderType: Text.NativeRendering
      }

      Column {
        Layout.fillWidth: true
        spacing: Style.space(2)

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: row.item.title
          color: row.item.state === "needs" ? root.foreground : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: row.item.state === "needs"
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: root.detail(row.item)
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      PanelActionButton {
        Layout.alignment: Qt.AlignVCenter
        iconText: row.item.state === "muted" ? "󰂚" : "󰂛"
        tooltipText: row.item.state === "muted" ? "Unmute (m)" : "Mute: never show or notify again (m)"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: inbox.setMuted(row.item, row.item.state !== "muted")
      }

      PanelActionButton {
        Layout.alignment: Qt.AlignVCenter
        visible: row.item.state === "needs" || row.item.state === "dismissed"
        iconText: row.item.state === "dismissed" ? "󰑐" : "󰅖"
        tooltipText: row.item.state === "dismissed" ? "Bring back (d)" : "Dismiss until new activity (d)"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: inbox.setDismissed(row.item, row.item.state !== "dismissed")
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function (dx, dy) { if (dy !== 0) root.moveCursor(dy) }
      onActivateRequested: { var s = root.selected(); if (root.cursorActive && s) inbox.openUrl(s.url) }
      onCloseRequested: { if (root.showSettings) root.showSettings = false; else root.close() }
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onTextKey: function (t) {
        var s = root.selected()
        if (t === "r" || t === "R") inbox.refresh()
        else if ((t === "d" || t === "D") && s && (s.state === "needs" || s.state === "dismissed")) inbox.setDismissed(s, s.state !== "dismissed")
        else if ((t === "m" || t === "M") && s) inbox.setMuted(s, s.state !== "muted")
        else if (t === "u" || t === "U") root.showMuted = !root.showMuted
        else if (t === "w" || t === "W") root.showWaiting = !root.showWaiting
        else if (t === "h" || t === "H") root.showDismissed = !root.showDismissed
        else if (t === ",") root.showSettings = !root.showSettings
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "Maintainer inbox"
            meta: inbox.summaryText
            detail: inbox.viewer !== "" ? "Watching " + (inbox.owners.trim() !== "" ? inbox.viewer + ", " + inbox.owners : inbox.viewer) + (inbox.participating ? " and your conversations" : "") : ""
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: root.glyph
                color: inbox.attention ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
                renderType: Text.NativeRendering
              }
            }
            trailingControl: Component {
              Row {
                spacing: Style.space(4)

                PanelActionButton {
                  iconText: "󰑓"
                  tooltipText: "Refresh (r)"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  enabled: !inbox.loading
                  visible: !root.showSettings
                  onClicked: inbox.refresh()
                }

                PanelActionButton {
                  iconText: root.showSettings ? "󰅁" : "󰒓"
                  tooltipText: root.showSettings ? "Back (esc)" : "Settings (,)"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.showSettings = !root.showSettings
                }
              }
            }
          }

          // ------------------------------------------------------- settings
          Column {
            visible: root.showSettings
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader { text: "WHAT TO WATCH"; foreground: root.foreground; fontFamily: root.fontFamily }

            TextField {
              width: parent.width
              foreground: root.foreground
              placeholderText: "Also watch: lojel, lojel/lojel-wp, …"
              text: inbox.owners
              onAccepted: inbox.saveSetting("owners", text, false)
              Keys.onEscapePressed: root.showSettings = false
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: "Comma-separated. An owner or organization covers all its repositories; owner/repo just that one. Your own account is always included. Press Enter to apply."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Toggle {
              width: parent.width
              label: "Replies in your conversations"
              description: "Issues and PRs anywhere on GitHub that you opened, commented on, or were mentioned or assigned in, when someone answers after you. Mute the ones you're done with."
              checked: inbox.participating
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: inbox.saveSetting("participating", inbox.participating ? "false" : "true", true)
            }

            Toggle {
              width: parent.width
              label: "Ignore bots"
              description: "Skip items opened by Dependabot, Renovate and other bot accounts."
              checked: inbox.excludeBots
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: inbox.saveSetting("excludeBots", inbox.excludeBots ? "false" : "true", true)
            }

            PanelSeparator { foreground: root.foreground }
            PanelSectionHeader { text: "ALERTS"; foreground: root.foreground; fontFamily: root.fontFamily }

            Toggle {
              width: parent.width
              label: "Desktop notification for new items"
              description: "One per new issue, PR or reply; a single summary when more than three arrive at once."
              checked: inbox.notify
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: inbox.saveSetting("notify", inbox.notify ? "false" : "true", true)
            }

            Toggle {
              width: parent.width
              label: "Hide the widget when nothing needs you"
              description: "It comes back as soon as something arrives or GitHub can't be reached."
              checked: inbox.hideWhenEmpty
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: inbox.saveSetting("hideWhenEmpty", inbox.hideWhenEmpty ? "false" : "true", true)
            }

            NumberField {
              label: "Check every (minutes)"
              value: inbox.refreshIntervalMin
              from: 1
              to: 120
              stepSize: 1
              foreground: root.foreground
              fontFamily: root.fontFamily
              onModified: function (v) { inbox.saveSetting("refreshIntervalMin", v, true) }
            }

            NumberField {
              label: "Warn after failing for (minutes)"
              value: inbox.staleAfterMin
              from: 10
              to: 1440
              stepSize: 10
              foreground: root.foreground
              fontFamily: root.fontFamily
              onModified: function (v) { inbox.saveSetting("staleAfterMin", v, true) }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: !root.showSettings && inbox.lastError !== ""
            width: parent.width
            text: inbox.lastError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Column {
            visible: !root.showSettings && inbox.loaded
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "ON YOUR REPOS · " + inbox.needsOwned.length
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              visible: inbox.needsOwned.length === 0
              textFormat: Text.PlainText
              width: parent.width
              text: "Nothing is waiting on you."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Repeater {
              model: inbox.needsOwned
              ItemRow { required property var modelData; item: modelData }
            }

            PanelSeparator { visible: inbox.needsReplies.length > 0; foreground: root.foreground }

            PanelSectionHeader {
              visible: inbox.needsReplies.length > 0
              text: "REPLIES TO YOU · " + inbox.needsReplies.length
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: inbox.needsReplies
              ItemRow { required property var modelData; item: modelData }
            }

            PanelSeparator { visible: inbox.waiting.length > 0; foreground: root.foreground }

            CursorSurface {
              visible: inbox.waiting.length > 0
              width: parent.width
              implicitHeight: waitingHeader.implicitHeight + Style.space(8)
              foreground: root.foreground
              MouseArea { anchors.fill: parent; onClicked: root.showWaiting = !root.showWaiting }
              PanelSectionHeader {
                id: waitingHeader
                anchors.verticalCenter: parent.verticalCenter
                text: (root.showWaiting ? "▾ " : "▸ ") + "WAITING ON THEM · " + inbox.waiting.length
                foreground: root.foreground
                fontFamily: root.fontFamily
              }
            }

            Repeater {
              model: root.showWaiting ? inbox.waiting : []
              ItemRow { required property var modelData; item: modelData }
            }

            CursorSurface {
              visible: inbox.dismissed.length > 0
              width: parent.width
              implicitHeight: dismissedHeader.implicitHeight + Style.space(8)
              foreground: root.foreground
              MouseArea { anchors.fill: parent; onClicked: root.showDismissed = !root.showDismissed }
              PanelSectionHeader {
                id: dismissedHeader
                anchors.verticalCenter: parent.verticalCenter
                text: (root.showDismissed ? "▾ " : "▸ ") + "DISMISSED · " + inbox.dismissed.length
                foreground: root.foreground
                fontFamily: root.fontFamily
              }
            }

            Repeater {
              model: root.showDismissed ? inbox.dismissed : []
              ItemRow { required property var modelData; item: modelData }
            }

            CursorSurface {
              visible: inbox.muted.length > 0
              width: parent.width
              implicitHeight: mutedHeader.implicitHeight + Style.space(8)
              foreground: root.foreground
              MouseArea { anchors.fill: parent; onClicked: root.showMuted = !root.showMuted }
              PanelSectionHeader {
                id: mutedHeader
                anchors.verticalCenter: parent.verticalCenter
                text: (root.showMuted ? "▾ " : "▸ ") + "MUTED · " + inbox.muted.length
                foreground: root.foreground
                fontFamily: root.fontFamily
              }
            }

            Repeater {
              model: root.showMuted ? inbox.muted : []
              ItemRow { required property var modelData; item: modelData }
            }
          }

          PanelSeparator { visible: !root.showSettings; foreground: root.foreground }

          Text {
            textFormat: Text.PlainText
            visible: !root.showSettings
            width: parent.width
            text: "j/k select · enter open · d dismiss · m mute · w waiting · h dismissed · u muted · r refresh · , settings"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }
}
