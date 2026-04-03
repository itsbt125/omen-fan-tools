#!/usr/bin/env python3
"""
omen-fand - Fan curve daemon for HP Omen 16-xf0xxx (Board 8BCA)

Reads CPU/GPU temperatures and applies a configurable fan curve via
the hp_wmi_fan_ctrl kernel module.

Usage:
    sudo python3 omen-fand.py                  # run with defaults
    sudo python3 omen-fand.py --config fan.conf # custom config
    sudo python3 omen-fand.py --dry-run         # show what would happen
    sudo python3 omen-fand.py --once            # single pass, then exit

Requires: hp_wmi_fan_ctrl.ko loaded
"""

import argparse
import glob
import json
import os
import signal
import sys
import time

# --- Default fan curve ---
# Each entry: (temp_celsius, fan_speed_value)
# fan_speed_value: 0 = auto/off, 1-255 = manual (RPM = value * 100)
# Interpolation between points. Below min = first value. Above max = last value.
DEFAULT_CURVE = [
    (35, 20),   # 35C+: ~2000 RPM baseline (never fully off)
    (45, 30),   # 45C: ~3000 RPM
    (55, 40),   # 55C: ~4000 RPM
    (65, 50),   # 65C: ~5000 RPM
    (70, 60),   # 70C: ~6000 RPM
    (75, 70),   # 75C: ~7000 RPM
    (80, 80),   # 80C: ~8000 RPM
    (85, 255),  # 85C+: MAX (prevent thermal lid sensor trips)
]

FAN_CTRL_PATH = "/sys/module/hp_wmi_fan_ctrl/fans"
POLL_INTERVAL = 3.0       # seconds between temp checks
HYSTERESIS = 3            # degrees C before stepping down
SMOOTHING_WINDOW = 3      # number of readings to average


def find_temp_sources():
    """Find CPU and GPU thermal zone paths."""
    sources = {}

    # Check hwmon devices first (more reliable names)
    for hwmon in sorted(glob.glob("/sys/class/hwmon/hwmon*")):
        name_path = os.path.join(hwmon, "name")
        if not os.path.exists(name_path):
            continue
        with open(name_path) as f:
            name = f.read().strip()

        # CPU temps
        if name in ("k10temp", "coretemp", "zenpower"):
            # Find the highest-numbered temp input (usually Tctl or package)
            temps = sorted(glob.glob(os.path.join(hwmon, "temp*_input")))
            if temps:
                label = ""
                for t in temps:
                    label_path = t.replace("_input", "_label")
                    if os.path.exists(label_path):
                        with open(label_path) as f:
                            l = f.read().strip()
                        if l in ("Tctl", "Tdie", "Package id 0"):
                            sources["cpu"] = {"path": t, "name": name, "label": l}
                            break
                if "cpu" not in sources:
                    sources["cpu"] = {"path": temps[-1], "name": name, "label": "last"}

        # GPU temps (NVIDIA or AMD)
        if name in ("nvidia", "amdgpu"):
            temps = sorted(glob.glob(os.path.join(hwmon, "temp*_input")))
            if temps:
                sources["gpu"] = {"path": temps[0], "name": name, "label": "edge"}

    # Fallback to thermal zones if hwmon didn't find things
    if "cpu" not in sources:
        for tz in sorted(glob.glob("/sys/class/thermal/thermal_zone*")):
            type_path = os.path.join(tz, "type")
            if os.path.exists(type_path):
                with open(type_path) as f:
                    tz_type = f.read().strip()
                if tz_type in ("x86_pkg_temp", "acpitz"):
                    temp_path = os.path.join(tz, "temp")
                    if os.path.exists(temp_path):
                        sources["cpu"] = {"path": temp_path, "name": tz_type, "label": "thermal_zone"}
                        break

    return sources


def read_temp(path):
    """Read temperature in millidegrees C, return degrees C."""
    try:
        with open(path) as f:
            val = int(f.read().strip())
        # millidegrees to degrees
        if val > 1000:
            return val / 1000.0
        return float(val)
    except (IOError, ValueError):
        return None


def interpolate_curve(curve, temp):
    """Linearly interpolate fan speed from curve for given temperature."""
    if temp <= curve[0][0]:
        return curve[0][1]
    if temp >= curve[-1][0]:
        return curve[-1][1]

    for i in range(len(curve) - 1):
        t0, s0 = curve[i]
        t1, s1 = curve[i + 1]
        if t0 <= temp <= t1:
            frac = (temp - t0) / (t1 - t0)
            return int(s0 + frac * (s1 - s0))

    return curve[-1][1]


def read_fan_status():
    """Read current fan status from the kernel module."""
    try:
        with open(FAN_CTRL_PATH) as f:
            return f.read().strip()
    except IOError:
        return None


def set_fan_speeds(speed0, speed1):
    """Write fan speeds to the kernel module."""
    try:
        with open(FAN_CTRL_PATH, 'w') as f:
            f.write(f"{speed0} {speed1}\n")
        return True
    except IOError as e:
        print(f"ERROR: Failed to set fan speeds: {e}", file=sys.stderr)
        return False


def set_fan_auto():
    """Return fans to auto mode."""
    try:
        with open(FAN_CTRL_PATH, 'w') as f:
            f.write("auto\n")
        return True
    except IOError:
        return False


