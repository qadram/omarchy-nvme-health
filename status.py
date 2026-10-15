#!/usr/bin/env python3
"""Emit disk SMART health JSON for the Omarchy NVMe Health bar widget.

Reads NVMe/ATA SMART through UDisks2 over the system bus — no root, no
smartctl, no sudoers. Requires udisks2 (ships with Omarchy).
"""

from __future__ import annotations

import json
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from concurrent.futures import TimeoutError as FuturesTimeout
from typing import Any, Callable, TypeVar

import gi

gi.require_version("Gio", "2.0")
gi.require_version("GLib", "2.0")
from gi.repository import Gio, GLib  # noqa: E402


UDISKS = "org.freedesktop.UDisks2"
IFACE_DRIVE = "org.freedesktop.UDisks2.Drive"
IFACE_NVME = "org.freedesktop.UDisks2.NVMe.Controller"
IFACE_ATA = "org.freedesktop.UDisks2.Drive.Ata"
IFACE_BLOCK = "org.freedesktop.UDisks2.Block"
IFACE_PARTITION = "org.freedesktop.UDisks2.Partition"

# Hard ceilings: UDisks GetManagedObjects can be large; keep parsing and
# the document we emit bounded so the shell/QML cannot be flooded.
MAX_MANAGED_OBJECTS = 512
MAX_DISKS = 32
MAX_BLOCK_CANDIDATES = 8
MAX_ATTR_ROWS = 256
MAX_FIELD_LEN = 128
MAX_PATH_LEN = 256
MAX_DEVICE_ARG_LEN = 64
MAX_MESSAGE_LEN = 256
MAX_JSON_BYTES = 32 * 1024
# Upper bound on per-disk summaries in one payload. Five drives cost ~2.5 KiB,
# so this leaves ample headroom under MAX_JSON_BYTES on a crowded machine.
MAX_DISKS = 12
DBUS_TIMEOUT_MS = 10_000
SETUP_TIMEOUT_SEC = 10
# Wall clock for the whole status.py run (QML watchdog should match).
PROCESS_DEADLINE_SEC = 45

NVME_ATTR_KEYS = ("percent_used", "avail_spare", "media_errors", "total_data_written")

T = TypeVar("T")

_bus: Gio.DBusConnection | None = None
_executor = ThreadPoolExecutor(max_workers=1)


def clamp_str(value: Any, max_len: int = MAX_FIELD_LEN) -> str:
  if value is None:
    return ""
  text = str(value).replace("\x00", "")
  # Drop other C0 controls except tab/newline so UI text stays printable.
  text = "".join(ch for ch in text if ch >= " " or ch in "\t\n")
  text = text.strip()
  if len(text) > max_len:
    return text[:max_len]
  return text


def safe_dbus_path(value: Any) -> str | None:
  """Sanitize an object path; reject if missing or over MAX_PATH_LEN."""
  text = clamp_str(value, MAX_PATH_LEN + 1)
  if not text or len(text) > MAX_PATH_LEN:
    return None
  if not text.startswith("/"):
    return None
  return text


def bytes_to_path(value: Any) -> str:
  raw = ""
  if isinstance(value, (bytes, bytearray)):
    raw = bytes(value).split(b"\x00", 1)[0].decode("utf-8", "replace")
  elif isinstance(value, str):
    raw = value.split("\x00", 1)[0]
  elif isinstance(value, (list, tuple)):
    try:
      raw = bytes(int(x) & 0xFF for x in value).split(b"\x00", 1)[0].decode("utf-8", "replace")
    except (TypeError, ValueError):
      return ""
  else:
    return ""
  return clamp_str(raw, MAX_FIELD_LEN)


def as_int(value: Any) -> int | None:
  try:
    if value is None:
      return None
    return int(value)
  except (TypeError, ValueError):
    return None


def bytes_to_tib(num_bytes: int | None) -> float | None:
  if num_bytes is None or num_bytes < 0:
    return None
  return round(num_bytes / (1024**4), 2)


def run_timed(timeout_sec: float, fn: Callable[..., T], *args: Any, **kwargs: Any) -> T:
  """Run a blocking Gio setup call with a wall-clock timeout."""
  fut = _executor.submit(fn, *args, **kwargs)
  try:
    return fut.result(timeout=timeout_sec)
  except FuturesTimeout as exc:
    raise TimeoutError(f"timed out after {timeout_sec:.0f}s") from exc


