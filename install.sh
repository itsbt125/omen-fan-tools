#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODULE_NAME="hp_wmi_fan_ctrl"
DKMS_NAME="hp-wmi-fan-ctrl"
DKMS_VER="1.0"
KVER="${1:-$(uname -r)}"

echo "=== omen-fan-tools install ==="
echo "Kernel: $KVER"
echo "Source: $SCRIPT_DIR"
echo ""

# Check prerequisites
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Run as root (sudo $0)"
    exit 1
fi

# Detect package manager for hints
if command -v dnf &>/dev/null; then
    PKG_HINT="sudo dnf install kernel-devel dkms"
elif command -v apt-get &>/dev/null; then
    PKG_HINT="sudo apt install linux-headers-\$(uname -r) dkms"
elif command -v pacman &>/dev/null; then
    PKG_HINT="sudo pacman -S linux-headers dkms"
else
    PKG_HINT="Install kernel headers and dkms for your distro"
fi

if [ ! -d "/lib/modules/$KVER/build" ]; then
    echo "ERROR: Kernel headers not found for $KVER"
    echo "  $PKG_HINT"
    exit 1
fi

# Choose install method: DKMS (preferred, auto-rebuilds) or manual
USE_DKMS=false
if command -v dkms &>/dev/null; then
    USE_DKMS=true
    echo "DKMS found - module will auto-rebuild on kernel updates"
else
    echo "DKMS not found - using kernel-install hook for auto-rebuild"
    echo "  (Install dkms for better cross-distro support: $PKG_HINT)"
fi
echo ""

if $USE_DKMS; then
    # --- DKMS install path ---
    echo "[1/4] Installing source to DKMS..."
    DKMS_SRC="/usr/src/$DKMS_NAME-$DKMS_VER"

    # Remove old DKMS registration if present
    dkms status "$DKMS_NAME/$DKMS_VER" 2>/dev/null | grep -q "$DKMS_NAME" && \
        dkms remove "$DKMS_NAME/$DKMS_VER" --all 2>/dev/null || true

    rm -rf "$DKMS_SRC"
    mkdir -p "$DKMS_SRC"
    cp "$SCRIPT_DIR/$MODULE_NAME.c" "$DKMS_SRC/"
    cp "$SCRIPT_DIR/Makefile" "$DKMS_SRC/"
    cp "$SCRIPT_DIR/dkms.conf" "$DKMS_SRC/"

    echo "[2/4] Building and installing via DKMS..."
    dkms add "$DKMS_NAME/$DKMS_VER"
    dkms build "$DKMS_NAME/$DKMS_VER" -k "$KVER"
    dkms install "$DKMS_NAME/$DKMS_VER" -k "$KVER"
else
    # --- Manual install path ---
    echo "[1/4] Building module..."
    make -C "$SCRIPT_DIR" clean 2>/dev/null || true
    make -C "$SCRIPT_DIR" KDIR="/lib/modules/$KVER/build"

    echo "[2/4] Installing module..."
    mkdir -p "/lib/modules/$KVER/extra"
    cp "$SCRIPT_DIR/$MODULE_NAME.ko" "/lib/modules/$KVER/extra/"
    depmod -a "$KVER"

    # Install kernel-install hook (Fedora/systemd-boot)
    if [ -d /etc/kernel/install.d ] || [ -d /usr/lib/kernel/install.d ]; then
        HOOK_DIR="/etc/kernel/install.d"
        mkdir -p "$HOOK_DIR"
        cat > "$HOOK_DIR/99-omen-fan.install" <<HOOK
#!/bin/bash
COMMAND="\$1"
KVER="\$2"
OMEN_SRC="$SCRIPT_DIR"

if [ "\$COMMAND" = "add" ] && [ -d "/lib/modules/\$KVER/build" ]; then
    echo "omen-fan: rebuilding module for kernel \$KVER..."
    make -C "\$OMEN_SRC" clean 2>/dev/null
    if make -C "\$OMEN_SRC" KDIR="/lib/modules/\$KVER/build" 2>/dev/null; then
        mkdir -p "/lib/modules/\$KVER/extra"
        cp "\$OMEN_SRC/$MODULE_NAME.ko" "/lib/modules/\$KVER/extra/"
        depmod -a "\$KVER"
        echo "omen-fan: module installed for kernel \$KVER"
    else
        echo "omen-fan: WARNING - build failed for \$KVER. Run: sudo $SCRIPT_DIR/install.sh \$KVER"
    fi
fi
HOOK
        chmod 755 "$HOOK_DIR/99-omen-fan.install"
        echo "    Installed kernel-install hook: $HOOK_DIR/99-omen-fan.install"
    fi
fi

# Load module if installing for running kernel
if [ "$KVER" = "$(uname -r)" ]; then
    echo "[3/4] Loading module..."
    rmmod "$MODULE_NAME" 2>/dev/null || true
    modprobe "$MODULE_NAME"
    echo "    $(cat /sys/module/$MODULE_NAME/fans 2>/dev/null)"
else
    echo "[3/4] Skipping load (target kernel $KVER is not running)"
fi

# Install daemon and service
echo "[4/4] Installing daemon and service..."
cp "$SCRIPT_DIR/omen-fand.py" /usr/local/bin/omen-fand
cp "$SCRIPT_DIR/omen-fan" /usr/local/bin/omen-fan
chmod 755 /usr/local/bin/omen-fand /usr/local/bin/omen-fan
# Fix SELinux context if applicable
command -v restorecon &>/dev/null && restorecon /usr/local/bin/omen-fand /usr/local/bin/omen-fan

cat > /etc/systemd/system/omen-fand.service <<'EOF'
[Unit]
Description=HP Omen Fan Curve Daemon
After=multi-user.target
Wants=multi-user.target

[Service]
Type=simple
ExecStartPre=/sbin/modprobe hp_wmi
ExecStartPre=/sbin/modprobe hp_wmi_fan_ctrl
ExecStart=/usr/local/bin/omen-fand --verbose
ExecStopPost=/bin/sh -c 'echo auto > /sys/module/hp_wmi_fan_ctrl/fans 2>/dev/null || true'
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable omen-fand

if [ "$KVER" = "$(uname -r)" ]; then
    systemctl restart omen-fand
fi

echo ""
echo "=== Done ==="
echo "Module:  $MODULE_NAME ($( $USE_DKMS && echo 'DKMS - auto-rebuilds on kernel updates' || echo 'manual - hook installed for auto-rebuild' ))"
echo "Daemon:  /usr/local/bin/omen-fand"
echo "Service: omen-fand (enabled, $(systemctl is-active omen-fand 2>/dev/null || echo 'unknown'))"
if $USE_DKMS; then
    echo ""
    echo "DKMS will auto-rebuild the module on kernel updates."
else
    echo ""
    echo "If auto-rebuild fails after a kernel update, run:"
    echo "  sudo $SCRIPT_DIR/install.sh"
fi
