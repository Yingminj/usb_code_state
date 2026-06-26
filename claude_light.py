#!/usr/bin/env python3
"""Claude Code USB status light controller.

Drives a 3-color (yellow/green/red) serial indicator light over a CH340
USB-serial adapter (9600 baud). Each color is an independent channel; the
host sends 4-byte commands: 0xA0 + address + opcode + checksum, where
checksum = (0xA0 + address + opcode) & 0xFF.

Usage:
    claude_light.py color <yellow|green|red|off> [on|flash]   # set exclusive state
    claude_light.py raw <yellow|green|red> <off|on|flash>     # single channel
    claude_light.py hook                                      # read Claude Code hook JSON on stdin
    claude_light.py test                                      # cycle through colors

Port is taken from $CLAUDE_LIGHT_PORT, else autodetected (/dev/ttyUSB*),
else defaults to /dev/ttyUSB0.
"""
import glob
import json
import os
import sys
import time

try:
    import serial  # pyserial
except ImportError:
    serial = None

BAUD = 9600

# address per color, opcode per mode
ADDR = {"yellow": 0x01, "green": 0x02, "red": 0x03}
OP = {"off": 0x00, "on": 0x01, "flash": 0x02}


def find_port():
    port = os.environ.get("CLAUDE_LIGHT_PORT")
    if port:
        return port
    candidates = sorted(glob.glob("/dev/ttyUSB*"))
    return candidates[0] if candidates else "/dev/ttyUSB0"


def build_cmd(color, mode):
    a = ADDR[color]
    o = OP[mode]
    chk = (0xA0 + a + o) & 0xFF
    return bytes([0xA0, a, o, chk])


def send(frames):
    """Send a list of 4-byte frames over the serial port."""
    if serial is None:
        sys.stderr.write("pyserial not installed\n")
        return False
    port = find_port()
    try:
        with serial.Serial(port, BAUD, timeout=1) as ser:
            for fr in frames:
                ser.write(fr)
                ser.flush()
                time.sleep(0.03)  # small gap so the MCU registers each frame
        return True
    except Exception as e:  # never let the light break the hook flow
        sys.stderr.write(f"claude_light: serial error on {port}: {e}\n")
        return False


def set_color(color, mode="on"):
    """Show exactly one color (or all off). Turns the other channels off."""
    frames = []
    if color == "off":
        for c in ADDR:
            frames.append(build_cmd(c, "off"))
    else:
        for c in ADDR:
            if c != color:
                frames.append(build_cmd(c, "off"))
        frames.append(build_cmd(color, mode))
    return send(frames)


# Map Claude Code hook events -> light state.
#   yellow = LLM generating / tools running
#   green  = turn complete, waiting for input
#   red    = permission / authorization required
def handle_hook():
    raw = sys.stdin.read()
    try:
        data = json.loads(raw) if raw.strip() else {}
    except json.JSONDecodeError:
        data = {}
    event = data.get("hook_event_name", "")

    if event in ("UserPromptSubmit", "PreToolUse", "PostToolUse"):
        set_color("yellow", "on")
    elif event == "Notification":
        msg = (data.get("message") or "").lower()
        # Permission/approval requests -> red; idle "waiting for input" -> leave green.
        if any(k in msg for k in ("permission", "approve", "approval",
                                  "authoriz", "allow", "confirm")):
            set_color("red", "on")
        else:
            set_color("green", "on")
    elif event in ("Stop", "SubagentStop"):
        set_color("green", "on")
    # unknown events: do nothing


def main(argv):
    if not argv:
        print(__doc__)
        return 1
    cmd = argv[0]
    if cmd == "hook":
        handle_hook()
        return 0
    if cmd == "color":
        color = argv[1] if len(argv) > 1 else "off"
        mode = argv[2] if len(argv) > 2 else "on"
        return 0 if set_color(color, mode) else 1
    if cmd == "raw":
        color, mode = argv[1], argv[2]
        return 0 if send([build_cmd(color, mode)]) else 1
    if cmd == "test":
        for c in ("yellow", "green", "red"):
            print(f"-> {c} on")
            set_color(c, "on")
            time.sleep(1.2)
        print("-> off")
        set_color("off")
        return 0
    print(__doc__)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
