import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// Headless state for the widget: runs inbox.py on a timer, holds the item
// list, raises a desktop notification for anything new, and exposes dismiss /
// restore. Everything that talks to GitHub lives in inbox.py.
//
// The point of the plugin is that nothing slips by, so a failing check must
// never look like an empty inbox: after staleAfterMin without a successful
// collect the bar turns urgent on its own.
Item {
  id: root

  property var settings: ({})
  // Set by the panel so the summary notification can open it.
  property var openPanel: null

  property var items: []
  property string viewer: ""
  property bool loading: false
  property bool loaded: false
  property bool truncated: false
  property string lastError: ""
  property double lastSuccessSec: 0
  property double nowSec: Date.now() / 1000

  readonly property string pythonPath: "/usr/bin/python3"
  readonly property string notifyPath: "/usr/bin/notify-send"
  readonly property int collectorTimeoutMs: 90000
  readonly property int maxOutputChars: 4194304

  readonly property int refreshIntervalMin: intSetting("refreshIntervalMin", 5, 1, 120)
  readonly property string owners: String(setting("owners", ""))
  readonly property bool excludeBots: boolSetting("excludeBots", false)
  readonly property bool participating: boolSetting("participating", true)
  readonly property bool notify: boolSetting("notify", true)
  readonly property bool hideWhenEmpty: boolSetting("hideWhenEmpty", false)
  readonly property int staleAfterMin: intSetting("staleAfterMin", 60, 10, 1440)

  readonly property string helperPath: Qt.resolvedUrl("inbox.py").toString().replace(/^file:\/\//, "")
  readonly property string iconPath: Qt.resolvedUrl("icon.svg").toString().replace(/^file:\/\//, "")
  readonly property string statePath: {
    var base = Quickshell.env("XDG_STATE_HOME")
    if (!base) base = Quickshell.env("HOME") + "/.local/state"
    return base + "/omarchy-maintainer-inbox/state.json"
  }

  readonly property var needs: items.filter(function (i) { return i.state === "needs" })
  readonly property var needsOwned: needs.filter(function (i) { return i.source !== "participating" })
  readonly property var needsReplies: needs.filter(function (i) { return i.source === "participating" })
  readonly property var muted: items.filter(function (i) { return i.state === "muted" })
  readonly property var waiting: items.filter(function (i) { return i.state === "waiting" })
  readonly property var dismissed: items.filter(function (i) { return i.state === "dismissed" })
  readonly property int needsCount: needs.length
  // No successful check for too long: say so instead of showing a calm zero.
  // Counted from startup until the first success, so one blip while the
  // network comes up after login or resume doesn't turn the bar red.
  readonly property double startedSec: Date.now() / 1000
  readonly property bool stale: lastError !== ""
    && (nowSec - (lastSuccessSec > 0 ? lastSuccessSec : startedSec)) > staleAfterMin * 60
  // Read by the unified tray ("attention": "attention").
  readonly property bool attention: needsCount > 0 || stale

  readonly property string summaryText: {
    if (stale) return "Can't reach GitHub: " + lastError
    if (!loaded && lastError !== "") return "Retrying: " + lastError
    if (!loaded) return "Checking…"
    if (needsCount === 0) return "Nothing waiting on you"
    return needsCount + (needsCount === 1 ? " item needs you" : " items need you")
  }

  property int _generation: 0
  property int _runningGeneration: -1
  property string _out: ""
  property string _err: ""
  property bool _overflow: false

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  function boolSetting(name, fallback) {
    var v = setting(name, fallback)
    if (typeof v === "boolean") return v
    var s = String(v).toLowerCase()
    return s === "true" || s === "1" || s === "yes"
  }

  function refresh() {
    if (collector.running) return
    _generation += 1
    _runningGeneration = _generation
    _out = ""
    _err = ""
    _overflow = false
    loading = true
    var cmd = [pythonPath, helperPath, "collect", "--state", statePath]
    if (owners.trim() !== "") cmd.push("--owners", owners.trim())
    if (excludeBots) cmd.push("--exclude-bots")
    if (participating) cmd.push("--participating")
    collector.command = cmd
    watchdog.restart()
    collector.running = true
  }

  function _append(chunk, isErr) {
    if (_overflow) return
    var cur = isErr ? _err : _out
    if (cur.length + chunk.length > maxOutputChars) { _overflow = true; return }
    if (isErr) _err = cur + chunk
    else _out = cur + chunk
  }

  // A failed check is retried after a minute rather than at the next poll.
  onLastErrorChanged: if (lastError !== "") retry.restart()
  Timer { id: retry; interval: 60000; repeat: false; onTriggered: root.refresh() }

  function apply(raw) {
    var data
    try { data = JSON.parse(raw) } catch (e) { lastError = "inbox.py printed invalid JSON"; return }
    if (!data || data.ok !== true) {
      lastError = data && data.error ? String(data.error) : "unknown error"
      return
    }
    items = data.items || []
    viewer = data.viewer || ""
    truncated = data.truncated === true
    lastError = ""
    lastSuccessSec = Date.now() / 1000
    loaded = true
    if (notify) announce(data.fresh || [])
  }

  function findItem(id) {
    for (var i = 0; i < items.length; i++) if (items[i].id === id) return items[i]
    return null
  }

  // A burst (first run, back from a week offline) gets one summary instead of
  // a wall of toasts; a handful get one each, clickable to the item.
  function announce(freshIds) {
    var fresh = []
    for (var i = 0; i < freshIds.length; i++) {
      var it = findItem(freshIds[i])
      if (it) fresh.push(it)
    }
    if (fresh.length === 0) return
    if (fresh.length > 3) {
      var repos = {}
      fresh.forEach(function (f) { repos[f.repo.split("/")[1]] = true })
      sendNotification(fresh.length + " issues and pull requests need you",
                       Object.keys(repos).join(", "), "")
      return
    }
    fresh.forEach(notifyItem)
  }

  function notifyItem(f) {
    var what = f.kind === "pr" ? "Pull request" : "Issue"
    var body = f.source === "participating" ? "New reply from " + f.lastOtherBy + " · " + f.repo
      : what + (f.lastOtherAt === f.createdAt ? " opened by " : " · new activity from ") + f.lastOtherBy
    sendNotification(f.repo.split("/")[1] + " #" + f.number + ": " + f.title, body, f.url)
  }

  // Re-sends the newest waiting item, to check the notification click.
  function testNotification() {
    if (needs.length > 0) { notifyItem(needs[0]); return "sent: " + needs[0].url }
    sendNotification("Maintainer Inbox test", "Nothing is waiting on you; clicking opens the inbox.", "")
    return "sent: summary"
  }

  Component {
    id: notificationProcess
    Process {
      id: notifier
      property string url: ""
      property string action: ""
      stdout: SplitParser { onRead: function (line) { notifier.action = String(line).trim() } }
      onExited: {
        if (action === "default" || action === "open") {
          if (url !== "") root.openUrl(url)
          else if (root.openPanel) root.openPanel()
        }
        destroy()
      }
    }
  }

  function sendNotification(summary, body, url) {
    var p = notificationProcess.createObject(root, { url: url })
    p.command = [notifyPath, "--app-name=Maintainer Inbox", "--app-icon=" + iconPath,
                 "--action=default=Open", "--action=open=" + (url !== "" ? "Open on GitHub" : "Show inbox"),
                 "--", summary, body]
    p.running = true
  }

  function openUrl(url) {
    // Only ever hand GitHub links to the browser.
    if (!/^https:\/\/github\.com\//.test(String(url))) return
    Qt.openUrlExternally(url)
  }

  function setDismissed(item, on) { _setFlag(item, on ? "dismiss" : "restore", on ? "dismissed" : "needs") }

  // Muting is for good: unlike a dismissal, new activity does not bring it back.
  function setMuted(item, on) { _setFlag(item, on ? "mute" : "unmute", on ? "muted" : "needs") }

  function _setFlag(item, command, newState) {
    if (!item || typeof item.id !== "string" || !findItem(item.id)) return
    // Move it locally at once; the helper persists it and the next collect
    // settles the real state (an unmuted item may be "waiting", not "needs").
    items = items.map(function (i) {
      if (i.id !== item.id) return i
      var copy = Object.assign({}, i)
      copy.state = newState
      return copy
    })
    var p = dismissProcess.createObject(root)
    p.command = [pythonPath, helperPath, command, "--state", statePath, "--id", item.id]
    p.running = true
    if (command === "unmute" || command === "restore") settle.restart()
  }

  Timer { id: settle; interval: 1500; repeat: false; onTriggered: root.refresh() }

  Component {
    id: dismissProcess
    Process {
      onExited: function (code) {
        if (code !== 0) root.lastError = "Could not save the change (exit " + code + ")"
        destroy()
      }
    }
  }

  Process {
    id: collector
    running: false
    command: []
    stdout: SplitParser { splitMarker: ""; onRead: function (d) { root._append(String(d), false) } }
    stderr: SplitParser { splitMarker: ""; onRead: function (d) { root._append(String(d), true) } }
    onExited: function (code) {
      watchdog.stop()
      var mine = root._runningGeneration === root._generation
      root._runningGeneration = -1
      root.loading = false
      root.nowSec = Date.now() / 1000
      if (!mine) return
      if (root._overflow) { root.lastError = "inbox.py output too large; discarded"; return }
      if (root._out.trim() !== "") root.apply(root._out)
      else root.lastError = root._err.trim() !== "" ? root._err.trim().split("\n").pop() : "inbox.py exited " + code
    }
  }

  Timer {
    id: watchdog
    interval: root.collectorTimeoutMs
    repeat: false
    onTriggered: {
      if (!collector.running) return
      root._runningGeneration = -1
      root.loading = false
      root.lastError = "GitHub check did not finish within " + Math.round(root.collectorTimeoutMs / 1000) + "s"
      collector.signal(9)
    }
  }

  Timer {
    interval: root.refreshIntervalMin * 60000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Ages and the stale check move without a collect. A minute tick also
  // catches a resume: the poll timer does not fire for time spent asleep.
  Timer {
    interval: 60000
    running: true
    repeat: true
    onTriggered: {
      var before = root.nowSec
      root.nowSec = Date.now() / 1000
      if (root.nowSec - before > 180) root.refresh()
    }
  }

  // ---------------------------------------------------------------- settings

  // Settings persist through `omarchy bar set`, which rewrites shell.json and
  // pushes a new `settings` object back; serialised so two writes can't race.
  property string widgetId: ""
  readonly property string omarchyBarPath: "/usr/bin/omarchy-bar"
  property var _settingQueue: []

  function saveSetting(key, value, asJson) {
    if (widgetId === "") return
    var cmd = [omarchyBarPath, "set", widgetId, String(key), String(value)]
    if (asJson) cmd.push("--json")
    var q = _settingQueue
    q.push(cmd)
    _settingQueue = q
    _pumpSettings()
  }

  function _pumpSettings() {
    if (settingProcess.running || _settingQueue.length === 0) return
    var q = _settingQueue
    settingProcess.command = q.shift()
    _settingQueue = q
    settingProcess.running = true
  }

  Process {
    id: settingProcess
    running: false
    command: []
    onExited: function (code) {
      if (code !== 0) root.lastError = "Could not save setting (exit " + code + ")"
      root._pumpSettings()
    }
  }

  onOwnersChanged: refresh()
  onExcludeBotsChanged: refresh()
  onParticipatingChanged: refresh()

  Component.onDestruction: {
    watchdog.stop()
    _runningGeneration = -1
    if (collector.running) collector.running = false
  }
}
