# acer-wmi-battery for Windows 11

Windows port of acer-wmi-battery 0.2.0 (Linux kernel driver by Frederik Harwath).
Controls Acer's firmware battery features: **health mode** (~80 % charge limit),
**calibration mode** and **battery temperature**.

## Interactive menu

Right-click `AcerBattery.ps1` -> **Run with PowerShell**

| Key | Action |
|-----|--------|
| 1 / 2 | Health mode on / off |
| 3 / 4 | Start / stop calibration |
| 5 / 6 | Install / remove boot+resume task (keeps health mode on) |
| 7 | Raw firmware data (debug) |
| 8 | Open log |
| R / Q | Refresh / quit |

Exit codes: 0 ok, 1 firmware/WMI error, 2 interface missing, 3 mode not
supported, 4 bad argument, 5 not elevated.

## License

GPL-2.0-or-later, same as the original driver (see `LICENSE`).
