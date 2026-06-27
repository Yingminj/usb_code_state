#!/bin/bash
# Merge the status-light hooks into the GLOBAL Claude Code settings
# (~/.claude/settings.json) so the light reacts in every session.
#
# Idempotent: re-running replaces our own entries (e.g. after the interpreter
# path changes) without touching any other hooks you have configured.
#
#   bash install_hooks.sh
#
# Run setup_root.sh first so the pyserial interpreter is known.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY_FILE="$SCRIPT_DIR/.claude_light_python"
SETTINGS="$HOME/.claude/settings.json"

if [ "$(id -u)" -eq 0 ]; then
    echo "Run this as your normal user so it edits YOUR ~/.claude/settings.json." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Resolve the interpreter that will run the hook (must have pyserial).
# ---------------------------------------------------------------------------
PY=""
if [ -f "$PY_FILE" ]; then
    PY="$(head -n1 "$PY_FILE")"
elif [ -n "${CLAUDE_LIGHT_PYTHON:-}" ]; then
    PY="$CLAUDE_LIGHT_PYTHON"
elif command -v python3 >/dev/null 2>&1; then
    PY="$(command -v python3)"
fi

if [ -z "$PY" ] || ! "$PY" -c 'import serial' 2>/dev/null; then
    echo "ERROR: no pyserial-capable Python found." >&2
    echo "Run 'bash setup_root.sh' first (it records the interpreter in $PY_FILE)." >&2
    exit 1
fi

HOOK_CMD="\"$PY\" \"$SCRIPT_DIR/claude_light.py\" hook"
echo "Hook command: $HOOK_CMD"

mkdir -p "$HOME/.claude"
if [ -f "$SETTINGS" ]; then
    BAK="$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
    cp "$SETTINGS" "$BAK"
    echo "Backed up existing settings to $BAK"
fi

# ---------------------------------------------------------------------------
# Merge with Python (json) — preserves unrelated keys and other hooks.
# ---------------------------------------------------------------------------
"$PY" - "$SETTINGS" "$HOOK_CMD" <<'PYEOF'
import json, os, sys

settings_path, cmd = sys.argv[1], sys.argv[2]

# Events the dispatcher (claude_light.py hook) understands. PreToolUse/
# PostToolUse take a tool matcher; the rest fire without one.
NO_MATCHER = ["UserPromptSubmit", "Notification", "Stop", "SubagentStop"]
WITH_MATCHER = ["PreToolUse", "PostToolUse"]

data = {}
if os.path.exists(settings_path):
    with open(settings_path) as f:
        txt = f.read().strip()
        data = json.loads(txt) if txt else {}

hooks = data.setdefault("hooks", {})
entry = {"type": "command", "command": cmd}

def strip_ours(groups):
    """Drop previously-installed status-light hooks; keep everything else."""
    kept = []
    for g in groups:
        hs = [h for h in g.get("hooks", [])
              if "claude_light.py" not in h.get("command", "")]
        if hs:
            g["hooks"] = hs
            kept.append(g)
        elif not g.get("hooks"):
            kept.append(g)  # malformed/empty group, leave as-is
        # group that held only our hook -> dropped
    return kept

for ev in NO_MATCHER + WITH_MATCHER:
    groups = strip_ours(hooks.get(ev, []))
    grp = {"matcher": "*", "hooks": [entry]} if ev in WITH_MATCHER else {"hooks": [entry]}
    groups.append(grp)
    hooks[ev] = groups

with open(settings_path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")

print("Updated", settings_path)
PYEOF

echo
echo "Done. Hooks installed for: UserPromptSubmit, PreToolUse, PostToolUse,"
echo "Notification, Stop, SubagentStop."
echo "Start a NEW Claude Code session for the hooks to take effect."
