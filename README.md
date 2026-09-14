# kcd Phone

An Omarchy Quattro `bar-widget` plugin for
[`kcd`](https://github.com/bethropolis/kcd), a KDE Connect protocol
daemon written in Go. Surfaces your phone in the bar and in a Night
Drive dashboard panel: device status, battery, now-playing card with
transport controls, and single-press quick actions.

## Requires

* Omarchy Quattro (`omarchy-shell`)
* `kcd` daemon with a paired phone (`systemctl --user start kcd`)

## Install

```sh
omarchy plugin add https://github.com/bethropolis/omarchy-kcd-plugin.git --enable
```

Or by hand (explicit file list, so no `.git` ships with the plugin):

```sh
PLUGIN=~/.config/omarchy/plugins/io.github.bethropolis.kcd
mkdir -p "$PLUGIN"
cp manifest.json BarWidget.qml Panel.qml KcdIo.qml Kcd.js KcdMissing.qml \
  KcdUnpaired.qml MediaCard.qml PanelHeader.qml QuickActionsRow.qml \
  QuickTile.qml README.md LICENSE kcd-share.sh kcd-screenshot-share.sh \
  preview.png "$PLUGIN/"
chmod +x "$PLUGIN"/*.sh
omarchy-shell shell rescanPlugins
omarchy plugin enable io.github.bethropolis.kcd
```

## Usage

* Bar shows battery level (dimmed when offline). Left-click toggles the
  panel, middle-click refreshes.
* Panel header — phone, link icon (tooltip shows the phone's reported
  network type when available), battery, last-seen.
* Media card — album art, title/artist, prev / play-pause / next, wave
  seeker with smooth playhead.
* Quick actions — **Ping**, **Ring**, **Clipboard**, **Share**,
  **Screenshot** (live). Text / Files are dimmed v2 placeholders. Share
  picks one file with the native chooser (`omarchy-file-select`) and sends
  it via `kcd share`, reporting back as a desktop notification.
  Screenshot captures the focused monitor with `grim` (after the panel
  hides itself) and sends the PNG the same way. Captures stage as
  temporary `/tmp` files — never the cache dir — because `kcd share`
  returns on invitation while the daemon opens the file seconds later;
  the staged file is deleted on `share.complete` (stale ones pruned
  after an hour, the rest vanish on reboot), and the notification only
  claims success then.
* No paired phone? **Start pairing** runs `kcd pair -y` (auto-accepts the
  first request, then stops). Daemon down? **Start daemon** starts it.
* Footer gear opens `kcd.toml` in Neovim. Footer right shows the live
  `kcd <version>` — click it to open `bethropolis/kcd` on GitHub.

## How it works

The panel boots from one `kcd watch --json` snapshot (devices + battery +
media), then stays live on watch events. Position is drift-free math from
the daemon's anchor stamp. Pure parsing lives in `Kcd.js` (Qt-free,
testable under bun):

```sh
bun test tests/
```

## Files

| File | Purpose |
|---|---|
| `manifest.json` | Plugin contract (`bar-widget` → `BarWidget.qml`) |
| `BarWidget.qml` | Bar button, mirrors panel state |
| `Panel.qml` | Night Drive dashboard, owns all kcd IO |
| `QuickTile.qml` | Quick-action tile component (+ `accent` primary style) |
| `KcdMissing.qml` / `KcdUnpaired.qml` | Empty-state panels |
| `Kcd.js` | Device/track/event parsing + CLI argv builders |
| `kcd-share.sh` | Share flow: native pick → `kcd share` → notification |
| `kcd-screenshot-share.sh` | Screenshot flow: `grim` → `/tmp` stage → `kcd share` → delete on `share.complete` |
| `tests/kcd.test.js` | Bun suite for the `Kcd.js` helpers (`bun test tests/`) |

## Previews

| Catppuccin | Flexoki | Vantablack |
|---|---|---|
| ![Catppuccin](docs/previews/catppuccin.png) | ![Flexoki](docs/previews/flexoki.png) | ![Vantablack](docs/previews/vantablack.png) |
