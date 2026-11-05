# Control Centre for Omarchy

A control centre for the [Omarchy](https://omarchy.org) bar: one icon that opens a
panel with Wi-Fi, Bluetooth, sound, microphone, brightness and quick toggles,
so the individual icons don't have to crowd the bar.

It is built from Omarchy's own panel components (`KeyboardPanel`, `PanelSlider`,
`PanelSectionHeader`, …) and theme colours, so it follows whatever theme you use.

## What's in it

- **Wi-Fi and Bluetooth tiles.** The round icon switches the radio on or off; the
  rest of the tile opens the full Omarchy Wi-Fi or Bluetooth panel.
- **Quick toggles.** Night light, Do not disturb and Stay awake.
- **Sound and microphone sliders**, with mute on the icon.
- **Output device picker.** With Pipeworks, choose which device the Main output
  plays through. Handy when you switch between laptop speakers and a headset.
- **Brightness slider**, plus a shortcut to the hyprmoncfg display panel.

### Opening

- **Hover** the icon to open it. It stays open while the pointer is over the
  icon or the panel, and closes shortly after it leaves.
- **Click** the icon to pin it open. Click again, or anywhere else, to close it.
- The panel does not take keyboard focus from the window you are typing in.

## Pipeworks

If the [Pipeworks](https://github.com/XenoUniv3rse/pipeworks-omarchy-plugin) mixer plugin
(`pipeworks.mixer`) is running, the sliders drive its strips instead of
PipeWire's default devices:

- **Sound** is the first output strip (usually *Main*).
- **Microphone** is the first input strip.
- **Mute** uses Pipeworks' own mute.
- **Device picker** moves the output with Pipeworks' `retarget-output`, so
  routing and effects stay intact.

Everything goes over D-Bus, exactly as Pipeworks' own panel does; this plugin
never edits Pipeworks' files.

When Pipeworks' **volume lock** is on, the sliders are dimmed and show a lock.
Click the lock to unlock, which is the same as unlocking in the mixer.

Without Pipeworks, the sliders control the default sink and source with `wpctl`.

## Requirements

- Omarchy 4.5 or newer (uses the shell's plugin system).
- `nmcli`, `bluetoothctl`, `wpctl`, `brightnessctl`. All ship with Omarchy.
- Optional: `pipeworks.mixer` and `crmne.hyprmoncfg` plugins for the mixer and
  display shortcuts.

## Install

```bash
omarchy plugin add https://github.com/XenoUniv3rse/omarchy-control-centre --enable
```

Then move the icon where you want it, for example:

```bash
omarchy bar move ebirkhoff.control --section right
```

## Hiding the icons it replaces

The tiles and shortcuts open the full panels of the Wi-Fi, Bluetooth, Pipeworks
and hyprmoncfg bar widgets, so those widgets need to stay loaded. On a bar that
supports a `"hidden": true` entry option you can keep them loaded but invisible:

```json
{ "id": "ebirkhoff.control" },
{ "id": "omarchy.network", "hidden": true },
{ "id": "omarchy.bluetooth", "hidden": true },
{ "id": "pipeworks.mixer", "hidden": true },
{ "id": "crmne.hyprmoncfg", "hidden": true }
```

Omarchy's stock bar does not have that option yet. Without it, you can remove the
icons from the bar; the switches and sliders keep working, but the "open the full
panel" shortcuts for removed widgets will do nothing.

## License

MIT. See [LICENSE](LICENSE).