def emit(payload: dict[str, Any]) -> None:
  """Print one JSON line, refusing to exceed MAX_JSON_BYTES (incl. newline)."""
  encoded = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
  if len(encoded) + 1 <= MAX_JSON_BYTES:
    sys.stdout.buffer.write(encoded + b"\n")
    return
  fallback = {
    "ok": False,
    "error": "output_too_large",
    "message": "SMART status payload exceeded size limit.",
    "needsSetup": False,
    "devices": [],
    "disk": None,
  }
  sys.stdout.buffer.write(
    json.dumps(fallback, ensure_ascii=False, separators=(",", ":")).encode("utf-8") + b"\n"
  )


def get_bus() -> Gio.DBusConnection:
  global _bus
  if _bus is None:
    _bus = run_timed(SETUP_TIMEOUT_SEC, Gio.bus_get_sync, Gio.BusType.SYSTEM, None)
  return _bus


def slim_managed_objects(objs: dict[str, Any]) -> dict[str, dict[str, Any]]:
  """Keep only drive/block interfaces and the few properties we read."""
  if len(objs) > MAX_MANAGED_OBJECTS:
    raise RuntimeError(f"UDisks object count {len(objs)} exceeds limit {MAX_MANAGED_OBJECTS}")

  slim: dict[str, dict[str, Any]] = {}
  for path, ifaces in objs.items():
    if len(slim) >= MAX_MANAGED_OBJECTS:
      break
    safe_path = safe_dbus_path(path)
    if not safe_path:
      continue
    if not isinstance(ifaces, dict):
      continue
    has_drive = IFACE_DRIVE in ifaces
    has_block = IFACE_BLOCK in ifaces
    if not has_drive and not has_block:
      continue

    entry: dict[str, Any] = {}
    if has_drive:
      drive = ifaces.get(IFACE_DRIVE) or {}
      entry[IFACE_DRIVE] = {
        "Model": drive.get("Model"),
        "Optical": drive.get("Optical"),
        "MediaRemovable": drive.get("MediaRemovable"),
        "MediaAvailable": drive.get("MediaAvailable"),
      }
      if IFACE_NVME in ifaces:
        nvme = ifaces.get(IFACE_NVME) or {}
        crit = nvme.get("SmartCriticalWarning") or []
        if isinstance(crit, (list, tuple)):
          crit = list(crit)[:32]
        else:
          crit = []
        entry[IFACE_NVME] = {
          "SmartPowerOnHours": nvme.get("SmartPowerOnHours"),
          "SmartCriticalWarning": crit,
          "SmartTemperature": nvme.get("SmartTemperature"),
        }
      if IFACE_ATA in ifaces:
        ata = ifaces.get(IFACE_ATA) or {}
        entry[IFACE_ATA] = {
          "SmartFailing": ata.get("SmartFailing"),
          "SmartPowerOnSeconds": ata.get("SmartPowerOnSeconds"),
          "SmartTemperature": ata.get("SmartTemperature"),
        }
    if has_block:
      block = ifaces.get(IFACE_BLOCK) or {}
      drive_ref = safe_dbus_path(block.get("Drive")) or ""
      entry[IFACE_BLOCK] = {
        "Drive": drive_ref,
        "Device": block.get("Device"),
        "PreferredDevice": block.get("PreferredDevice"),
      }
      if IFACE_PARTITION in ifaces:
        entry[IFACE_PARTITION] = True

    if entry:
      slim[safe_path] = entry
  return slim


def get_managed_objects() -> dict[str, dict[str, Any]]:
  bus = get_bus()
  om = run_timed(
    SETUP_TIMEOUT_SEC,
    Gio.DBusProxy.new_sync,
    bus,
    Gio.DBusProxyFlags.NONE,
    None,
    UDISKS,
    "/org/freedesktop/UDisks2",
    "org.freedesktop.DBus.ObjectManager",
    None,
  )
  result = om.call_sync("GetManagedObjects", None, Gio.DBusCallFlags.NONE, DBUS_TIMEOUT_MS, None)
  objs = result.unpack()
  if isinstance(objs, tuple):
    objs = objs[0]
  if not isinstance(objs, dict):
    return {}
  slim = slim_managed_objects(objs)
  objs.clear()
  return slim


def call_method(path: str, iface: str, method: str) -> Any:
  bus = get_bus()
  proxy = run_timed(
    SETUP_TIMEOUT_SEC,
    Gio.DBusProxy.new_sync,
    bus,
    Gio.DBusProxyFlags.NONE,
    None,
    UDISKS,
    path,
    iface,
    None,
  )
  result = proxy.call_sync(
    method,
    GLib.Variant("(a{sv})", ([],)),
    Gio.DBusCallFlags.NONE,
    DBUS_TIMEOUT_MS,
    None,
  )
  return result.unpack()


