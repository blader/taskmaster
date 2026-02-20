#!/usr/bin/env bash
#
# Taskmaster uninstaller for OpenClaw
#
# Removes the skill directory and deregisters the stop hook from openclaw.json.
#
set -euo pipefail

SKILL_DIR="$HOME/.openclaw/skills/taskmaster"
SETTINGS="$HOME/.openclaw/openclaw.json"

echo "Uninstalling Taskmaster..."

# 1. Remove skill directory
if [ -d "$SKILL_DIR" ]; then
  rm -rf "$SKILL_DIR"
  echo "  Removed $SKILL_DIR"
else
  echo "  Skill directory not found (already removed)"
fi

# 2. Remove hook from openclaw.json
if [ -f "$SETTINGS" ] && command -v jq &>/dev/null; then
  TMP=$(mktemp)
  jq '
    if .hooks and .hooks.Stop then
      .hooks.Stop |= map(
        .hooks |= map(select(.command | test("taskmaster") | not))
        | select(.hooks | length > 0)
      )
      | if (.hooks.Stop | length) == 0 then del(.hooks.Stop) else . end
      | if (.hooks | length) == 0 then del(.hooks) else . end
    else . end
  ' "$SETTINGS" > "$TMP" && mv "$TMP" "$SETTINGS"
  echo "  Removed stop hook from $SETTINGS"
else
  echo "  Could not auto-remove hook from settings (jq not found or no settings file)."
  echo "  Manually remove the Taskmaster Stop hook entry from $SETTINGS"
fi

echo ""
echo "Done. Taskmaster has been uninstalled."