def load_config(path):
    """Load config from a JSON file."""
    with open(path) as f:
        cfg = json.load(f)

    result = {}
    if "curve" in cfg:
        result["curve"] = [(int(t), int(s)) for t, s in cfg["curve"]]
    if "poll_interval" in cfg:
        result["poll_interval"] = float(cfg["poll_interval"])
    if "hysteresis" in cfg:
        result["hysteresis"] = int(cfg["hysteresis"])
    if "smoothing_window" in cfg:
        result["smoothing_window"] = int(cfg["smoothing_window"])
    return result


def write_default_config(path):
    """Write a default config file."""
    cfg = {
        "curve": DEFAULT_CURVE,
        "poll_interval": POLL_INTERVAL,
        "hysteresis": HYSTERESIS,
        "smoothing_window": SMOOTHING_WINDOW,
        "_comment": "curve: [[temp_C, fan_value], ...]. fan_value 0=auto, 1-255=manual (RPM~=value*100)"
    }
    with open(path, 'w') as f:
        json.dump(cfg, f, indent=2)
    print(f"Default config written to {path}")


def main():
    parser = argparse.ArgumentParser(description="HP Omen fan curve daemon")
    parser.add_argument("--config", "-c", help="Path to config file (JSON)")
    parser.add_argument("--dry-run", "-n", action="store_true",
                        help="Show what would happen without changing fans")
    parser.add_argument("--once", action="store_true",
                        help="Run one iteration and exit")
    parser.add_argument("--write-config", metavar="PATH",
                        help="Write default config file and exit")
    parser.add_argument("--verbose", "-v", action="store_true")
    args = parser.parse_args()

    if args.write_config:
        write_default_config(args.write_config)
        return

    # Load config
    curve = DEFAULT_CURVE
    poll_interval = POLL_INTERVAL
    hysteresis = HYSTERESIS
    smoothing_window = SMOOTHING_WINDOW

    if args.config:
        cfg = load_config(args.config)
        curve = cfg.get("curve", curve)
        poll_interval = cfg.get("poll_interval", poll_interval)
        hysteresis = cfg.get("hysteresis", hysteresis)
        smoothing_window = cfg.get("smoothing_window", smoothing_window)

    # Check kernel module
    if not args.dry_run and not os.path.exists(FAN_CTRL_PATH):
        print(f"ERROR: {FAN_CTRL_PATH} not found.", file=sys.stderr)
        print("Load the kernel module: sudo insmod hp_wmi_fan_ctrl.ko", file=sys.stderr)
        sys.exit(1)

    # Find temperature sources
    sources = find_temp_sources()
    if not sources:
        print("ERROR: No temperature sources found!", file=sys.stderr)
        sys.exit(1)

    print(f"omen-fand starting")
    print(f"  Temperature sources:")
    for key, src in sources.items():
        temp = read_temp(src["path"])
        print(f"    {key}: {src['name']} ({src['label']}) = {temp}C  [{src['path']}]")
    print(f"  Fan curve: {curve}")
    print(f"  Poll interval: {poll_interval}s, Hysteresis: {hysteresis}C")
    print(f"  Mode: {'DRY RUN' if args.dry_run else 'LIVE'}")
    print()

    # Graceful shutdown
    running = True
    def handle_signal(sig, frame):
        nonlocal running
        print(f"\nReceived signal {sig}, shutting down...")
        running = False
    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    # Smoothing buffer
    temp_history = []
    last_speed = -1

    try:
        while running:
            # Read temperatures
            temps = {}
            for key, src in sources.items():
                t = read_temp(src["path"])
                if t is not None:
                    temps[key] = t

            if not temps:
                print("WARNING: No temperature readings available", file=sys.stderr)
                time.sleep(poll_interval)
                continue

            # Use max of CPU/GPU temp for fan curve
            max_temp = max(temps.values())

            # Smoothing: average over window
            temp_history.append(max_temp)
            if len(temp_history) > smoothing_window:
                temp_history.pop(0)
            avg_temp = sum(temp_history) / len(temp_history)

            # Hysteresis: only decrease speed if temp dropped by hysteresis amount
            target_speed = interpolate_curve(curve, avg_temp)
            if target_speed < last_speed:
                # Check if temp is low enough to warrant decrease
                lower_temp = avg_temp + hysteresis
                lower_speed = interpolate_curve(curve, lower_temp)
                if lower_speed >= last_speed:
                    target_speed = last_speed  # hold current speed

            # Apply
            status = read_fan_status() if not args.dry_run else "dry-run"
            timestamp = time.strftime("%H:%M:%S")

            if args.verbose or args.dry_run or args.once:
                temp_str = " ".join(f"{k}={v:.1f}C" for k, v in temps.items())
                print(f"[{timestamp}] {temp_str} avg={avg_temp:.1f}C -> speed={target_speed} "
                      f"(last={last_speed}) | {status}")

            if target_speed != last_speed and not args.dry_run:
                if target_speed == 0:
                    set_fan_auto()
                else:
                    set_fan_speeds(target_speed, target_speed)
                last_speed = target_speed
            elif args.dry_run:
                last_speed = target_speed

            if args.once:
                break

            time.sleep(poll_interval)

    finally:
        if not args.dry_run and not args.once:
            print("Restoring auto fan mode...")
            set_fan_auto()
            print("Done.")


if __name__ == '__main__':
    main()