def block_paths_for_drive(objects: dict[str, Any], drive_path: str) -> list[str]:
  names: list[str] = []
  for _path, ifaces in objects.items():
    if len(names) >= MAX_BLOCK_CANDIDATES:
      break
    block = ifaces.get(IFACE_BLOCK)
    if not block:
      continue
    if str(block.get("Drive") or "") != drive_path:
      continue
    # Skip partitions: they also point at the same Drive in some setups via
    # the parent disk; prefer whole-disk nodes (no Partition iface).
    if IFACE_PARTITION in ifaces:
      continue
    device = bytes_to_path(block.get("Device") or block.get("PreferredDevice"))
    if device:
      names.append(device)
  return names


def device_matches(requested: str, candidates: list[str], drive_id: str) -> str | None:
  """Return 'exact', 'prefix', or None."""
  if not requested:
    return None
  req = clamp_str(requested, MAX_DEVICE_ARG_LEN)
  if len(req) < 5 or req in ("/dev", "/dev/"):
    return None
  if not (req.startswith("/dev/") or req.startswith("/org/freedesktop/UDisks2/")):
    return None
  if req == drive_id or req in candidates:
    return "exact"
  for name in candidates:
    if name == req:
      return "exact"
    # /dev/nvme0 matches /dev/nvme0n1; /dev/sda matches /dev/sda
    if name.startswith(req) or req.startswith(name):
      return "prefix"
  return None


def slim_nvme_attrs(attrs: Any) -> dict[str, Any]:
  if isinstance(attrs, tuple) and len(attrs) == 1:
    attrs = attrs[0]
  if not isinstance(attrs, dict):
    return {}
  out: dict[str, Any] = {}
  for key in NVME_ATTR_KEYS:
    if key in attrs:
      out[key] = attrs.get(key)
  return out


def ata_attr_raw(attrs: Any, *names: str) -> int | None:
  # ATA SmartGetAttributes returns (a{sv} or aa{sv} depending on version).
  wanted = {n.lower() for n in names}
  rows: list[Any]
  if isinstance(attrs, tuple) and len(attrs) == 1:
    attrs = attrs[0]
  if isinstance(attrs, dict):
    rows = list(attrs.values())[:MAX_ATTR_ROWS]
  elif isinstance(attrs, list):
    rows = attrs[:MAX_ATTR_ROWS]
  else:
    return None
  for row in rows:
    if not isinstance(row, dict):
      continue
    name = str(row.get("name") or row.get("Name") or "").lower()
    if name not in wanted:
      continue
    for key in ("raw", "value", "Raw", "Value"):
      if key in row:
        return as_int(row.get(key))
  return None


def kelvin_to_c(value: Any) -> int | None:
  """UDisks2 reports SmartTemperature in Kelvin; the UI wants Celsius."""
  # NVMe reports a uint16, ATA a double; both in Kelvin.
  try:
    kelvin = float(value)
  except (TypeError, ValueError):
    return None
  if kelvin <= 0:
    return None
  return int(round(kelvin - 273.15))


def summarize_nvme(drive: dict[str, Any], nvme_props: dict[str, Any], attrs: dict[str, Any], device: str) -> dict[str, Any]:
  percent_used = as_int(attrs.get("percent_used"))
  life_remaining = None if percent_used is None else max(0, 100 - percent_used)
  spare = as_int(attrs.get("avail_spare"))
  media_errors = as_int(attrs.get("media_errors"))
  written = as_int(attrs.get("total_data_written"))
  hours = as_int(nvme_props.get("SmartPowerOnHours"))
  critical = nvme_props.get("SmartCriticalWarning") or []
  warning = False
  if isinstance(critical, (list, tuple)) and len(critical) > 0:
    warning = True
  if media_errors is not None and media_errors > 0:
    warning = True
  if spare is not None and spare < 10:
    warning = True
  if life_remaining is not None and life_remaining <= 10:
    warning = True

  return {
    "device": clamp_str(device),
    "type": "nvme",
    "model": clamp_str(drive.get("Model")),
    "protocol": "nvme",
    "passed": None if warning else True,
    "warning": warning,
    "powerOnHours": hours,
    "reallocatedSectors": None,
    "mediaErrors": media_errors,
    "availableSparePercent": spare,
    "percentageUsed": percent_used,
    "lifeRemainingPercent": life_remaining,
    "temperatureC": kelvin_to_c(nvme_props.get("SmartTemperature")),
    "tbwTiB": bytes_to_tib(written),
    "criticalWarning": len(critical) if isinstance(critical, (list, tuple)) else 0,
  }


