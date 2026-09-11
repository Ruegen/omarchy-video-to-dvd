import QtQuick
import Quickshell
import Quickshell.Io

// Tiny locale helper: flat JSON maps in i18n/<tag>.json (BCP-47 / ISO 639).
// Resolve Qt.locale().name, then LANGUAGE / LANG, trying de_DE.json → de.json → en.json.
// Files are read by oma-dvd (no-follow, size-capped); FileView is not used.
Item {
  id: root
  visible: false
  width: 0
  height: 0

  property var strings: ({})
  property var fallback: ({})
  property string localeTag: "en"
  property int revision: 0
  property bool ready: false
  property string helperPath: Qt.resolvedUrl("oma-dvd").toString().replace("file://", "")

  function t(key) {
    var _dep = root.revision
    var s = root.strings && root.strings[key]
    if (s === undefined || s === "")
      s = root.fallback && root.fallback[key]
    if (s === undefined || s === "")
      s = key
    s = String(s)
    for (var i = 1; i < arguments.length; i++)
      s = s.split("%" + i).join(String(arguments[i]))
    return s
  }

  function envVal(name) {
    try {
      return Quickshell.env(name) || ""
    } catch (e) {
      return ""
    }
  }

  function normalizeTag(raw) {
    if (!raw)
      return ""
    var s = String(raw).trim()
    if (!s)
      return ""
    s = s.split(".")[0].split("@")[0]
    if (s === "C" || s === "POSIX")
      return ""
    return s.replace(/-/g, "_")
  }

  function pushTag(list, seen, raw) {
    var tag = root.normalizeTag(raw)
    if (!tag)
      return
    if (!seen[tag]) {
      seen[tag] = true
      list.push(tag)
    }
    var lang = tag.split("_")[0].toLowerCase()
    if (lang && !seen[lang]) {
      seen[lang] = true
      list.push(lang)
    }
  }

  function candidates() {
    var list = []
    var seen = {}
    root.pushTag(list, seen, Qt.locale().name)
    var language = root.envVal("LANGUAGE")
    if (language) {
      var parts = language.split(":")
      for (var i = 0; i < parts.length; i++)
        root.pushTag(list, seen, parts[i])
    }
    root.pushTag(list, seen, root.envVal("LC_ALL"))
    root.pushTag(list, seen, root.envVal("LC_MESSAGES"))
    root.pushTag(list, seen, root.envVal("LANG"))
    return list
  }

  function jsonName(tag) {
    var name = String(tag) + ".json"
    if (!/^[A-Za-z]{2,8}(_[A-Za-z0-9]{1,16})?\.json$/.test(name))
      return ""
    return name
  }

  function applyPayload(json) {
    try {
      var data = JSON.parse(json)
      if (!data || typeof data !== "object")
        return
      if (typeof data.tag !== "string" || typeof data.fallback !== "object" || typeof data.strings !== "object")
        return
      root.fallback = data.fallback
      root.strings = data.strings
      root.localeTag = data.tag
      root.ready = true
      root.revision++
    } catch (e) {}
  }

  Process {
    id: i18nProc
    stdout: SplitParser {
      onRead: function(line) {
        if (line.indexOf("I18N:") !== 0)
          return
        root.applyPayload(line.substring(5))
      }
    }
  }

  function load() {
    var args = [root.helperPath, "read-i18n", "en.json"]
    var cands = root.candidates()
    for (var i = 0; i < cands.length; i++) {
      var name = root.jsonName(cands[i])
      if (!name || name === "en.json")
        continue
      args.push(name)
    }
    i18nProc.command = args
    i18nProc.running = true
  }

  Component.onCompleted: root.load()
}
