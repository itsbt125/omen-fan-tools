#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODULE_NAME="hp_wmi_fan_ctrl"
DKMS_NAME="hp-wmi-fan-ctrl"
DKMS_VER="1.0"

ACTION="install"
KVER="$(uname -r)"
case "${1:-}" in
    --uninstall|-u) ACTION="uninstall" ;;
    "") ;;
    *) KVER="$1" ;;
esac

# Colored output (only when attached to a terminal that supports it)
if [ -t 1 ] && command -v tput &>/dev/null && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
    BOLD="$(tput bold)"; RESET="$(tput sgr0)"
    RED="$(tput setaf 1)"; GREEN="$(tput setaf 2)"; YELLOW="$(tput setaf 3)"; BLUE="$(tput setaf 4)"
else
    BOLD=""; RESET=""; RED=""; GREEN=""; YELLOW=""; BLUE=""
fi

heading() { echo "${BOLD}${BLUE}== $* ==${RESET}"; }
step()    { echo "${BOLD}${BLUE}==>${RESET} $*"; }
ok()      { echo "${GREEN}$*${RESET}"; }
warn()    { echo "${YELLOW}WARNING:${RESET} $*"; }
err()     { echo "${RED}ERROR:${RESET} $*" >&2; }

is_installed() {
    [ -f /usr/local/bin/omen-fand ] ||
    [ -f /etc/systemd/system/omen-fand.service ] ||
    [ -f /etc/init.d/omen-fand ] ||
    [ -d /etc/sv/omen-fand ] ||
    [ -f /etc/kernel/install.d/99-omen-fan.install ] ||
    dkms status "$DKMS_NAME/$DKMS_VER" 2>/dev/null | grep -q "$DKMS_NAME"
}

