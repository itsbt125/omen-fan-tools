# omen-fan-tools

Fan control for HP Omen 16-xf0xxx (Board 8BCA) on Linux.

First time using Claude Code, really impressed.

## The Problem

The HP Omen 16-xf0xxx uses the Victus-S WMI fan protocol (queries `0x2D`/`0x2E`), but the mainline `hp_wmi` kernel driver doesn't include board `8BCA` in its `victus_s_thermal_profile_boards` list. This means:

- Fan speed readings return bogus zeros (using the wrong WMI query)
- Manual fan speed control is completely unavailable
- Only auto/max toggle works (and even that uses a failing query path)

## What This Provides

1. **`hp_wmi_fan_ctrl.ko`** — Standalone kernel module that exposes WMI fan control via sysfs
2. **`omen-fand.py`** — Temperature-based fan curve daemon with hold/resume support
3. **`omen-fan`** — CLI helper for quick manual control
4. **`hp_wmi_fan_test.ko`** — Diagnostic module for probing WMI query support
5. **`ec_probe.py`** — EC register dumper for hardware analysis

## Quick Start

### Build & Install

```bash
# Install prerequisites
sudo dnf install kernel-devel dkms   # Fedora
sudo apt install linux-headers-$(uname -r) dkms  # Debian/Ubuntu
sudo pacman -S linux-headers dkms    # Arch

# Clone and install
git clone https://github.com/itsbt125/omen-fan-tools.git
cd omen-fan-tools
sudo ./install.sh
```

The install script:
- Builds the kernel module (uses DKMS if available for auto-rebuild on kernel updates)
- Installs the daemon and CLI helper to `/usr/local/bin/`
- Enables the `omen-fand` systemd service

### CLI Helper

```bash
sudo omen-fan status        # show current fan state
sudo omen-fan max           # max fans, pause daemon
sudo omen-fan set 50 50     # set both fans to ~5000 RPM, pause daemon
sudo omen-fan auto          # return to auto, resume daemon
sudo omen-fan hold          # pause daemon (keep current speed)
sudo omen-fan resume        # resume daemon curve control
```

### Direct sysfs Control

```bash
# Read current state
cat /sys/module/hp_wmi_fan_ctrl/fans

# Set fan speeds (value * 100 = approximate RPM)
echo "30 30" | sudo tee /sys/module/hp_wmi_fan_ctrl/fans   # ~3000 RPM
echo "55 55" | sudo tee /sys/module/hp_wmi_fan_ctrl/fans   # ~5500 RPM
echo "max"   | sudo tee /sys/module/hp_wmi_fan_ctrl/fans   # full blast
echo "auto"  | sudo tee /sys/module/hp_wmi_fan_ctrl/fans   # firmware control
```

## Fan Curve

The default curve is aggressive:

| Temp (C) | Fan Speed | ~RPM |
|----------|-----------|------|
| 35       | 20        | 2000 |
| 45       | 30        | 3000 |
| 55       | 40        | 4000 |
| 65       | 50        | 5000 |
| 70       | 60        | 6000 |
| 75       | 70        | 7000 |
| 80       | 80        | 8000 |
| 85+      | 255       | MAX  |

Custom curves via JSON config:

```bash
python3 omen-fand.py --write-config fan.json  # generate default
sudo omen-fand -c fan.json -v                 # use custom config
```

## Hold Mode

When you manually set fans (via `omen-fan max`, `omen-fan set`, or direct sysfs writes), the daemon's curve would normally override your setting. Hold mode pauses the curve:

```bash
sudo omen-fan max       # sets max AND pauses daemon automatically
sudo omen-fan resume    # releases hold, daemon resumes curve
```

You can also signal the daemon directly:
```bash
kill -USR1 $(pidof omen-fand)  # hold
kill -USR2 $(pidof omen-fand)  # resume
```

## How We Found This

The `hp_wmi_fan_test.ko` module probes all fan-related WMI queries. Results for board 8BCA:

| Query | ID   | Result |
|-------|------|--------|
| FAN_COUNT_GET | 0x10 | 2 fans |
| FAN_SPEED_GET (old Omen) | 0x11 | Returns zeros (wrong protocol) |
| VICTUS_S_FAN_GET | 0x2D | Real RPM values |
| FAN_SPEED_MAX_GET (old) | 0x26 | FAILED (not supported) |
| SYSTEM_DESIGN_DATA (old) | 0x28 | FAILED (not supported) |
| FAN_SPEED_SET | 0x2E | SUCCESS |

This confirmed the board uses the Victus-S fan protocol despite being branded as an Omen.

## Compatibility

- **Tested on:** HP Omen 16-xf0xxx, Board ID 8BCA, Fedora 43, kernel 6.19.10
- **Should work on:** Any Linux kernel 6.x with headers available
- **Other boards:** HP Omen/Victus boards missing from the upstream driver may benefit — use `hp_wmi_fan_test.ko` to check

## Kernel Updates

With DKMS installed, the module auto-rebuilds on kernel updates. Without DKMS, run:

```bash
cd omen-fan-tools
sudo ./install.sh
```

## The Proper Fix

The upstream kernel fix is a one-line patch adding `"8BCA"` to the `victus_s_thermal_profile_boards` array in `drivers/platform/x86/hp/hp-wmi.c`. See `patches/` for details.

## License

GPL-2.0 (matching the Linux kernel)
