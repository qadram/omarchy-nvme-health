// Zero-dependency tests for the pure helpers in Model.js.
// Run with: node --test test/
const test = require("node:test")
const assert = require("node:assert/strict")
const M = require("../Model.js")

// A healthy NVMe baseline; each test overrides only what it exercises.
function disk(over) {
  return Object.assign({
    device: "/dev/nvme0n1",
    model: "GENERIC SSD",
    warning: false,
    criticalWarning: 0,
    mediaErrors: 0,
    availableSparePercent: 100,
    lifeRemainingPercent: 100,
    temperatureC: 40,
  }, over || {})
}

test("worstDisk ranks a critical warning above media errors", () => {
  const critical = disk({ device: "/dev/nvme1n1", criticalWarning: 1 })
  const errors = disk({ device: "/dev/nvme2n1", mediaErrors: 5 })

  assert.equal(M.worstDisk([errors, critical]).device, "/dev/nvme1n1")
})

test("worstDisk ranks reduced spare above a fully healthy disk", () => {
  const healthy = disk({ device: "/dev/nvme1n1" })
  const lowSpare = disk({ device: "/dev/nvme2n1", availableSparePercent: 94 })

  assert.equal(M.worstDisk([healthy, lowSpare]).device, "/dev/nvme2n1")
})

test("worstDisk picks the lowest life remaining among equally healthy disks", () => {
  const fresh = disk({ device: "/dev/nvme1n1", lifeRemainingPercent: 100 })
  const worn = disk({ device: "/dev/nvme2n1", lifeRemainingPercent: 93 })

  assert.equal(M.worstDisk([fresh, worn]).device, "/dev/nvme2n1")
})

test("worstDisk breaks a life tie with the hotter disk", () => {
  const cool = disk({ device: "/dev/nvme1n1", temperatureC: 41 })
  const hot = disk({ device: "/dev/nvme2n1", temperatureC: 68 })

  assert.equal(M.worstDisk([cool, hot]).device, "/dev/nvme2n1")
})

test("worstDisk returns null for an empty list", () => {
  assert.equal(M.worstDisk([]), null)
})

// status.py raises `warning` for a critical bit, any media error, spare under
// 10% or life at/below 10%. A disk flagged that way must outrank a disk that
// merely started consuming spare, otherwise the bar hides the alarm behind a
// healthy-looking percentage.
test("worstDisk prefers a warning disk over one with merely reduced spare", () => {
  const spareDipped = disk({ device: "/dev/nvme1n1", availableSparePercent: 50, warning: false })
  const nearEndOfLife = disk({ device: "/dev/nvme2n1", lifeRemainingPercent: 8, warning: true })

  assert.equal(M.worstDisk([spareDipped, nearEndOfLife]).device, "/dev/nvme2n1")
})

test("worsenedDisk returns the disk whose rank rose since the last poll", () => {
  const previous = { "/dev/nvme1n1": 0, "/dev/nvme2n1": 0 }
  const steady = disk({ device: "/dev/nvme1n1" })
  const degraded = disk({ device: "/dev/nvme2n1", mediaErrors: 1, warning: true })

  assert.equal(M.worsenedDisk(previous, [steady, degraded]).device, "/dev/nvme2n1")
})

test("worsenedDisk ignores a disk that stayed at the same rank", () => {
  const previous = { "/dev/nvme1n1": 4 }
  const stillBad = disk({ device: "/dev/nvme1n1", mediaErrors: 7, warning: true })

  assert.equal(M.worsenedDisk(previous, [stillBad]), null)
})

test("worsenedDisk ignores a disk that improved", () => {
  const previous = { "/dev/nvme1n1": 4 }
  const recovered = disk({ device: "/dev/nvme1n1" })

  assert.equal(M.worsenedDisk(previous, [recovered]), null)
})

test("worsenedDisk reports a disk absent from the previous poll", () => {
  const degraded = disk({ device: "/dev/nvme9n1", criticalWarning: 1 })

  assert.equal(M.worsenedDisk({}, [degraded]).device, "/dev/nvme9n1")
})

test("worsenedDisk picks the worst when several disks rose at once", () => {
  const previous = { "/dev/nvme1n1": 0, "/dev/nvme2n1": 0 }
  const spareDipped = disk({ device: "/dev/nvme1n1", availableSparePercent: 80 })
  const critical = disk({ device: "/dev/nvme2n1", criticalWarning: 1 })

  assert.equal(M.worsenedDisk(previous, [spareDipped, critical]).device, "/dev/nvme2n1")
})

test("severityMap keys every device by its rank", () => {
  const healthy = disk({ device: "/dev/nvme1n1" })
  const bad = disk({ device: "/dev/nvme2n1", mediaErrors: 2, warning: true })

  assert.deepEqual(M.severityMap([healthy, bad]), {
    "/dev/nvme1n1": 0,
    "/dev/nvme2n1": 4,
  })
})