uninstall() {
    heading "Removing existing omen-fan-tools installation"

    if command -v systemctl &>/dev/null; then
        systemctl stop omen-fand 2>/dev/null || true
        systemctl disable omen-fand 2>/dev/null || true
        rm -f /etc/systemd/system/omen-fand.service
        systemctl daemon-reload
    fi
    if command -v rc-service &>/dev/null; then
        rc-service omen-fand stop 2>/dev/null || true
        rc-update del omen-fand default 2>/dev/null || true
        rm -f /etc/init.d/omen-fand
    fi
    if command -v sv &>/dev/null && [ -d /etc/sv/omen-fand ]; then
        # Take the service down and remove the "enabled" symlink before the
        # service dir itself, so runsvdir stops supervising it cleanly.
        for svc_dir in /var/service /etc/runit/runsvdir/default /service; do
            [ -L "$svc_dir/omen-fand" ] && rm -f "$svc_dir/omen-fand"
        done
        sv down omen-fand 2>/dev/null || true
        rm -rf /etc/sv/omen-fand
    fi

    rm -f /usr/local/bin/omen-fand /usr/local/bin/omen-fan /run/omen-fand-hold
    rm -f "/etc/modules-load.d/$MODULE_NAME.conf"

    rmmod "$MODULE_NAME" 2>/dev/null || true

    if dkms status "$DKMS_NAME/$DKMS_VER" 2>/dev/null | grep -q "$DKMS_NAME"; then
        dkms remove "$DKMS_NAME/$DKMS_VER" --all 2>/dev/null || true
        rm -rf "/usr/src/$DKMS_NAME-$DKMS_VER"
    fi

    rm -f /etc/kernel/install.d/99-omen-fan.install

    # DKMS installs compressed (.ko.xz/.ko.zst) on some distros - match all
    for ko in /lib/modules/*/extra/$MODULE_NAME.ko*; do
        [ -e "$ko" ] || continue
        rm -f "$ko"
        depmod -a "$(basename "$(dirname "$(dirname "$ko")")")"
    done

    echo ""
    ok "Uninstalled."
}

heading "omen-fan-tools install"
echo "Kernel: $KVER"
echo "Source: $SCRIPT_DIR"
echo ""

# Check prerequisites
if [ "$(id -u)" -ne 0 ]; then
    err "Run as root (sudo $0)"
    exit 1
fi

if [ "$ACTION" = "uninstall" ]; then
    uninstall
    exit 0
fi

if is_installed; then
    warn "An existing omen-fan-tools installation was detected."
    if [ -t 0 ]; then
        read -r -p "Reinstall (overwrite), uninstall, or cancel? [R/u/c] " ANSWER
        case "${ANSWER,,}" in
            u|uninstall)
                uninstall
                exit 0
                ;;
            c|cancel)
                echo "Cancelled."
                exit 0
                ;;
            *)
                echo "Reinstalling..."
                ;;
        esac
    else
        echo "Non-interactive shell - reinstalling automatically."
    fi
    echo ""
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
    err "Kernel headers not found for $KVER"
    echo "  $PKG_HINT"
    exit 1
fi

# Choose install method: DKMS (preferred, auto-rebuilds) or manual
USE_DKMS=false
if command -v dkms &>/dev/null; then
    USE_DKMS=true
    ok "DKMS found - module will auto-rebuild on kernel updates"
else
    warn "DKMS not found - using kernel-install hook for auto-rebuild"
    echo "  (Install dkms for better cross-distro support: $PKG_HINT)"
fi
echo ""

if $USE_DKMS; then
    # --- DKMS install path ---
    step "[1/4] Installing source to DKMS..."
    DKMS_SRC="/usr/src/$DKMS_NAME-$DKMS_VER"

    # Remove old DKMS registration if present
    dkms status "$DKMS_NAME/$DKMS_VER" 2>/dev/null | grep -q "$DKMS_NAME" && \
        dkms remove "$DKMS_NAME/$DKMS_VER" --all 2>/dev/null || true

    # Remove the manual-path kernel-install hook if it's still around - it
    # rebuilds-and-depmods on every "kernel-install add", which fights with
    # DKMS's own rebuild and can loop the two off each other indefinitely.
    if [ -f /etc/kernel/install.d/99-omen-fan.install ]; then
        rm -f /etc/kernel/install.d/99-omen-fan.install
        ok "    Removed stale kernel-install hook (DKMS handles rebuilds now)"
    fi

    rm -rf "$DKMS_SRC"
    mkdir -p "$DKMS_SRC"
    cp "$SCRIPT_DIR/$MODULE_NAME.c" "$DKMS_SRC/"
    cp "$SCRIPT_DIR/Makefile" "$DKMS_SRC/"
    cp "$SCRIPT_DIR/dkms.conf" "$DKMS_SRC/"

    step "[2/4] Building and installing via DKMS..."
    dkms add "$DKMS_NAME/$DKMS_VER"
    dkms build "$DKMS_NAME/$DKMS_VER" -k "$KVER"
    dkms install "$DKMS_NAME/$DKMS_VER" -k "$KVER"
else
    # --- Manual install path ---
    # Remove any DKMS registration from a previous install - leaving it in
    # place would mean both DKMS and our copied .ko try to provide the same
    # module on the next kernel update.
    if dkms status "$DKMS_NAME/$DKMS_VER" 2>/dev/null | grep -q "$DKMS_NAME"; then
        dkms remove "$DKMS_NAME/$DKMS_VER" --all 2>/dev/null || true
        rm -rf "/usr/src/$DKMS_NAME-$DKMS_VER"
        ok "    Removed stale DKMS registration (using kernel-install hook instead)"
    fi

    step "[1/4] Building module..."
    make -C "$SCRIPT_DIR" clean 2>/dev/null || true
    make -C "$SCRIPT_DIR" KDIR="/lib/modules/$KVER/build"

    step "[2/4] Installing module..."
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

build_and_install() {
    # Headers (kernel-devel) often land a few seconds *after* kernel-core
    # triggers this hook, so /lib/modules/\$KVER/build may not exist yet.
    # Poll for up to 2 minutes before giving up.
    for _ in \$(seq 1 24); do
        [ -d "/lib/modules/\$KVER/build" ] && break
        sleep 5
    done
    [ -d "/lib/modules/\$KVER/build" ] || {
        echo "omen-fan: kernel headers never appeared for \$KVER, skipping" \
            | systemd-cat -t omen-fan
        return
    }

    make -C "\$OMEN_SRC" clean >/dev/null 2>&1
    if make -C "\$OMEN_SRC" KDIR="/lib/modules/\$KVER/build" >/dev/null 2>&1; then
        mkdir -p "/lib/modules/\$KVER/extra"
        cp "\$OMEN_SRC/$MODULE_NAME.ko" "/lib/modules/\$KVER/extra/"
        depmod -a "\$KVER"
        echo "omen-fan: module installed for kernel \$KVER" | systemd-cat -t omen-fan
    else
        echo "omen-fan: WARNING - build failed for \$KVER. Run: sudo $SCRIPT_DIR/install.sh \$KVER" \
            | systemd-cat -t omen-fan
    fi
}

if [ "\$COMMAND" = "add" ]; then
    # Run in the background so a slow/missing header install doesn't hold
    # up the package transaction.
    build_and_install &
    disown
fi
HOOK
        chmod 755 "$HOOK_DIR/99-omen-fan.install"
        ok "    Installed kernel-install hook: $HOOK_DIR/99-omen-fan.install"
    fi
fi

RUNNING_KERNEL=false
[ "$KVER" = "$(uname -r)" ] && RUNNING_KERNEL=true

# Load the module at every boot via systemd-modules-load/OpenRC modules;
# the service's ExecCondition alone runs too early to do the modprobe itself.
mkdir -p /etc/modules-load.d
echo "$MODULE_NAME" > "/etc/modules-load.d/$MODULE_NAME.conf"

# Load module if installing for running kernel
if $RUNNING_KERNEL; then
    step "[3/4] Loading module..."
    rmmod "$MODULE_NAME" 2>/dev/null || true
    modprobe "$MODULE_NAME"
    echo "    $(cat /sys/module/$MODULE_NAME/fans 2>/dev/null)"
else
    step "[3/4] Skipping load (target kernel $KVER is not running)"
fi

# Install daemon and service
step "[4/4] Installing daemon and service..."
cp "$SCRIPT_DIR/omen-fand.py" /usr/local/bin/omen-fand
cp "$SCRIPT_DIR/omen-fan" /usr/local/bin/omen-fan
chmod 755 /usr/local/bin/omen-fand /usr/local/bin/omen-fan
# Fix SELinux context if applicable
command -v restorecon &>/dev/null && restorecon /usr/local/bin/omen-fand /usr/local/bin/omen-fan

if command -v systemctl &>/dev/null; then
    INIT_SYSTEM="systemd"
    cp "$SCRIPT_DIR/omen-fand.service" /etc/systemd/system/omen-fand.service
    systemctl daemon-reload
    systemctl enable omen-fand
    $RUNNING_KERNEL && systemctl restart omen-fand
    SERVICE_STATE="$(systemctl is-active omen-fand 2>/dev/null || echo 'unknown')"
elif command -v rc-update &>/dev/null; then
    INIT_SYSTEM="OpenRC"
    cp "$SCRIPT_DIR/omen-fand.openrc" /etc/init.d/omen-fand
    chmod 755 /etc/init.d/omen-fand
    rc-update add omen-fand default
    $RUNNING_KERNEL && rc-service omen-fand restart
    SERVICE_STATE="$(rc-service omen-fand status 2>/dev/null | awk '{print $NF}' || echo 'unknown')"
elif command -v sv &>/dev/null && [ -d /etc/sv ]; then
    INIT_SYSTEM="runit"
    mkdir -p /etc/sv/omen-fand
    cp "$SCRIPT_DIR/omen-fand.run" /etc/sv/omen-fand/run
    cp "$SCRIPT_DIR/omen-fand.finish" /etc/sv/omen-fand/finish
    chmod 755 /etc/sv/omen-fand/run /etc/sv/omen-fand/finish
    command -v restorecon &>/dev/null && restorecon -R /etc/sv/omen-fand

    # Enable by symlinking into the active runsvdir. /var/service is the Void
    # default; fall back to other common layouts if it's absent.
    SVDIR=""
    for d in /var/service /etc/runit/runsvdir/default /service; do
        if [ -d "$d" ]; then SVDIR="$d"; break; fi
    done
    if [ -n "$SVDIR" ]; then
        ln -sf /etc/sv/omen-fand "$SVDIR/omen-fand"
        # runsvdir scans on an interval; give it a moment to spawn runsv.
        if $RUNNING_KERNEL; then
            for _ in $(seq 1 10); do
                [ -e "$SVDIR/omen-fand/supervise/ok" ] && break
                sleep 1
            done
            sv restart omen-fand 2>/dev/null || true
        fi
        SERVICE_STATE="$(sv status omen-fand 2>/dev/null | awk '{print $1}' | tr -d ':' || echo 'unknown')"
    else
        warn "No runit service directory found (looked in /var/service, /etc/runit/runsvdir/default, /service)."
        echo "  Symlink it manually: ln -s /etc/sv/omen-fand /var/service/omen-fand"
        SERVICE_STATE="installed (not enabled)"
    fi
else
    INIT_SYSTEM="none"
    SERVICE_STATE="not installed"
    warn "No supported init system detected (systemd, OpenRC, runit)."
    echo "  Run /usr/local/bin/omen-fand manually or wire it into your init system."
fi

echo ""
heading "Done"
echo "Module:  $MODULE_NAME ($( $USE_DKMS && echo 'DKMS - auto-rebuilds on kernel updates' || echo 'manual - hook installed for auto-rebuild' ))"
echo "Daemon:  /usr/local/bin/omen-fand"
state_color="$GREEN"; case "$SERVICE_STATE" in active|started|run) ;; *) state_color="$YELLOW" ;; esac
echo "Service: omen-fand ($INIT_SYSTEM, ${state_color}${SERVICE_STATE}${RESET})"
if $USE_DKMS; then
    echo ""
    echo "DKMS will auto-rebuild the module on kernel updates."
else
    echo ""
    echo "If auto-rebuild fails after a kernel update, run:"
    echo "  sudo $SCRIPT_DIR/install.sh"
fi
