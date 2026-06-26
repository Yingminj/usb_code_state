# Claude Code USB Status Light

A 3-color USB indicator light that reflects Claude Code's state, driven over a
CH340 USB-serial adapter (`1a86:7523`, 9600 baud).

| Color  | Meaning                                   |
|--------|-------------------------------------------|
| 🟡 Yellow | LLM generating / tools running         |
| 🟢 Green  | Turn complete, waiting for input       |
| 🔴 Red    | Permission prompt / authorization req. |

## Protocol

4-byte commands: `0xA0 + address + opcode + checksum`, where
`checksum = (0xA0 + address + opcode) & 0xFF`.

- address: yellow `0x01`, green `0x02`, red `0x03`
- opcode: off `0x00`, on `0x01`, flash `0x02`

Each color is an independent channel, so a single state is shown by turning the
other two channels off and the target on.

## Files

- `claude_light.py` — controller + Claude Code hook dispatcher
- `setup_root.sh` — one-time root setup (binds driver, installs udev rule)
- `~/.claude/settings.json` — hooks mapping Claude Code events to light states (installed globally, applies to all sessions)

## Setup

1. Conda env (already created): `conda create -n usbstatus python=3.11 pyserial`
2. Privileged setup (binds CH340 driver, creates `/dev/claude_light`, sets perms):
   ```
   sudo bash setup_root.sh
   ```

## Manual use

```
PY=/home/kewei/anaconda3/envs/usbstatus/bin/python
$PY claude_light.py test                 # cycle yellow -> green -> red -> off
$PY claude_light.py color yellow on      # show one color (others off)
$PY claude_light.py raw red flash        # single channel, flashing
$PY claude_light.py color off            # all off
```

Port resolution: `$CLAUDE_LIGHT_PORT` → first `/dev/ttyUSB*` → `/dev/ttyUSB0`.
The udev rule also creates a stable `/dev/claude_light` symlink.

## Hook mapping (`.claude/settings.json`)

| Hook event                          | Light        |
|-------------------------------------|--------------|
| UserPromptSubmit / PreToolUse / PostToolUse | 🟡 yellow on |
| Notification (permission/approval)  | 🔴 red on    |
| Notification (idle)                 | 🟢 green on  |
| Stop / SubagentStop                 | 🟢 green on  |

Hooks are installed globally in `~/.claude/settings.json`, so they fire in every
Claude Code session on this machine. A new session is needed to pick up the
settings after a change.
