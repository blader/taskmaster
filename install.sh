#!/usr/bin/env bash
#
# Taskmaster installer for Codex and Claude.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CODEX_ROOT="$HOME/.codex"
CLAUDE_ROOT="$HOME/.claude"

CODEX_SKILL_DIR="$CODEX_ROOT/skills/taskmaster"
CLAUDE_SKILL_DIR="$CLAUDE_ROOT/skills/taskmaster"

CODEX_BIN_DIR="$CODEX_ROOT/bin"
CODEX_LAUNCHER_LINK="$CODEX_BIN_DIR/codex-taskmaster"
CODEX_SHIM_LINK="$CODEX_BIN_DIR/codex"
SUPERSET_CODEX_WRAPPER="$HOME/.superset/bin/codex"

CLAUDE_HOOKS_DIR="$CLAUDE_ROOT/hooks"
CLAUDE_HOOK_LINK="$CLAUDE_HOOKS_DIR/taskmaster-check-completion.sh"
CLAUDE_SETTINGS_PATH="$CLAUDE_ROOT/settings.json"
CLAUDE_HOOK_COMMAND="~/.claude/hooks/taskmaster-check-completion.sh"

safe_copy() {
  local src="$1"
  local dst="$2"
  local src_abs=""
  local dst_abs=""
  local dst_dir=""

  src_abs="$(cd -P "$(dirname "$src")" && pwd)/$(basename "$src")"
  dst_dir="$(dirname "$dst")"
  mkdir -p "$dst_dir"
  dst_abs="$(cd -P "$dst_dir" && pwd)/$(basename "$dst")"

  if [[ "$src_abs" == "$dst_abs" ]]; then
    return 0
  fi
  cp "$src" "$dst"
}

copy_skill_files() {
  local skill_dir="$1"

  mkdir -p "$skill_dir/hooks"
  mkdir -p "$skill_dir/docs"

  safe_copy "$SCRIPT_DIR/SKILL.md" "$skill_dir/SKILL.md"
  safe_copy "$SCRIPT_DIR/README.md" "$skill_dir/README.md"
  safe_copy "$SCRIPT_DIR/LICENSE" "$skill_dir/LICENSE"
  safe_copy "$SCRIPT_DIR/docs/SPEC.md" "$skill_dir/docs/SPEC.md"
  safe_copy "$SCRIPT_DIR/install.sh" "$skill_dir/install.sh"
  safe_copy "$SCRIPT_DIR/uninstall.sh" "$skill_dir/uninstall.sh"
  safe_copy "$SCRIPT_DIR/taskmaster-compliance-prompt.sh" "$skill_dir/taskmaster-compliance-prompt.sh"
  safe_copy "$SCRIPT_DIR/taskmaster-verify-command.sh" "$skill_dir/taskmaster-verify-command.sh"
  safe_copy "$SCRIPT_DIR/taskmaster-prompt-detect.sh" "$skill_dir/taskmaster-prompt-detect.sh"
  safe_copy "$SCRIPT_DIR/taskmaster-state.sh" "$skill_dir/taskmaster-state.sh"

  safe_copy "$SCRIPT_DIR/run-taskmaster-codex.sh" "$skill_dir/run-taskmaster-codex.sh"
  safe_copy "$SCRIPT_DIR/check-completion.sh" "$skill_dir/check-completion.sh"
  safe_copy "$SCRIPT_DIR/hooks/check-completion.sh" "$skill_dir/hooks/check-completion.sh"
  safe_copy "$SCRIPT_DIR/hooks/inject-continue-codex.sh" "$skill_dir/hooks/inject-continue-codex.sh"
  safe_copy "$SCRIPT_DIR/hooks/run-codex-expect-bridge.exp" "$skill_dir/hooks/run-codex-expect-bridge.exp"

  chmod +x "$skill_dir/install.sh"
  chmod +x "$skill_dir/uninstall.sh"
  chmod +x "$skill_dir/taskmaster-compliance-prompt.sh"
  chmod +x "$skill_dir/taskmaster-verify-command.sh"
  chmod +x "$skill_dir/taskmaster-prompt-detect.sh"
  chmod +x "$skill_dir/taskmaster-state.sh"
  chmod +x "$skill_dir/run-taskmaster-codex.sh"
  chmod +x "$skill_dir/check-completion.sh"
  chmod +x "$skill_dir/hooks/check-completion.sh"
  chmod +x "$skill_dir/hooks/inject-continue-codex.sh"
  chmod +x "$skill_dir/hooks/run-codex-expect-bridge.exp"
}

