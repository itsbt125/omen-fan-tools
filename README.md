# omen-fan-tools

Fan control for HP Omen 16-xf0xxx (Board 8BCA) on Linux.

## The Problem

The HP Omen 16-xf0xxx uses the Victus-S WMI fan protocol (queries `0x2D`/`0x2E`), but the mainline `hp_wmi` kernel driver doesn't include board `8BCA` in its `victus_s_thermal_profile_boards` list. This means:

- Fan speed readings return bogus zeros (using the wrong WMI query)
- Manual fan speed control is completely unavailable
- Only auto/max toggle works (and even that uses a failing query path)

This is compounded by a [known hardware defect](https://chimicles.com/hp-victus-16-and-omen-16-gaming-laptop-hall-sensor-defect-investigation/) where the hall effect lid sensor (Toshiba TCS40DLR) is placed adjacent to the CPU/GPU heatpipe. Without proper fan control, thermal buildup causes false lid-close events that shut down the machine.

## What This Provides

1. **`hp_wmi_fan_ctrl.ko`** — Standalone kernel module that exposes WMI fan control via sysfs
2. **`omen-fand.py`** — Temperature-based fan curve daemon
3. **`hp_wmi_fan_test.ko`** — Diagnostic module for probing WMI query support
4. **`ec_probe.py`** — EC register dumper for hardware analysis

## Quick Start

### Build

```bash
# Requires kernel headers
sudo dnf install kernel-devel  # Fedora
sudo apt install linux-headers-$(uname -r)  # Debian/Ubuntu

make
```

### Install

```bash
# Install module to system path (avoids SELinux denials)
sudo mkdir -p /lib/modules/$(uname -r)/extra
sudo cp hp_wmi_fan_ctrl.ko /lib/modules/$(uname -r)/extra/
sudo depmod -a

# Load
sudo modprobe hp_wmi_fan_ctrl

# Verify
cat /sys/module/hp_wmi_fan_ctrl/fans
```

### Manual Control

```bash
# Read current state
cat /sys/module/hp_wmi_fan_ctrl/fans

# Set fan speeds (value * 100 = approximate RPM)
echo "30 30" | sudo tee /sys/module/hp_wmi_fan_ctrl/fans   # ~3000 RPM
echo "55 55" | sudo tee /sys/module/hp_wmi_fan_ctrl/fans   # ~5500 RPM
echo "max"   | sudo tee /sys/module/hp_wmi_fan_ctrl/fans   # full blast
echo "auto"  | sudo tee /sys/module/hp_wmi_fan_ctrl/fans   # return to firmware control
```

### Fan Curve Daemon

```bash
# Dry run (see what it would do)
sudo python3 omen-fand.py --dry-run --once -v

# Run live
sudo python3 omen-fand.py -v
```

### Systemd Service

```bash
sudo cp omen-fand.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now omen-fand
```

## Fan Curve

The default curve is aggressive to prevent thermal lid sensor trips:

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

Custom curves can be set via JSON config:

```bash
python3 omen-fand.py --write-config fan.json  # generate default
python3 omen-fand.py -c fan.json              # use custom config
```

## Hall Effect Lid Sensor Workaround

If you're experiencing false lid-close shutdowns, add to `/etc/systemd/logind.conf`:

```ini
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
```

And add `button.lid_init_state=open` to your kernel boot parameters.

## The Proper Fix

The upstream kernel fix is a one-line patch adding `"8BCA"` to the `victus_s_thermal_profile_boards` array in `drivers/platform/x86/hp/hp-wmi.c`. A patch for the `platform-drivers-x86` mailing list is in progress.

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

- Tested on: HP Omen 16-xf0xxx, Board ID 8BCA, Fedora 43, kernel 6.19.10
- Should work on any Linux kernel 6.x with headers available
- Other HP Omen/Victus boards missing from the upstream list may benefit — use `hp_wmi_fan_test.ko` to check

## Kernel Update Note

After a kernel update, you need to rebuild and reinstall the module:

```bash
cd omen-fan-tools
make clean && make
sudo cp hp_wmi_fan_ctrl.ko /lib/modules/$(uname -r)/extra/
sudo depmod -a
sudo systemctl restart omen-fand
```

## License

GPL-2.0 (matching the Linux kernel)
