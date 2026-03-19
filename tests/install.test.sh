#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/install.sh"

TEST_HOME="$(mktemp -d "${TMPDIR:-/tmp}/taskmaster-install-test.XXXXXX")"
trap 'rm -rf "$TEST_HOME"' EXIT

CODEX_ROOT="$TEST_HOME/.codex"
CODEX_SKILL_DIR="$CODEX_ROOT/skills/taskmaster"
CODEX_BIN_DIR="$CODEX_ROOT/bin"
CONFIG_PATH="$CODEX_ROOT/config.toml"
HOOKS_PATH="$CODEX_ROOT/hooks.json"

mkdir -p "$CODEX_BIN_DIR"

cat > "$CONFIG_PATH" <<'EOF'
[features]
existing_flag = true
EOF

cat > "$HOOKS_PATH" <<'EOF'
{
  "hooks": {
    "Stop": [
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

ln -sf "$CODEX_SKILL_DIR/run-taskmaster-codex.sh" "$CODEX_BIN_DIR/codex"
ln -sf "$CODEX_SKILL_DIR/run-taskmaster-codex.sh" "$CODEX_BIN_DIR/codex-taskmaster"

HOME="$TEST_HOME" SHELL="/bin/zsh" TASKMASTER_INSTALL_TARGET=codex bash "$SCRIPT" >/dev/null

python3 - "$CONFIG_PATH" "$HOOKS_PATH" "$CODEX_BIN_DIR" <<'PY'
import json
import sys
from pathlib import Path

config_path = Path(sys.argv[1])
hooks_path = Path(sys.argv[2])
bin_dir = Path(sys.argv[3])

config_text = config_path.read_text(encoding="utf-8")
if "codex_hooks = true" not in config_text:
    raise SystemExit("expected codex_hooks feature flag to be enabled")
if "existing_flag = true" not in config_text:
    raise SystemExit("expected existing config to be preserved")

hooks = json.loads(hooks_path.read_text(encoding="utf-8"))
session_start = "~/.codex/skills/taskmaster/hooks/taskmaster-session-start.sh"
stop = "~/.codex/skills/taskmaster/hooks/taskmaster-stop.sh"

session_start_count = 0
stop_count = 0
other_stop_count = 0
for entry in hooks.get("hooks", {}).get("SessionStart", []):
    for hook in entry.get("hooks", []):
        if hook.get("command") == session_start:
            session_start_count += 1

for entry in hooks.get("hooks", {}).get("Stop", []):
    if entry.get("matcher") == "other":
        other_stop_count += 1
    for hook in entry.get("hooks", []):
        if hook.get("command") == stop:
            stop_count += 1

if session_start_count != 1:
    raise SystemExit(f"expected one taskmaster session-start hook, got {session_start_count}")
if stop_count != 1:
    raise SystemExit(f"expected one taskmaster stop hook, got {stop_count}")
if other_stop_count != 1:
    raise SystemExit("expected unrelated stop hook entries to be preserved")

for name in ("codex", "codex-taskmaster"):
    path = bin_dir / name
    if path.exists() or path.is_symlink():
        raise SystemExit(f"expected legacy wrapper link to be removed: {path}")
PY

HOME="$TEST_HOME" SHELL="/bin/zsh" TASKMASTER_INSTALL_TARGET=codex bash "$SCRIPT" >/dev/null

python3 - "$HOOKS_PATH" <<'PY'
import json
import sys
from pathlib import Path

hooks = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
session_start = "~/.codex/skills/taskmaster/hooks/taskmaster-session-start.sh"
stop = "~/.codex/skills/taskmaster/hooks/taskmaster-stop.sh"

session_start_count = sum(
    1
    for entry in hooks.get("hooks", {}).get("SessionStart", [])
    for hook in entry.get("hooks", [])
    if hook.get("command") == session_start
)
stop_count = sum(
    1
    for entry in hooks.get("hooks", {}).get("Stop", [])
    for hook in entry.get("hooks", [])
    if hook.get("command") == stop
)

if session_start_count != 1 or stop_count != 1:
    raise SystemExit(
        f"expected install to be idempotent; got session_start={session_start_count}, stop={stop_count}"
    )
PY

echo "ok"