codex_detected() {
  command -v codex >/dev/null 2>&1 || [[ -d "$CODEX_ROOT" ]]
}

claude_detected() {
  command -v claude >/dev/null 2>&1 || [[ -d "$CLAUDE_ROOT" ]]
}

ensure_claude_stop_hook() {
  local settings_path="$1"
  local hook_command="$2"

  if ! command -v python3 >/dev/null 2>&1; then
    echo "  Claude: python3 not found; add Stop hook manually -> $hook_command" >&2
    return 0
  fi

  python3 - "$settings_path" "$hook_command" <<'PY'
import json
import os
import sys

settings_path = sys.argv[1]
hook_command = sys.argv[2]

if os.path.exists(settings_path):
    try:
        with open(settings_path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except json.JSONDecodeError:
        print(f"  Claude: settings is not valid JSON ({settings_path}); add Stop hook manually.", file=sys.stderr)
        sys.exit(0)
else:
    data = {}

if not isinstance(data, dict):
    print(f"  Claude: settings root is not an object ({settings_path}); add Stop hook manually.", file=sys.stderr)
    sys.exit(0)

container = None
if isinstance(data.get("hooks"), dict):
    container = data["hooks"]
else:
    container = data

stop_hooks = container.get("Stop")
if not isinstance(stop_hooks, list):
    stop_hooks = []
    container["Stop"] = stop_hooks

# Migrate stale entries pointing at the old in-skill hook path
# (~/.claude/skills/taskmaster/hooks/check-completion.sh) to the
# user-level $HOME/.claude/hooks/ path. Idempotent.
migrated = 0
stale_marker = "skills/taskmaster/hooks/check-completion.sh"
for entry in stop_hooks:
    if not isinstance(entry, dict):
        continue
    hooks = entry.get("hooks")
    if not isinstance(hooks, list):
        continue
    for hook in hooks:
        if not isinstance(hook, dict):
            continue
        cmd = hook.get("command")
        if hook.get("type") == "command" and isinstance(cmd, str) and stale_marker in cmd:
            hook["command"] = hook_command
            migrated += 1

exists = False
for entry in stop_hooks:
    if not isinstance(entry, dict):
        continue
    hooks = entry.get("hooks")
    if not isinstance(hooks, list):
        continue
    for hook in hooks:
        if not isinstance(hook, dict):
            continue
        if hook.get("type") == "command" and hook.get("command") == hook_command:
            exists = True
            break
    if exists:
        break

if not exists:
    stop_hooks.append(
        {
            "matcher": "*",
            "hooks": [
                {
                    "type": "command",
                    "command": hook_command,
                }
            ],
        }
    )

os.makedirs(os.path.dirname(settings_path), exist_ok=True)
with open(settings_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")

if migrated:
    print(f"  Claude: migrated {migrated} stale Stop hook entr{'y' if migrated == 1 else 'ies'} to {hook_command}")

if exists:
    if not migrated:
        print("  Claude: Stop hook already configured")
else:
    print("  Claude: added Stop hook to settings")
PY
}

ensure_superset_codex_prefers_taskmaster() {
  local wrapper_path="$1"

  if [[ ! -f "$wrapper_path" ]]; then
    return 0
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    echo "  Codex: python3 not found; update $wrapper_path manually to prefer codex-taskmaster" >&2
    return 0
  fi

  python3 - "$wrapper_path" <<'PY'
from pathlib import Path
import sys

wrapper_path = Path(sys.argv[1]).expanduser()
text = wrapper_path.read_text(encoding="utf-8")

if "find_taskmaster_or_real_binary()" in text:
    print("  Codex: Superset wrapper already prefers codex-taskmaster")
    raise SystemExit(0)

needle = 'REAL_BIN="$(find_real_binary "codex")"'
if needle not in text:
    print(f"  Codex: Superset wrapper format not recognized; skipped {wrapper_path}", file=sys.stderr)
    raise SystemExit(0)

replacement = """find_taskmaster_or_real_binary() {
  local taskmaster_bin=""
  taskmaster_bin="$(find_real_binary "codex-taskmaster" || true)"
  if [ -n "$taskmaster_bin" ]; then
    printf "%s\\n" "$taskmaster_bin"
    return 0
  fi

  find_real_binary "codex"
}

REAL_BIN="$(find_taskmaster_or_real_binary)" """

text = text.replace(needle, replacement, 1)
text = text.replace(
    "Superset: codex not found in PATH. Install it and ensure it is on PATH, then retry.",
    "Superset: codex or codex-taskmaster not found in PATH. Install it and ensure it is on PATH, then retry.",
)
wrapper_path.write_text(text, encoding="utf-8")
print("  Codex: updated Superset wrapper to prefer codex-taskmaster")
PY
}

install_codex() {
  copy_skill_files "$CODEX_SKILL_DIR"

  mkdir -p "$CODEX_BIN_DIR"
  ln -sf "$CODEX_SKILL_DIR/run-taskmaster-codex.sh" "$CODEX_LAUNCHER_LINK"
  ln -sf "$CODEX_SKILL_DIR/run-taskmaster-codex.sh" "$CODEX_SHIM_LINK"

  echo "  Codex: installed skill files to $CODEX_SKILL_DIR"
  echo "  Codex: linked launcher at $CODEX_LAUNCHER_LINK"
  echo "  Codex: linked shim at $CODEX_SHIM_LINK"
  ensure_superset_codex_prefers_taskmaster "$SUPERSET_CODEX_WRAPPER"
}

install_claude() {
  copy_skill_files "$CLAUDE_SKILL_DIR"

  mkdir -p "$CLAUDE_HOOKS_DIR"
  ln -sf "$CLAUDE_SKILL_DIR/check-completion.sh" "$CLAUDE_HOOK_LINK"
  ln -sf "$CLAUDE_SKILL_DIR/taskmaster-compliance-prompt.sh" "$CLAUDE_HOOKS_DIR/taskmaster-compliance-prompt.sh"
  ln -sf "$CLAUDE_SKILL_DIR/taskmaster-verify-command.sh" "$CLAUDE_HOOKS_DIR/taskmaster-verify-command.sh"
  ln -sf "$CLAUDE_SKILL_DIR/taskmaster-prompt-detect.sh" "$CLAUDE_HOOKS_DIR/taskmaster-prompt-detect.sh"
  ln -sf "$CLAUDE_SKILL_DIR/taskmaster-state.sh" "$CLAUDE_HOOKS_DIR/taskmaster-state.sh"
  chmod +x "$CLAUDE_HOOK_LINK"

  echo "  Claude: installed skill files to $CLAUDE_SKILL_DIR"
  echo "  Claude: linked Stop hook at $CLAUDE_HOOK_LINK"
  ensure_claude_stop_hook "$CLAUDE_SETTINGS_PATH" "$CLAUDE_HOOK_COMMAND"
}

INSTALL_TARGET="${TASKMASTER_INSTALL_TARGET:-auto}"
INSTALL_CODEX=0
INSTALL_CLAUDE=0

case "$INSTALL_TARGET" in
  auto)
    if codex_detected; then
      INSTALL_CODEX=1
    fi
    if claude_detected; then
      INSTALL_CLAUDE=1
    fi
    if [[ "$INSTALL_CODEX" -eq 0 && "$INSTALL_CLAUDE" -eq 0 ]]; then
      INSTALL_CODEX=1
      INSTALL_CLAUDE=1
      echo "No Codex/Claude install detected; defaulting to both targets."
    fi
    ;;
  codex)
    INSTALL_CODEX=1
    ;;
  claude)
    INSTALL_CLAUDE=1
    ;;
  both)
    INSTALL_CODEX=1
    INSTALL_CLAUDE=1
    ;;
  *)
    echo "Invalid TASKMASTER_INSTALL_TARGET='$INSTALL_TARGET' (expected: auto|codex|claude|both)" >&2
    exit 4
    ;;
esac

echo "Installing Taskmaster..."

if [[ "$INSTALL_CODEX" -eq 1 ]]; then
  install_codex
fi

if [[ "$INSTALL_CLAUDE" -eq 1 ]]; then
  install_claude
fi

echo ""
echo "Done."

if [[ "$INSTALL_CODEX" -eq 1 ]]; then
  echo ""
  echo "Codex usage:"
  echo "  codex [codex args]"
fi

if [[ "$INSTALL_CLAUDE" -eq 1 ]]; then
  echo ""
  echo "Claude usage:"
  echo "  Claude Stop hook is configured at $CLAUDE_HOOK_COMMAND"
fi
