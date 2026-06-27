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
- `setup_root.sh` — one-click setup: resolves/creates the Python env, then binds the driver and installs the udev rule
- `install_hooks.sh` — merges the status-light hooks into the global `~/.claude/settings.json`
- `.claude_light_python` — interpreter path recorded by `setup_root.sh` for `install_hooks.sh` (git-ignored, machine-specific)
- `~/.claude/settings.json` — hooks mapping Claude Code events to light states (installed globally, applies to all sessions)

## Setup

Two steps, both run as your **normal user** (no `sudo` prefix — `setup_root.sh`
escalates with `sudo` itself only for the device/udev steps):

```
bash setup_root.sh      # 1. env + driver + udev, then a smoke test
bash install_hooks.sh   # 2. wire the light into Claude Code
```

Then start a **new** Claude Code session for the hooks to take effect.

`setup_root.sh` finds a pyserial-capable Python in this order: `$CLAUDE_LIGHT_PYTHON`
→ a conda env named `usbstatus` (created automatically if missing) → system
`python3` with `pip install --user pyserial`. The resolved path is written to
`.claude_light_python` and baked into the hook command by `install_hooks.sh`.
Both scripts are idempotent — re-run them any time (e.g. after moving the repo or
changing the interpreter); `install_hooks.sh` replaces only its own hook entries
and leaves any other hooks you've configured untouched.

## Manual use

```
PY=$(cat .claude_light_python)           # interpreter recorded by setup_root.sh
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
