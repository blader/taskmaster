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

CODEX_CONFIG_PATH="$CODEX_ROOT/config.toml"
CODEX_HOOKS_PATH="$CODEX_ROOT/hooks.json"
CODEX_BIN_DIR="$CODEX_ROOT/bin"
CODEX_LAUNCHER_LINK="$CODEX_BIN_DIR/codex-taskmaster"
CODEX_SHIM_LINK="$CODEX_BIN_DIR/codex"
CODEX_RUNNER_PATH="$CODEX_SKILL_DIR/run-taskmaster-codex.sh"
CODEX_SESSION_START_HOOK_COMMAND="~/.codex/skills/taskmaster/hooks/taskmaster-session-start.sh"
CODEX_USER_PROMPT_SUBMIT_HOOK_COMMAND="~/.codex/skills/taskmaster/hooks/taskmaster-user-prompt-submit.sh"
CODEX_STOP_HOOK_COMMAND="~/.codex/skills/taskmaster/hooks/taskmaster-stop.sh"

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
  safe_copy "$SCRIPT_DIR/taskmaster-state.sh" "$skill_dir/taskmaster-state.sh"

  safe_copy "$SCRIPT_DIR/check-completion.sh" "$skill_dir/check-completion.sh"
  safe_copy "$SCRIPT_DIR/hooks/taskmaster-session-start.sh" "$skill_dir/hooks/taskmaster-session-start.sh"
  safe_copy "$SCRIPT_DIR/hooks/taskmaster-user-prompt-submit.sh" "$skill_dir/hooks/taskmaster-user-prompt-submit.sh"
  safe_copy "$SCRIPT_DIR/hooks/taskmaster-stop.sh" "$skill_dir/hooks/taskmaster-stop.sh"

  chmod +x "$skill_dir/install.sh"
  chmod +x "$skill_dir/uninstall.sh"
  chmod +x "$skill_dir/taskmaster-compliance-prompt.sh"
  chmod +x "$skill_dir/taskmaster-state.sh"
  chmod +x "$skill_dir/check-completion.sh"
  chmod +x "$skill_dir/hooks/taskmaster-session-start.sh"
  chmod +x "$skill_dir/hooks/taskmaster-user-prompt-submit.sh"
  chmod +x "$skill_dir/hooks/taskmaster-stop.sh"
}

codex_detected() {
  command -v codex >/dev/null 2>&1 || [[ -d "$CODEX_ROOT" ]]
}

claude_detected() {
  command -v claude >/dev/null 2>&1 || [[ -d "$CLAUDE_ROOT" ]]
}

