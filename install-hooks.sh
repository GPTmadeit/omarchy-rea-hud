#!/usr/bin/env bash
# Wire the REA HUD into Claude Code: adds PreToolUse / PostToolUse /
# PostToolUseFailure hooks for mcp__rea__* tools to your Claude Code settings.
#
#   ./install-hooks.sh              install (safe to re-run)
#   ./install-hooks.sh --uninstall  remove the hooks again
#
# Honors CLAUDE_CONFIG_DIR; defaults to ~/.claude/settings.json. A timestamped
# backup of the settings file is written before any change.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hook="$here/rea-hud-hook.py"
settings="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
mode="install"
[[ "${1:-}" == "--uninstall" ]] && mode="uninstall"

if [[ ! -f "$hook" ]]; then
  echo "rea-hud-hook.py not found next to this script" >&2
  exit 1
fi
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }

mkdir -p "$(dirname "$settings")"
[[ -f "$settings" ]] && cp "$settings" "$settings.bak.$(date +%s)"

python3 -I - "$settings" "$hook" "$mode" <<'EOF'
import json, os, sys

path, hook, mode = sys.argv[1:4]
try:
    with open(path) as fh:
        settings = json.load(fh)
except FileNotFoundError:
    settings = {}

# Guarded so a removed plugin can never block a tool call: a missing script
# would make python exit 2, which Claude Code treats as "block this tool".
command = 'f="%s"; [ -f "$f" ] && python3 -I "$f" || true' % hook
events = ("PreToolUse", "PostToolUse", "PostToolUseFailure")
hooks = settings.setdefault("hooks", {})

for event in events:
    groups = []
    for group in hooks.get(event, []):
        kept = [h for h in group.get("hooks", []) if "rea-hud-hook.py" not in h.get("command", "")]
        if kept:
            groups.append(dict(group, hooks=kept))
    if mode == "install":
        groups.append({
            "matcher": "mcp__rea__.*",
            "hooks": [{"type": "command", "command": command, "timeout": 5}],
        })
    if groups:
        hooks[event] = groups
    else:
        hooks.pop(event, None)

if not hooks:
    settings.pop("hooks", None)

with open(path, "w") as fh:
    json.dump(settings, fh, indent=2)
    fh.write("\n")
EOF

if [[ "$mode" == "install" ]]; then
  echo "REA HUD hooks installed in $settings"
  echo "Restart any running Claude Code sessions to pick them up."
else
  echo "REA HUD hooks removed from $settings"
fi