def summarize_ata(drive: dict[str, Any], ata_props: dict[str, Any], attrs: Any, device: str) -> dict[str, Any]:
  hours = ata_attr_raw(attrs, "power_on_hours", "Power_On_Hours")
  if hours is None:
    seconds = as_int(ata_props.get("SmartPowerOnSeconds"))
    if seconds is not None:
      hours = seconds // 3600
  reallocated = ata_attr_raw(attrs, "reallocated_sector_ct", "Reallocated_Sector_Ct")
  life = ata_attr_raw(attrs, "percent_lifetime_remain", "Percent_Lifetime_Remain", "Percent_Lifetime_Remaining")
  failing = bool(ata_props.get("SmartFailing"))
  warning = failing or (reallocated is not None and reallocated > 0) or (life is not None and life <= 10)
  return {
    "device": clamp_str(device),
    "type": "ata",
    "model": clamp_str(drive.get("Model")),
    "protocol": "ata",
    "passed": (not failing) if ata_props.get("SmartFailing") is not None else None,
    "warning": warning,
    "powerOnHours": hours,
    "reallocatedSectors": reallocated,
    "mediaErrors": None,
    "availableSparePercent": None,
    "percentageUsed": None if life is None else max(0, 100 - life),
    "lifeRemainingPercent": life,
    "temperatureC": kelvin_to_c(ata_props.get("SmartTemperature")),
    "tbwTiB": None,
    "criticalWarning": 0,
  }


def enumerate_drives(objects: dict[str, Any], deadline: float) -> list[dict[str, Any]]:
  """List NVMe/ATA drives without issuing SMART method calls."""
  disks: list[dict[str, Any]] = []
  for path, ifaces in objects.items():
    if time.monotonic() > deadline:
      break
    if len(disks) >= MAX_DISKS:
      break
    drive = ifaces.get(IFACE_DRIVE)
    if not drive:
      continue
    if drive.get("Optical") or drive.get("MediaRemovable"):
      continue
    if drive.get("MediaAvailable") is False:
      continue

    is_nvme = IFACE_NVME in ifaces
    is_ata = IFACE_ATA in ifaces
    if not is_nvme and not is_ata:
      continue

    blocks = block_paths_for_drive(objects, path)
    device = blocks[0] if blocks else path
    disks.append(
      {
        "path": path,
        "device": clamp_str(device),
        "candidates": blocks,
        "protocol": "nvme" if is_nvme else "ata",
        "model": clamp_str(drive.get("Model")),
        "drive": drive,
        "ctrl_props": ifaces.get(IFACE_NVME if is_nvme else IFACE_ATA) or {},
      }
    )
  return disks


def pick_disk(disks: list[dict[str, Any]], requested: str) -> dict[str, Any] | None:
  if not disks:
    return None
  if requested:
    exact: list[dict[str, Any]] = []
    prefix: list[dict[str, Any]] = []
    for d in disks:
      kind = device_matches(requested, d.get("candidates") or [d.get("device") or ""], d.get("path") or "")
      if kind == "exact":
        exact.append(d)
      elif kind == "prefix":
        prefix.append(d)
    if exact:
      return exact[0]
    # Prefix only when unambiguous (avoids /dev/nvme0 matching several namespaces).
    if len(prefix) == 1:
      return prefix[0]
    return None
  for d in disks:
    if d.get("protocol") == "nvme":
      return d
  return disks[0]


def fetch_smart(disk: dict[str, Any]) -> dict[str, Any]:
  path = disk["path"]
  is_nvme = disk.get("protocol") == "nvme"
  iface = IFACE_NVME if is_nvme else IFACE_ATA
  device = disk.get("device") or path
  try:
    call_method(path, iface, "SmartUpdate")
  except Exception:
    pass
  try:
    attrs_pack = call_method(path, iface, "SmartGetAttributes")
  except Exception as exc:
    return {
      "ok": False,
      "device": clamp_str(device),
      "error": clamp_str(exc, MAX_MESSAGE_LEN),
      "protocol": disk.get("protocol"),
      "model": disk.get("model") or "",
    }

  attrs = attrs_pack[0] if isinstance(attrs_pack, tuple) else attrs_pack
  drive = disk.get("drive") or {}
  ctrl = disk.get("ctrl_props") or {}
  if is_nvme:
    return summarize_nvme(drive, ctrl, slim_nvme_attrs(attrs), device)
  return summarize_ata(drive, ctrl, attrs, device)


