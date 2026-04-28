#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/uninstall.sh"

TEST_HOME="$(mktemp -d "${TMPDIR:-/tmp}/taskmaster-uninstall-test.XXXXXX")"
trap 'rm -rf "$TEST_HOME"' EXIT

CODEX_ROOT="$TEST_HOME/.codex"
CODEX_SKILL_DIR="$CODEX_ROOT/skills/taskmaster"
CODEX_BIN_DIR="$CODEX_ROOT/bin"
CONFIG_PATH="$CODEX_ROOT/config.toml"
HOOKS_PATH="$CODEX_ROOT/hooks.json"

mkdir -p "$CODEX_SKILL_DIR/hooks" "$CODEX_BIN_DIR"

cat > "$CONFIG_PATH" <<'EOF'
[features]
codex_hooks = true
existing_flag = true
EOF

cat > "$HOOKS_PATH" <<'EOF'
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "^(startup|resume|clear)$",
        "hooks": [
          {
            "type": "command",
            "command": "~/.codex/skills/taskmaster/hooks/taskmaster-session-start.sh"
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.codex/skills/taskmaster/hooks/taskmaster-user-prompt-submit.sh"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.codex/skills/taskmaster/hooks/taskmaster-stop.sh"
          }
        ]
      },
      {
        "matcher": "other",
        "hooks": [
          {
            "type": "command",
            "command": "~/.codex/other-stop.sh"
          }
        ]
      }
    ]
  }
}
EOF

touch "$CODEX_SKILL_DIR/run-taskmaster-codex.sh"
ln -sf "$CODEX_SKILL_DIR/run-taskmaster-codex.sh" "$CODEX_BIN_DIR/codex"
ln -sf "$CODEX_SKILL_DIR/run-taskmaster-codex.sh" "$CODEX_BIN_DIR/codex-taskmaster"

HOME="$TEST_HOME" TASKMASTER_UNINSTALL_TARGET=codex bash "$SCRIPT" >/dev/null

python3 - "$CONFIG_PATH" "$HOOKS_PATH" "$CODEX_BIN_DIR" "$CODEX_SKILL_DIR" <<'PY'
import json
import sys
from pathlib import Path

config_path = Path(sys.argv[1])
hooks_path = Path(sys.argv[2])
bin_dir = Path(sys.argv[3])
skill_dir = Path(sys.argv[4])

config_text = config_path.read_text(encoding="utf-8")
if "codex_hooks = true" not in config_text:
    raise SystemExit("expected codex_hooks feature flag to be preserved")
if "existing_flag = true" not in config_text:
    raise SystemExit("expected unrelated config to be preserved")

hooks = json.loads(hooks_path.read_text(encoding="utf-8"))
session_start = "~/.codex/skills/taskmaster/hooks/taskmaster-session-start.sh"
user_prompt_submit = "~/.codex/skills/taskmaster/hooks/taskmaster-user-prompt-submit.sh"
stop = "~/.codex/skills/taskmaster/hooks/taskmaster-stop.sh"

for entry in hooks.get("hooks", {}).get("SessionStart", []):
    for hook in entry.get("hooks", []):
        if hook.get("command") == session_start:
            raise SystemExit("expected taskmaster session-start hook to be removed")

for entry in hooks.get("hooks", {}).get("UserPromptSubmit", []):
    for hook in entry.get("hooks", []):
        if hook.get("command") == user_prompt_submit:
            raise SystemExit("expected taskmaster user-prompt-submit hook to be removed")

for entry in hooks.get("hooks", {}).get("Stop", []):
    for hook in entry.get("hooks", []):
        if hook.get("command") == stop:
            raise SystemExit("expected taskmaster stop hook to be removed")

other_hooks = hooks.get("hooks", {}).get("Stop", [])
if not any(entry.get("matcher") == "other" for entry in other_hooks):
    raise SystemExit("expected unrelated stop hook to be preserved")

for name in ("codex", "codex-taskmaster"):
    path = bin_dir / name
    if path.exists() or path.is_symlink():
        raise SystemExit(f"expected legacy wrapper link to be removed: {path}")

if skill_dir.exists():
    raise SystemExit(f"expected skill dir to be removed: {skill_dir}")
PY

echo "ok"
