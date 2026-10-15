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

// Severity ranking: which disk most deserves the user's attention.
// Higher rank wins. Kept pure so it can be tested without Qt or hardware.
function severityRank(disk) {
  if (asInt(disk.criticalWarning, 0) !== 0) return 5
  if (asInt(disk.mediaErrors, 0) > 0) return 4
  // status.py already raises `warning` for spare under 10% or life at/below
  // 10%; trust it rather than duplicating its thresholds here.
  if (disk.warning === true) return 3
  // Spare below 100% is not yet a warning, but it outranks an untouched disk.
  if (asInt(disk.availableSparePercent, 100) < 100) return 2
  return 0
}

// True when a is the one to surface instead of b.
function isWorse(a, b) {
  var rankA = severityRank(a)
  var rankB = severityRank(b)
  if (rankA !== rankB) return rankA > rankB

  var lifeA = asInt(a.lifeRemainingPercent, 100)
  var lifeB = asInt(b.lifeRemainingPercent, 100)
  if (lifeA !== lifeB) return lifeA < lifeB

  // Equally worn: surface the hotter one.
  return asInt(a.temperatureC, 0) > asInt(b.temperatureC, 0)
}

function worstDisk(disks) {
  if (!Array.isArray(disks) || disks.length === 0) return null
  var best = disks[0]
  for (var i = 1; i < disks.length; i++) {
    if (isWorse(disks[i], best)) best = disks[i]
  }
  return best
}

// Severity per device, for persisting between polls.
function severityMap(disks) {
  var map = {}
  if (!Array.isArray(disks)) return map
  for (var i = 0; i < disks.length; i++) {
    var d = disks[i]
    if (d && d.device) map[String(d.device)] = severityRank(d)
  }
  return map
}

// The disk to announce: the worst one whose rank rose since `previous`.
// A device missing from `previous` is treated as having been healthy, so a
// drive that is already degraded on first run is reported once.
function worsenedDisk(previous, disks) {
  if (!Array.isArray(disks)) return null
  var before = previous && typeof previous === "object" ? previous : {}
  var found = null
  for (var i = 0; i < disks.length; i++) {
    var d = disks[i]
    if (!d || !d.device) continue
    var key = String(d.device)
    var was = asInt(before[key], 0)
    var now = severityRank(d)
    if (now > was && (found === null || now > severityRank(found))) found = d
  }
  return found
}

// "/dev/nvme2n1" -> "nvme2n1"; the /dev/ prefix is noise in a narrow column.
function shortDevice(disk) {
  if (!disk || !disk.device) return "\u2014"
  var s = String(disk.device)
  return s.indexOf("/dev/") === 0 ? s.substring(5) : s
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
    severityRank: severityRank,
    worstDisk: worstDisk,
    severityMap: severityMap,
    worsenedDisk: worsenedDisk,
    shortDevice: shortDevice,
    MAX_STATUS_CHARS: MAX_STATUS_CHARS
  }
}
