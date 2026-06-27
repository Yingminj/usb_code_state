#!/bin/bash
# One-click setup for the Claude Code USB status light (CH340, 1a86:7523).
#
# Does two things:
#   1. Environment  — find/create a Python with pyserial (per-user, no sudo).
#   2. Privileges   — bind the CH340 driver + install the udev rule (via sudo).
#
# Run as your NORMAL user (it calls sudo itself when it needs root):
#   bash setup_root.sh
#
# The resolved interpreter is written to .claude_light_python so that
# install_hooks.sh can bake the same path into ~/.claude/settings.json.
set -e

VID=1a86
PID=7523
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY_FILE="$SCRIPT_DIR/.claude_light_python"

if [ "$(id -u)" -eq 0 ]; then
    echo "Run this as your normal user, NOT with sudo." >&2
    echo "It escalates with sudo only for the device/udev steps." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 0. Is the light actually plugged in?
# ---------------------------------------------------------------------------
device_present() {
    for vfile in /sys/bus/usb/devices/*/idVendor; do
        d=$(dirname "$vfile")
        if [ "$(cat "$vfile" 2>/dev/null)" = "$VID" ] && \
           [ "$(cat "$d/idProduct" 2>/dev/null)" = "$PID" ]; then
            return 0
        fi
    done
    return 1
}

if device_present; then
    echo "[0/5] Found CH340 device $VID:$PID."
else
    echo "[0/5] WARNING: CH340 $VID:$PID not detected on the USB bus."
    echo "      Plug the light in; continuing with environment + udev setup anyway."
fi

# ---------------------------------------------------------------------------
# 1. Environment: a Python that can 'import serial' (pyserial)
# ---------------------------------------------------------------------------
find_conda() {
    if command -v conda >/dev/null 2>&1; then echo conda; return 0; fi
    for base in "$HOME/anaconda3" "$HOME/miniconda3" "$HOME/miniforge3" /opt/conda; do
        [ -x "$base/bin/conda" ] && { echo "$base/bin/conda"; return 0; }
    done
    return 1
}

RESOLVED_PY=""
echo "[1/5] Resolving a Python with pyserial..."

if [ -n "${CLAUDE_LIGHT_PYTHON:-}" ] && "$CLAUDE_LIGHT_PYTHON" -c 'import serial' 2>/dev/null; then
    RESOLVED_PY="$CLAUDE_LIGHT_PYTHON"
    echo "    using \$CLAUDE_LIGHT_PYTHON: $RESOLVED_PY"
elif CONDA="$(find_conda)"; then
    if ! "$CONDA" env list | grep -qw usbstatus; then
        echo "    creating conda env 'usbstatus' (python=3.11 pyserial)..."
        "$CONDA" create -y -n usbstatus python=3.11 pyserial
    fi
    RESOLVED_PY="$("$CONDA" run -n usbstatus python -c 'import sys; print(sys.executable)')"
    if ! "$RESOLVED_PY" -c 'import serial' 2>/dev/null; then
        echo "    installing pyserial into 'usbstatus'..."
        "$CONDA" install -y -n usbstatus pyserial || "$CONDA" run -n usbstatus pip install pyserial
    fi
    echo "    using conda env python: $RESOLVED_PY"
elif command -v python3 >/dev/null 2>&1; then
    if ! python3 -c 'import serial' 2>/dev/null; then
        echo "    no conda; installing pyserial with 'pip install --user'..."
        python3 -m pip install --user pyserial
    fi
    RESOLVED_PY="$(command -v python3)"
    echo "    using system python3: $RESOLVED_PY"
else
    echo "    ERROR: no conda and no python3 found. Install Python first." >&2
    exit 1
fi

# Final sanity check + persist the path for install_hooks.sh.
if ! "$RESOLVED_PY" -c 'import serial' 2>/dev/null; then
    echo "    ERROR: '$RESOLVED_PY' still cannot import pyserial." >&2
    exit 1
fi
printf '%s\n' "$RESOLVED_PY" > "$PY_FILE"
echo "    interpreter recorded in $PY_FILE"

# ---------------------------------------------------------------------------
# 2-4. Privileges: driver bind + udev rule (need root -> sudo)
# ---------------------------------------------------------------------------
echo "[2/5] Make sure brltty isn't hijacking the CH340..."
sudo systemctl mask brltty.service 2>/dev/null || true
sudo systemctl stop brltty.service 2>/dev/null || true

echo "[3/5] Register the device id with the ch341-uart driver (forces bind)..."
echo "$VID $PID" | sudo tee /sys/bus/usb-serial/drivers/ch341-uart/new_id >/dev/null 2>&1 || true

echo "[4/5] Bind any currently-connected, still-unbound CH340 interface..."
for vfile in /sys/bus/usb/devices/*/idVendor; do
    dir=$(dirname "$vfile")
    if [ "$(cat "$vfile" 2>/dev/null)" = "$VID" ] && \
       [ "$(cat "$dir/idProduct" 2>/dev/null)" = "$PID" ]; then
        for intf in "$dir"/*:*; do
            iname=$(basename "$intf")
            if [ ! -e "$intf/driver" ]; then
                echo "    binding $iname"
                echo -n "$iname" | sudo tee /sys/bus/usb/drivers/ch341/bind >/dev/null 2>&1 || true
            fi
        done
    fi
done

echo "[5/5] Install udev rule: stable /dev/claude_light symlink + world-writable..."
sudo tee /etc/udev/rules.d/99-claude-light.rules >/dev/null <<EOF
# Claude Code USB status light (CH340)
SUBSYSTEM=="tty", ATTRS{idVendor}=="$VID", ATTRS{idProduct}=="$PID", MODE="0666", SYMLINK+="claude_light"
EOF
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=tty || true
sleep 1

echo
echo "Detected serial devices:"
ls -l /dev/ttyUSB* /dev/claude_light 2>/dev/null || echo "  (none found — try unplugging and replugging the device)"

# ---------------------------------------------------------------------------
# Smoke test
# ---------------------------------------------------------------------------
echo
echo "Smoke test: cycling the light (yellow -> green -> red -> off)..."
"$RESOLVED_PY" "$SCRIPT_DIR/claude_light.py" test || \
    echo "  (test failed — check the device is plugged in and bound)"

echo
echo "Done. Next: run 'bash install_hooks.sh' to wire the light into Claude Code."