def unavailable_summary(disk: dict[str, Any], error: Any) -> dict[str, Any]:
  """A disk we listed but could not read, shaped like a real summary.

  Keeping the ranking keys present (as None) lets the panel render one row per
  device without the UI having to special-case a different object shape.
  """
  return {
    "device": clamp_str(disk.get("device") or disk.get("path")),
    "type": clamp_str(disk.get("protocol") or "", 16),
    "model": clamp_str(disk.get("model") or ""),
    "protocol": disk.get("protocol"),
    "available": False,
    "error": clamp_str(error, MAX_MESSAGE_LEN),
    "passed": None,
    "warning": False,
    "powerOnHours": None,
    "reallocatedSectors": None,
    "mediaErrors": None,
    "availableSparePercent": None,
    "percentageUsed": None,
    "lifeRemainingPercent": None,
    "temperatureC": None,
    "tbwTiB": None,
    "criticalWarning": 0,
  }


def main() -> int:
  raw_arg = sys.argv[1] if len(sys.argv) > 1 else ""
  requested = clamp_str(raw_arg, MAX_DEVICE_ARG_LEN)
  deadline = time.monotonic() + PROCESS_DEADLINE_SEC

  try:
    objects = get_managed_objects()
  except Exception as exc:
    emit(
      {
        "ok": False,
        "error": "udisks_unavailable",
        "message": clamp_str(f"Could not talk to UDisks2: {exc}", MAX_MESSAGE_LEN),
        "needsSetup": False,
        "devices": [],
        "disk": None,
      }
    )
    return 0

  disks = enumerate_drives(objects, deadline)
  # Drop the managed-object tree as soon as the light inventory exists.
  del objects

  devices = [
    {
      "name": clamp_str(d.get("device") or d.get("path")),
      "type": clamp_str(d.get("protocol") or "", 16),
      "info": clamp_str(d.get("model") or d.get("device") or ""),
    }
    for d in disks
  ]

  chosen = pick_disk(disks, requested)
  if not chosen:
    emit(
      {
        "ok": False,
        "error": "no_devices",
        "message": (
          "No matching NVMe/ATA drive was found."
          if requested
          else "No NVMe/ATA drives with SMART data were found."
        ),
        "needsSetup": False,
        "devices": devices,
        "disk": None,
      }
    )
    return 0

  if time.monotonic() > deadline:
    emit(
      {
        "ok": False,
        "error": "timeout",
        "message": "SMART status collection timed out.",
        "needsSetup": False,
        "devices": devices,
        "disk": None,
      }
    )
    return 0

  # One summary per listed device. Serial on purpose: the D-Bus connection is
  # shared and _executor is a single-worker timeout harness, not a pool.
  all_summaries = []
  chosen_summary = None
  for d in disks[:MAX_DISKS]:
    if time.monotonic() > deadline:
      break
    one = fetch_smart(d)
    if one.get("ok") is False or "lifeRemainingPercent" not in one:
      one = unavailable_summary(d, one.get("error"))
    else:
      one["available"] = True
    all_summaries.append(one)
    if d is chosen:
      chosen_summary = one

  summary = chosen_summary if chosen_summary is not None else fetch_smart(chosen)
  if summary.get("ok") is False or "lifeRemainingPercent" not in summary:
    emit(
      {
        "ok": False,
        "error": "smart_unavailable",
        "message": clamp_str(summary.get("error") or "Could not read SMART attributes.", MAX_MESSAGE_LEN),
        "needsSetup": False,
        "devices": devices,
        "disk": None,
      }
    )
    return 0

  emit(
    {
      "ok": True,
      "error": "",
      "message": "",
      "needsSetup": False,
      "devices": devices,
      "disks": all_summaries,
      "disk": summary,
    }
  )
  return 0


if __name__ == "__main__":
  try:
    raise SystemExit(main())
  except SystemExit:
    raise
  except Exception as exc:
    # Never dump tracebacks to stderr (QML no longer collects it).
    emit(
      {
        "ok": False,
        "error": "internal_error",
        "message": clamp_str(exc, MAX_MESSAGE_LEN),
        "needsSetup": False,
        "devices": [],
        "disk": None,
      }
    )
    raise SystemExit(0)
