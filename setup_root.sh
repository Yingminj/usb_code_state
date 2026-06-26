#!/bin/bash
# One-time root setup for the Claude Code USB status light (CH340, 1a86:7523).
# Run with: sudo bash setup_root.sh
set -e

VID=1a86
PID=7523

echo "[1/4] Make sure brltty isn't hijacking the CH340..."
systemctl mask brltty.service 2>/dev/null || true
systemctl stop brltty.service 2>/dev/null || true

echo "[2/4] Register the device id with the ch341-uart driver (forces bind)..."
echo "$VID $PID" > /sys/bus/usb-serial/drivers/ch341-uart/new_id 2>/dev/null || true

echo "[3/4] Bind any currently-connected, still-unbound CH340 interface..."
for vfile in /sys/bus/usb/devices/*/idVendor; do
    dir=$(dirname "$vfile")
    if [ "$(cat "$vfile" 2>/dev/null)" = "$VID" ] && \
       [ "$(cat "$dir/idProduct" 2>/dev/null)" = "$PID" ]; then
        for intf in "$dir"/*:*; do
            iname=$(basename "$intf")
            if [ ! -e "$intf/driver" ]; then
                echo "    binding $iname"
                echo -n "$iname" > /sys/bus/usb/drivers/ch341/bind 2>/dev/null || true
            fi
        done
    fi
done

echo "[4/4] Install udev rule: stable /dev/claude_light symlink + world-writable..."
cat > /etc/udev/rules.d/99-claude-light.rules <<EOF
# Claude Code USB status light (CH340)
SUBSYSTEM=="tty", ATTRS{idVendor}=="$VID", ATTRS{idProduct}=="$PID", MODE="0666", SYMLINK+="claude_light"
EOF
udevadm control --reload-rules
udevadm trigger --subsystem-match=tty || true
sleep 1

echo
echo "Done. Detected serial devices:"
ls -l /dev/ttyUSB* /dev/claude_light 2>/dev/null || echo "  (none found — try unplugging and replugging the device)"
