#!/usr/bin/env python3
"""
EC Register Probe for HP Omen 16-xf0xxx (Board 8BCA)

Reads all 256 Embedded Controller registers via /dev/port using the
standard ACPI EC command protocol (ports 0x62 data, 0x66 cmd/status).

Must be run as root: sudo python3 ec_probe.py

Known EC offsets from other HP Omen models (for reference):
  0x44 = CPU fan write   (15-en0xxx)
  0x45 = GPU fan write   (15-en0xxx)
  0x46 = CPU fan read    (15-en0xxx)
  0x47 = GPU fan read    (15-en0xxx)
  0x58 = ACPI temp       (multiple models)
  0x62 = thermal profile flags (Omen, from hp_wmi.c)
  0x63 = thermal profile timer (Omen, from hp_wmi.c)
  0x95 = thermal profile / HPCM (Omen, from hp_wmi.c)
"""

import os
import struct
import sys
import time

EC_DATA_PORT = 0x62
EC_CMD_PORT  = 0x66

EC_CMD_READ  = 0x80
EC_CMD_WRITE = 0x81

EC_STATUS_OBF = 0x01  # Output Buffer Full
EC_STATUS_IBF = 0x02  # Input Buffer Full

TIMEOUT_US = 100_000  # 100ms


def port_read(fd, port):
    os.lseek(fd, port, os.SEEK_SET)
    return struct.unpack('B', os.read(fd, 1))[0]


def port_write(fd, port, val):
    os.lseek(fd, port, os.SEEK_SET)
    os.write(fd, struct.pack('B', val & 0xFF))


def wait_ibf_clear(fd, timeout_us=TIMEOUT_US):
    """Wait for Input Buffer Full bit to clear (EC ready for input)."""
    deadline = time.monotonic() + timeout_us / 1_000_000
    while time.monotonic() < deadline:
        status = port_read(fd, EC_CMD_PORT)
        if not (status & EC_STATUS_IBF):
            return True
    return False


def wait_obf_set(fd, timeout_us=TIMEOUT_US):
    """Wait for Output Buffer Full bit to set (EC has data ready)."""
    deadline = time.monotonic() + timeout_us / 1_000_000
    while time.monotonic() < deadline:
        status = port_read(fd, EC_CMD_PORT)
        if status & EC_STATUS_OBF:
            return True
    return False


def ec_read(fd, addr):
    """Read one byte from EC register at addr (0x00-0xFF)."""
    if not wait_ibf_clear(fd):
        return None
    port_write(fd, EC_CMD_PORT, EC_CMD_READ)
    if not wait_ibf_clear(fd):
        return None
    port_write(fd, EC_DATA_PORT, addr)
    if not wait_obf_set(fd):
        return None
    return port_read(fd, EC_DATA_PORT)


def ec_write(fd, addr, val):
    """Write one byte to EC register at addr (0x00-0xFF)."""
    if not wait_ibf_clear(fd):
        return False
    port_write(fd, EC_CMD_PORT, EC_CMD_WRITE)
    if not wait_ibf_clear(fd):
        return False
    port_write(fd, EC_DATA_PORT, addr)
    if not wait_ibf_clear(fd):
        return False
    port_write(fd, EC_DATA_PORT, val)
    return True


def dump_all_registers(fd):
    """Dump all 256 EC registers."""
    regs = {}
    for addr in range(256):
        val = ec_read(fd, addr)
        regs[addr] = val
    return regs


def print_register_dump(regs):
    """Print register dump in hex table format."""
    print("\nEC Register Dump (256 bytes)")
    print("=" * 67)
    print("     ", end="")
    for col in range(16):
        print(f" {col:02X}", end="")
    print()
    print("-" * 67)

    for row in range(16):
        base = row * 16
        print(f"0x{base:02X} |", end="")
        for col in range(16):
            addr = base + col
            val = regs.get(addr)
            if val is None:
                print(" ??", end="")
            else:
                print(f" {val:02X}", end="")
        print()
    print()


