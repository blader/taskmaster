#!/usr/bin/env bash
#
# Taskmaster installer for OpenClaw
#
# Installs the skill + stop hook and registers it in ~/.openclaw/openclaw.json.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$HOME/.openclaw/skills/taskmaster"
SETTINGS="$HOME/.openclaw/openclaw.json"

echo "Installing Taskmaster for OpenClaw..."

# 1. Copy skill files
mkdir -p "$SKILL_DIR/scripts"
cp "$SCRIPT_DIR/SKILL.md" "$SKILL_DIR/SKILL.md"
cp "$SCRIPT_DIR/scripts/check-completion.sh" "$SKILL_DIR/scripts/check-completion.sh"
chmod +x "$SKILL_DIR/scripts/check-completion.sh"
echo "  Skill installed to $SKILL_DIR"

# 2. Register the stop hook in openclaw.json
HOOK_CMD="\$HOME/.openclaw/skills/taskmaster/scripts/check-completion.sh"

if [ ! -f "$SETTINGS" ]; then
  # No settings file — create one with just the hook
  cat > "$SETTINGS" <<EOF
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$HOOK_CMD",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
EOF
  echo "  Created $SETTINGS with stop hook"
elif ! grep -q 'check-completion.sh' "$SETTINGS" 2>/dev/null; then
  # Settings exists but hook not registered — merge it in
  if command -v jq &>/dev/null; then
    HOOK_ENTRY=$(cat <<EOF
[{"hooks":[{"type":"command","command":"$HOOK_CMD","timeout":10}]}]
EOF
)
    TMP=$(mktemp)
    jq --argjson hook "$HOOK_ENTRY" '
      .hooks //= {} |
      .hooks.Stop //= [] |
      .hooks.Stop += $hook
    ' "$SETTINGS" > "$TMP" && mv "$TMP" "$SETTINGS"
    echo "  Added stop hook to $SETTINGS"
  else
    echo ""
    echo "  jq not found — could not auto-register the hook."
    echo "  Add this manually to $SETTINGS:"
    echo ""
    echo '  "hooks": {'
    echo '    "Stop": [{'
    echo '      "hooks": [{'
    echo '        "type": "command",'
    echo "        \"command\": \"$HOOK_CMD\","
    echo '        "timeout": 10'
    echo '      }]'
    echo '    }]'
    echo '  }'
    echo ""
  fi
else
  echo "  Stop hook already registered in $SETTINGS"
fi

echo ""
echo "Done. Restart OpenClaw to activate Taskmaster."
