// Pure formatting helpers for NVMe Health (no Qt).

// Keep in sync with status.py MAX_JSON_BYTES (defense in depth before parse).
var MAX_STATUS_CHARS = 32768

function asInt(value, fallback) {
  var n = Number(value)
  if (!isFinite(n)) return fallback
  return Math.round(n)
}

function clampStatusText(text) {
  var s = String(text || "")
  if (s.length > MAX_STATUS_CHARS)
    return s.substring(0, MAX_STATUS_CHARS)
  return s
}

function formatHours(hours) {
  if (hours === null || hours === undefined || !isFinite(Number(hours))) return "—"
  var h = Math.max(0, Math.round(Number(hours)))
  if (h < 24) return h + "h"
  var days = Math.floor(h / 24)
  var rem = h % 24
  return days + "d " + rem + "h"
}

function formatTiB(value) {
  if (value === null || value === undefined || !isFinite(Number(value))) return "—"
  var n = Number(value)
  if (n < 0.1) return n.toFixed(2) + " TiB"
  if (n < 10) return n.toFixed(1) + " TiB"
  return Math.round(n) + " TiB"
}

function formatPercent(value) {
  if (value === null || value === undefined || !isFinite(Number(value))) return "—"
  return Math.round(Number(value)) + "%"
}

function barLabel(disk, _needsSetup, unavailable) {
  if (unavailable && !disk) return "?"
  if (!disk) return "—"
  if (disk.warning) return "!"
  if (disk.lifeRemainingPercent === null || disk.lifeRemainingPercent === undefined)
    return "OK"
  return Math.round(Number(disk.lifeRemainingPercent)) + "%"
}

function parseStatus(text) {
  try {
    var data = JSON.parse(clampStatusText(text))
    if (!data || typeof data !== "object" || Array.isArray(data)) return null
    return data
  } catch (e) {
    return null
  }
}

function nextIndex(i, n, delta) {
  if (!n || n < 1) return 0
  i = Math.round(Number(i) || 0)
  delta = Math.round(Number(delta) || 0)
  return ((i + delta) % n + n) % n
}

function indexOfDevice(disks, device) {
  if (!disks || !disks.length) return -1
  var want = String(device || "")
  for (var i = 0; i < disks.length; i++) {
    if (disks[i] && String(disks[i].device || "") === want) return i
  }
  return -1
}

if (typeof module !== "undefined") {
  module.exports = {
    asInt: asInt,
    clampStatusText: clampStatusText,
    formatHours: formatHours,
    formatTiB: formatTiB,
    formatPercent: formatPercent,
    barLabel: barLabel,
    parseStatus: parseStatus,
    nextIndex: nextIndex,
    indexOfDevice: indexOfDevice,
    MAX_STATUS_CHARS: MAX_STATUS_CHARS
  }
}
