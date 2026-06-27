# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A 3-color (yellow/green/red) USB indicator light that reflects Claude Code's
state. The host drives a CH340 USB-serial adapter (`1a86:7523`, 9600 baud) and
Claude Code hooks invoke this controller to change the light as the session
moves through generating / waiting / permission-prompt states.

## Commands

Use a pyserial-capable Python (it lives in a conda env, not the system Python).
After running `setup_root.sh`, the resolved interpreter is in `.claude_light_python`:

```
PY=$(cat .claude_light_python)
$PY claude_light.py test                 # cycle yellow -> green -> red -> off
$PY claude_light.py color yellow on      # exclusive state: one color, others off
$PY claude_light.py raw red flash        # single channel, no implicit "off" of others
$PY claude_light.py color off            # all off
echo '{"hook_event_name":"Stop"}' | $PY claude_light.py hook   # exercise the hook path
```

There is no build step, test suite, or linter. Verification is hardware-driven:
run `test` and watch the light, or pipe hook JSON into `hook`.

Setup is two idempotent scripts, both run as the **normal user** (not `sudo` —
`setup_root.sh` escalates internally):

- `bash setup_root.sh` — resolves/creates the pyserial Python (writes the path to
  `.claude_light_python`), binds the CH340 driver, installs the udev rule, then
  smoke-tests the light. Re-run after a kernel/udev change or a fresh plug.
- `bash install_hooks.sh` — merges the status-light hooks into the global
  `~/.claude/settings.json` using the recorded interpreter. Re-run after moving
  the repo or changing the interpreter; it replaces only its own entries.

## Architecture

Single module, `claude_light.py`, with two layers:

- **Protocol/transport** (`build_cmd`, `send`, `set_color`): each color is an
  independent channel addressed by `ADDR` (yellow `0x01`, green `0x02`, red
  `0x03`); modes are `OP` (off `0x00`, on `0x01`, flash `0x02`). A frame is
  `0xA0 + address + opcode + checksum` where `checksum = (0xA0+addr+op) & 0xFF`.
  `set_color` shows *exactly one* color by emitting "off" frames for the other
  two channels plus the target frame — the device has no global state, so
  exclusivity is enforced host-side. A ~30ms gap between frames lets the MCU
  register each one.
- **Hook dispatcher** (`handle_hook`): reads Claude Code hook JSON on stdin,
  branches on `hook_event_name`. yellow = generating/tools running
  (UserPromptSubmit/PreToolUse/PostToolUse); green = idle/turn complete
  (Stop/SubagentStop, or Notification without permission keywords); red =
  Notification whose `message` contains permission/approval keywords. Red vs.
  green for `Notification` is decided purely by keyword-matching the message
  string.

Port resolution (`find_port`): `$CLAUDE_LIGHT_PORT` → first `/dev/ttyUSB*` →
`/dev/ttyUSB0`. The udev rule also provides a stable `/dev/claude_light`.

## Conventions that matter here

- **Never let the light break the session.** `send` swallows all serial errors
  (and missing pyserial) and returns False rather than raising, because this
  runs inside hooks on every event. Preserve that — a failed light must not
  fail a hook.
- **Hooks are installed globally**, in `~/.claude/settings.json` (not in this
  repo's `.claude/settings.json`, which only carries a pointer comment). They
  apply to every Claude Code session on the machine, and a session must be
  restarted to pick up changes. `install_hooks.sh` writes them there (a JSON
  merge that preserves unrelated keys/hooks); see the table in `README.md` for
  the event→color mapping.
