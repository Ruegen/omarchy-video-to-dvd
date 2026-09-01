import QtQuick
import Quickshell
import Quickshell.Io

// Tiny locale helper: flat JSON maps in i18n/<tag>.json (BCP-47 / ISO 639).
// Resolve Qt.locale().name, then LANGUAGE / LANG, trying de_DE.json → de.json → en.json.
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

  FileView {
    id: jsonView
    blockLoading: true
    preload: false
    printErrors: false
  }

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

  function jsonPath(name) {
    var u = Qt.resolvedUrl("i18n/" + name)
    return u.toString().replace("file://", "")
  }

  function loadJson(name) {
    jsonView.path = root.jsonPath(name)
    try {
      var txt = jsonView.text()
      if (!txt)
        return null
      return JSON.parse(txt)
    } catch (e) {
      return null
    }
  }

  function load() {
    var en = root.loadJson("en.json") || {}
    root.fallback = en
    var cands = root.candidates()
    var chosen = en
    var tag = "en"
    for (var i = 0; i < cands.length; i++) {
      var c = cands[i]
      var data = root.loadJson(c + ".json")
      if (data) {
        chosen = data
        tag = c
        break
      }
    }
    root.strings = chosen
    root.localeTag = tag
    root.ready = true
    root.revision++
  }

  Component.onCompleted: root.load()
}
