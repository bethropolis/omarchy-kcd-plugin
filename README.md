# KDE Connect — Night Drive dashboard for Omarchy

An Omarchy Quattro `bar-widget` plugin that surfaces your phone (via
[`kcd`](https://github.com/bethropolis/kcd)) in the bar and in a Night
Drive dashboard panel: device status, battery, now-playing card with
transport controls, and single-press quick actions.

## Requires

* Omarchy Quattro (`omarchy-shell`)
* `kcd` daemon with a paired phone (`systemctl --user start kcd`)

## Install

```sh
omarchy plugin add https://github.com/bethropolis/omarchy-kcd-plugin.git --enable
```

Or by hand:

```sh
cp -r . ~/.config/omarchy/plugins/bet.kcd
omarchy-shell shell rescanPlugins
omarchy plugin enable bet.kcd
```

## Usage

* Bar shows battery level (dimmed when offline). Left-click toggles the
  panel, middle-click refreshes.
* Panel header — phone, WiFi link icon, battery, last-seen.
* Media card — album art, title/artist, prev / play-pause / next, wave
  seeker with smooth playhead.
* Quick actions — **Ping**, **Ring**, **Clipboard** (live).
  Text / Files / Share are dimmed v2 placeholders.
* No paired phone? **Start pairing** runs `kcd pair -y` (auto-accepts the
  first request, then stops). Daemon down? **Start daemon** starts it.
* Footer gear opens `kcd.toml` in Neovim.

## How it works

The panel boots from one `kcd watch --json` snapshot (devices + battery +
media), then stays live on watch events. Position is drift-free math from
the daemon's anchor stamp. Pure parsing lives in `Kcd.js` (Qt-free,
testable under node).

## Files

| File | Purpose |
|---|---|
| `manifest.json` | Plugin contract (`bar-widget` → `BarWidget.qml`) |
| `BarWidget.qml` | Bar button, mirrors panel state |
| `Panel.qml` | Night Drive dashboard, owns all kcd IO |
| `QuickTile.qml` | Quick-action tile component |
| `KcdMissing.qml` / `KcdUnpaired.qml` | Empty-state panels |
| `Kcd.js` | Device/track/event parsing + CLI argv builders |