resolve_link_target() {
  local link_path="$1"
  local raw_target
  local target_dir

  raw_target="$(readlink "$link_path")"
  if [[ "$raw_target" == /* ]]; then
    printf '%s\n' "$raw_target"
    return 0
  fi

  target_dir="$(cd "$(dirname "$link_path")" && cd "$(dirname "$raw_target")" && pwd)"
  printf '%s/%s\n' "$target_dir" "$(basename "$raw_target")"
}

remove_symlink_if_target() {
  local link_path="$1"
  shift
  local expected_targets=("$@")
  local resolved_target
  local expected

  [[ -L "$link_path" ]] || return 0

  resolved_target="$(resolve_link_target "$link_path")"
  for expected in "${expected_targets[@]}"; do
    if [[ "$resolved_target" == "$expected" ]]; then
      rm -f "$link_path"
      echo "  Codex: removed legacy wrapper link at $link_path"
      return 0
    fi
  done
}

require_python3() {
  local target="$1"

  if ! command -v python3 >/dev/null 2>&1; then
    echo "  ${target}: python3 is required for config updates" >&2
    exit 1
  fi
}

ensure_codex_feature_flag() {
  local config_path="$1"

  python3 - "$config_path" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1]).expanduser()
path.parent.mkdir(parents=True, exist_ok=True)
text = path.read_text(encoding="utf-8") if path.exists() else ""
lines = text.splitlines()

section_idx = None
section_end = len(lines)
for idx, line in enumerate(lines):
    if re.match(r"^\s*\[features\]\s*$", line):
        section_idx = idx
        for next_idx in range(idx + 1, len(lines)):
            if re.match(r"^\s*\[.*\]\s*$", lines[next_idx]):
                section_end = next_idx
                break
        break

updated = False
if section_idx is None:
    if lines and lines[-1] != "":
        lines.append("")
    lines.extend(["[features]", "codex_hooks = true"])
    updated = True
else:
    key_idx = None
    for idx in range(section_idx + 1, section_end):
        if re.match(r"^\s*codex_hooks\s*=", lines[idx]):
            key_idx = idx
            break
    if key_idx is None:
        lines.insert(section_end, "codex_hooks = true")
        updated = True
    elif lines[key_idx].strip() != "codex_hooks = true":
        lines[key_idx] = "codex_hooks = true"
        updated = True

output = "\n".join(lines).rstrip() + "\n"
path.write_text(output, encoding="utf-8")
print("updated" if updated else "unchanged")
PY
}

ensure_codex_hooks_file() {
  local hooks_path="$1"
  local session_start_command="$2"
  local user_prompt_submit_command="$3"
  local stop_command="$4"

  python3 - "$hooks_path" "$session_start_command" "$user_prompt_submit_command" "$stop_command" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1]).expanduser()
session_start_command = sys.argv[2]
user_prompt_submit_command = sys.argv[3]
stop_command = sys.argv[4]
path.parent.mkdir(parents=True, exist_ok=True)

if path.exists():
    data = json.loads(path.read_text(encoding="utf-8"))
else:
    data = {}

if not isinstance(data, dict):
    raise SystemExit("Codex hooks file must contain a JSON object")

hooks = data.get("hooks")
if not isinstance(hooks, dict):
    hooks = {}
    data["hooks"] = hooks

taskmaster_commands = {session_start_command, user_prompt_submit_command, stop_command}


def strip_taskmaster_entries(entries):
    cleaned = []
    for entry in entries if isinstance(entries, list) else []:
        if not isinstance(entry, dict):
            cleaned.append(entry)
            continue
        entry_hooks = entry.get("hooks")
        if not isinstance(entry_hooks, list):
            cleaned.append(entry)
            continue
        kept_hooks = [
            hook
            for hook in entry_hooks
            if not (
                isinstance(hook, dict)
                and hook.get("type") == "command"
                and hook.get("command") in taskmaster_commands
            )
        ]
        if kept_hooks:
            entry_copy = dict(entry)
            entry_copy["hooks"] = kept_hooks
            cleaned.append(entry_copy)
    return cleaned


hooks["SessionStart"] = strip_taskmaster_entries(hooks.get("SessionStart"))
hooks["UserPromptSubmit"] = strip_taskmaster_entries(hooks.get("UserPromptSubmit"))
hooks["Stop"] = strip_taskmaster_entries(hooks.get("Stop"))

hooks["SessionStart"].append(
    {
        "matcher": "^(startup|resume|clear)$",
        "hooks": [
            {
                "type": "command",
                "command": session_start_command,
                "statusMessage": "Loading completion contract...",
                "timeout": 10,
            }
        ],
    }
)
hooks["Stop"].append(
    {
        "hooks": [
            {
                "type": "command",
                "command": stop_command,
                "statusMessage": "Checking completion...",
                "timeout": 30,
            }
        ],
    }
)
hooks["UserPromptSubmit"].append(
    {
        "hooks": [
            {
                "type": "command",
                "command": user_prompt_submit_command,
                "statusMessage": "Capturing task prompt...",
                "timeout": 15,
            }
        ],
    }
)

path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
print("updated")
PY
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

if exists:
    print("  Claude: Stop hook already configured")
else:
    print("  Claude: added Stop hook to settings")
PY
}

install_codex() {
  require_python3 "Codex"
  copy_skill_files "$CODEX_SKILL_DIR"

  ensure_codex_feature_flag "$CODEX_CONFIG_PATH" >/dev/null
  ensure_codex_hooks_file "$CODEX_HOOKS_PATH" "$CODEX_SESSION_START_HOOK_COMMAND" "$CODEX_USER_PROMPT_SUBMIT_HOOK_COMMAND" "$CODEX_STOP_HOOK_COMMAND" >/dev/null
  mkdir -p "$CODEX_BIN_DIR"
  remove_symlink_if_target "$CODEX_SHIM_LINK" "$CODEX_LAUNCHER_LINK" "$CODEX_RUNNER_PATH"
  remove_symlink_if_target "$CODEX_LAUNCHER_LINK" "$CODEX_RUNNER_PATH"

  echo "  Codex: installed skill files to $CODEX_SKILL_DIR"
  echo "  Codex: enabled native hooks in $CODEX_CONFIG_PATH"
  echo "  Codex: configured hooks in $CODEX_HOOKS_PATH"
}

install_claude() {
  copy_skill_files "$CLAUDE_SKILL_DIR"

  mkdir -p "$CLAUDE_HOOKS_DIR"
  ln -sf "$CLAUDE_SKILL_DIR/check-completion.sh" "$CLAUDE_HOOK_LINK"
  ln -sf "$CLAUDE_SKILL_DIR/taskmaster-compliance-prompt.sh" "$CLAUDE_HOOKS_DIR/taskmaster-compliance-prompt.sh"
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