def identify_interesting_registers(regs):
    """Flag registers that look like they could be fan/thermal related."""
    print("Interesting registers (non-zero, potential fan/thermal):")
    print("-" * 60)

    known_offsets = {
        0x44: "CPU fan write (15-en0xxx)",
        0x45: "GPU fan write (15-en0xxx)",
        0x46: "CPU fan read (15-en0xxx)",
        0x47: "GPU fan read (15-en0xxx)",
        0x58: "ACPI temperature (multiple models)",
        0x62: "Thermal profile flags (hp_wmi.c)",
        0x63: "Thermal profile timer (hp_wmi.c)",
        0x95: "Thermal profile / HPCM (hp_wmi.c)",
    }

    for addr in range(256):
        val = regs.get(addr)
        if val is None:
            continue
        note = known_offsets.get(addr, "")
        # Show non-zero regs, or known offsets even if zero
        if val != 0 or addr in known_offsets:
            marker = " <-- KNOWN" if addr in known_offsets else ""
            print(f"  0x{addr:02X} = 0x{val:02X} ({val:3d})  {note}{marker}")

    print()


def monitor_fan_registers(fd, addrs, interval=1.0, count=10):
    """Monitor specific registers over time to correlate with fan activity."""
    print(f"\nMonitoring {len(addrs)} registers every {interval}s ({count} samples):")
    print("Timestamp  ", end="")
    for a in addrs:
        print(f" 0x{a:02X}", end="")
    print()
    print("-" * (11 + 5 * len(addrs)))

    for i in range(count):
        t = time.strftime("%H:%M:%S")
        print(f"{t}   ", end="")
        for a in addrs:
            val = ec_read(fd, a)
            if val is None:
                print("  ??", end="")
            else:
                print(f" {val:3d}", end="")
        print()
        if i < count - 1:
            time.sleep(interval)


def main():
    if os.geteuid() != 0:
        print("ERROR: This script must be run as root (sudo python3 ec_probe.py)")
        sys.exit(1)

    try:
        fd = os.open('/dev/port', os.O_RDWR)
    except PermissionError:
        print("ERROR: Cannot open /dev/port. Run as root.")
        sys.exit(1)
    except FileNotFoundError:
        print("ERROR: /dev/port not found. Is this an x86 Linux system?")
        sys.exit(1)

    print(f"HP Omen EC Register Probe")
    print(f"Board: 8BCA (OMEN 16-xf0xxx)")
    print(f"Time: {time.strftime('%Y-%m-%d %H:%M:%S')}")
    print()

    # Phase 1: Full register dump
    print("[1/3] Dumping all 256 EC registers...")
    regs = dump_all_registers(fd)
    print_register_dump(regs)
    identify_interesting_registers(regs)

    # Phase 2: Save raw dump to file
    dump_file = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ec_dump.txt")
    with open(dump_file, 'w') as f:
        f.write(f"# EC Register Dump - HP Omen 16-xf0xxx (8BCA)\n")
        f.write(f"# Date: {time.strftime('%Y-%m-%d %H:%M:%S')}\n")
        f.write(f"# Format: addr=value (hex)\n\n")
        for addr in range(256):
            val = regs.get(addr)
            if val is not None:
                f.write(f"0x{addr:02X}=0x{val:02X}\n")
    print(f"Raw dump saved to {dump_file}")

    # Phase 3: Monitor fan-candidate registers
    # Watch registers in the typical fan control range (0x40-0x50)
    # plus known thermal offsets
    fan_candidates = list(range(0x40, 0x50)) + [0x58, 0x62, 0x63, 0x95]
    print(f"\n[2/3] Monitoring fan-candidate registers (0x40-0x4F + thermal)...")
    print("       (Let this run, try toggling fans: echo 0 > pwm1_enable, then echo 2)")
    monitor_fan_registers(fd, fan_candidates, interval=1.0, count=15)

    # Phase 4: Wider monitoring for any changes
    # Take two snapshots 2 seconds apart, show what changed
    print(f"\n[3/3] Delta scan: taking two full snapshots 2s apart...")
    snap1 = dump_all_registers(fd)
    time.sleep(2)
    snap2 = dump_all_registers(fd)

    changed = []
    for addr in range(256):
        v1 = snap1.get(addr)
        v2 = snap2.get(addr)
        if v1 is not None and v2 is not None and v1 != v2:
            changed.append((addr, v1, v2))

    if changed:
        print(f"Registers that changed between snapshots:")
        for addr, v1, v2 in changed:
            print(f"  0x{addr:02X}: 0x{v1:02X} -> 0x{v2:02X} (delta: {v2 - v1:+d})")
    else:
        print("No registers changed between snapshots (system may be idle).")

    print(f"\nDone. Review the dump above and in {dump_file}")
    print("Next step: run under load to see which registers change with fan activity.")

    os.close(fd)


if __name__ == '__main__':
    main()
