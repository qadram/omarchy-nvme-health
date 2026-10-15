# NVMe Health

![NVMe Health panel on Omarchy](preview.png)

SMART disk health for the Omarchy Quattro bar. The panel lists every drive
with its temperature, remaining life, spare and media errors; the bar shows
the one drive that most needs attention.

Reads SMART through **UDisks2** (already on Omarchy). No `smartctl`, no root, no sudoers.

## Install

```sh
omarchy plugin add https://github.com/qadram/omarchy-nvme-health.git --enable
```

Or from a local checkout:

```sh
PLUGIN_ID=io.github.qadram.nvme-health
PLUGIN_DIR="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
mkdir -p "$PLUGIN_DIR"
cp -a manifest.json BarWidget.qml Panel.qml Model.js status.py "$PLUGIN_DIR/"
chmod +x "$PLUGIN_DIR/status.py"
omarchy plugin validate "$PLUGIN_DIR"
omarchy-shell shell rescanPlugins
omarchy plugin enable "$PLUGIN_ID" --section right
```

## Usage

- **Left click:** open the panel listing every drive
- **Middle click** (bar) or **R / Enter** (panel): refresh
- Bar label: the worst drive's remaining life `%`, or `!` when something looks wrong

### Which drive the bar speaks for

With several drives, the bar has to pick one. Ranked worst first:

1. a SMART critical warning
2. any media error / reallocated sector
3. `warning` raised by `status.py` (spare under 10%, or life at/below 10%)
4. available spare below 100%
5. lowest remaining life, ties broken by the hotter drive

### Notifications

When a drive's rank rises, one desktop notification is sent on that poll. It
does not repeat while the state holds. If several drives worsen in the same
poll, the worst one speaks for the batch. The last seen rank per drive is kept
in `${XDG_STATE_HOME:-~/.local/state}/omarchy/nvme-health/severity.json`, so a
drive that is already degraded when the widget first runs is reported once.

Set `notify` to `false` to paint the bar only.

## Configure

```sh
omarchy bar move io.github.qadram.nvme-health --section right
```

Optional settings on the widget entry in `~/.config/omarchy/shell.json`:

- `refreshIntervalSec` — 60–3600 (default `300`)
- `device` — e.g. `/dev/nvme0n1`. Empty (the default) watches every drive.
- `notify` — `true` (default) or `false`

## Multi-monitor and replacement bars

The bar instantiates one widget per screen, so the poll, the persisted state
and the notification live in a service (`kinds: ["service", "bar-widget"]`),
which the shell instantiates once. Without that, a four-monitor machine runs
four `status.py` processes per tick and sends four identical notifications for
one event.

Under a third-party *replacement* bar, `bar.shell.serviceFor()` returns null by
design, so the widget cannot reach its own service — known upstream as
[omarchy#11796](https://github.com/omacom/omarchy/issues/11796) and
[#13289](https://github.com/omacom/omarchy/issues/13289). The bar then shows
`?` and the panel says so, rather than rendering an icon that quietly does
nothing. Under the built-in bar everything works.

## Tests

No dependencies beyond the stdlib and the system Python.

```sh
node --test test/model.test.js                                   # ranking and formatting
/usr/bin/python3 -m unittest discover -s test -p 'test_*.py'     # payload shape, real drives
```

## Remove

```sh
omarchy plugin remove io.github.qadram.nvme-health
```

## License

MIT
