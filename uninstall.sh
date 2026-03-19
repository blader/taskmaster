#!/usr/bin/env bash
#
# Taskmaster uninstaller for Codex and Claude.
#
set -euo pipefail

CODEX_ROOT="$HOME/.codex"
CLAUDE_ROOT="$HOME/.claude"

CODEX_SKILL_DIR="$CODEX_ROOT/skills/taskmaster"
CLAUDE_SKILL_DIR="$CLAUDE_ROOT/skills/taskmaster"

CODEX_CONFIG_PATH="$CODEX_ROOT/config.toml"
CODEX_HOOKS_PATH="$CODEX_ROOT/hooks.json"
CODEX_LAUNCHER_LINK="$CODEX_ROOT/bin/codex-taskmaster"
CODEX_SHIM_LINK="$CODEX_ROOT/bin/codex"
CODEX_RUNNER_PATH="$CODEX_SKILL_DIR/run-taskmaster-codex.sh"
CODEX_SESSION_START_HOOK_COMMAND="~/.codex/skills/taskmaster/hooks/taskmaster-session-start.sh"
CODEX_STOP_HOOK_COMMAND="~/.codex/skills/taskmaster/hooks/taskmaster-stop.sh"

CLAUDE_HOOK_LINK="$CLAUDE_ROOT/hooks/taskmaster-check-completion.sh"
CLAUDE_CHECK_SCRIPT="$CLAUDE_SKILL_DIR/check-completion.sh"
CLAUDE_SETTINGS_PATH="$CLAUDE_ROOT/settings.json"

codex_detected() {
  command -v codex >/dev/null 2>&1 || [[ -d "$CODEX_ROOT" ]]
}

claude_detected() {
  command -v claude >/dev/null 2>&1 || [[ -d "$CLAUDE_ROOT" ]]
}

codex_artifacts_detected() {
  [[ -e "$CODEX_SKILL_DIR" || -L "$CODEX_LAUNCHER_LINK" || -L "$CODEX_SHIM_LINK" ]]
}

claude_artifacts_detected() {
  [[ -e "$CLAUDE_SKILL_DIR" || -L "$CLAUDE_HOOK_LINK" || -f "$CLAUDE_SETTINGS_PATH" ]]
}

require_python3() {
  local target="$1"

  if ! command -v python3 >/dev/null 2>&1; then
    echo "  ${target}: python3 is required for config updates" >&2
    exit 1
  fi
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

  if [[ ! -L "$link_path" ]]; then
    if [[ -e "$link_path" ]]; then
      echo "  Skipped $link_path (not a symlink)"
    else
      echo "  Link not found (already removed): $link_path"
    fi
    return 0
  fi

  resolved_target="$(resolve_link_target "$link_path")"
  for expected in "${expected_targets[@]}"; do
    if [[ "$resolved_target" == "$expected" ]]; then
      rm -f "$link_path"
      echo "  Removed $link_path"
      return 0
    fi
  done

  echo "  Skipped $link_path (not a Taskmaster link -> $resolved_target)"
}

remove_dir_if_exists() {
  local dir_path="$1"
  if [[ -d "$dir_path" ]]; then
    rm -rf "$dir_path"
    echo "  Removed $dir_path"
  else
    echo "  Directory not found (already removed): $dir_path"
  fi
}

remove_codex_feature_flag() {
  local config_path="$1"

  [[ -f "$config_path" ]] || return 0

  python3 - "$config_path" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1]).expanduser()
lines = path.read_text(encoding="utf-8").splitlines()

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

if section_idx is not None:
    filtered_section = []
    removed = False
    for idx in range(section_idx + 1, section_end):
        if re.match(r"^\s*codex_hooks\s*=", lines[idx]):
            removed = True
            continue
        filtered_section.append(lines[idx])
    if removed:
        keep_section = any(line.strip() and not line.lstrip().startswith("#") for line in filtered_section)
        prefix = lines[:section_idx]
        suffix = lines[section_end:]
        if keep_section:
            lines = prefix + [lines[section_idx]] + filtered_section + suffix
        else:
            lines = prefix + suffix

output = "\n".join(lines).strip()
if output:
    path.write_text(output + "\n", encoding="utf-8")
else:
    path.write_text("", encoding="utf-8")
PY
}

remove_codex_hooks() {
  local hooks_path="$1"
  local session_start_command="$2"
  local stop_command="$3"

  [[ -f "$hooks_path" ]] || return 0

  python3 - "$hooks_path" "$session_start_command" "$stop_command" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1]).expanduser()
session_start_command = sys.argv[2]
stop_command = sys.argv[3]
data = json.loads(path.read_text(encoding="utf-8"))

if not isinstance(data, dict):
    raise SystemExit("Codex hooks file must contain a JSON object")

hooks = data.get("hooks")
if not isinstance(hooks, dict):
    raise SystemExit(0)

taskmaster_commands = {session_start_command, stop_command}


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


for key in ("SessionStart", "Stop"):
    cleaned = strip_taskmaster_entries(hooks.get(key))
    if cleaned:
        hooks[key] = cleaned
    elif key in hooks:
        del hooks[key]

if not hooks and "hooks" in data:
    del data["hooks"]

path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
}

remove_claude_stop_hook_from_settings() {
  local settings_path="$1"

  if [[ ! -f "$settings_path" ]]; then
    echo "  Claude: settings not found (already removed): $settings_path"
    return 0
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    echo "  Claude: python3 not found; remove Stop hook manually from $settings_path" >&2
    return 0
  fi

  python3 - "$settings_path" <<'PY'
import json
import os
import sys

settings_path = sys.argv[1]

hook_commands = {
    "~/.claude/hooks/taskmaster-check-completion.sh",
    os.path.expanduser("~/.claude/hooks/taskmaster-check-completion.sh"),
    "~/.claude/skills/taskmaster/check-completion.sh",
    os.path.expanduser("~/.claude/skills/taskmaster/check-completion.sh"),
}

try:
    with open(settings_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except json.JSONDecodeError:
    print(f"  Claude: settings is not valid JSON ({settings_path}); remove Stop hook manually.", file=sys.stderr)
    sys.exit(0)

if not isinstance(data, dict):
    print(f"  Claude: settings root is not an object ({settings_path}); remove Stop hook manually.", file=sys.stderr)
    sys.exit(0)

changed = False


def strip_stop_hooks(container):
    global changed

    stop_list = container.get("Stop")
    if not isinstance(stop_list, list):
        return

    new_stop = []
    for entry in stop_list:
        if not isinstance(entry, dict):
            new_stop.append(entry)
            continue

        hooks = entry.get("hooks")
        if not isinstance(hooks, list):
            new_stop.append(entry)
            continue

        kept_hooks = []
        for hook in hooks:
            if (
                isinstance(hook, dict)
                and hook.get("type") == "command"
                and isinstance(hook.get("command"), str)
                and hook.get("command") in hook_commands
            ):
                changed = True
                continue
            kept_hooks.append(hook)

        if kept_hooks:
            entry_copy = dict(entry)
            entry_copy["hooks"] = kept_hooks
            new_stop.append(entry_copy)
        else:
            changed = True

    if new_stop:
        container["Stop"] = new_stop
    elif "Stop" in container:
        del container["Stop"]
        changed = True


if isinstance(data.get("hooks"), dict):
    strip_stop_hooks(data["hooks"])
    if not data["hooks"]:
        del data["hooks"]
        changed = True

strip_stop_hooks(data)

if changed:
    with open(settings_path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    print("  Claude: removed Taskmaster Stop hook from settings")
else:
    print("  Claude: Taskmaster Stop hook not found in settings")
PY
}

uninstall_codex() {
  require_python3 "Codex"
  echo "Removing Taskmaster from Codex..."
  remove_codex_feature_flag "$CODEX_CONFIG_PATH"
  remove_codex_hooks "$CODEX_HOOKS_PATH" "$CODEX_SESSION_START_HOOK_COMMAND" "$CODEX_STOP_HOOK_COMMAND"
  remove_symlink_if_target "$CODEX_SHIM_LINK" "$CODEX_LAUNCHER_LINK" "$CODEX_RUNNER_PATH"
  remove_symlink_if_target "$CODEX_LAUNCHER_LINK" "$CODEX_RUNNER_PATH"
  remove_dir_if_exists "$CODEX_SKILL_DIR"
}

uninstall_claude() {
  echo "Removing Taskmaster from Claude..."
  remove_claude_stop_hook_from_settings "$CLAUDE_SETTINGS_PATH"
  remove_symlink_if_target "$CLAUDE_HOOK_LINK" "$CLAUDE_CHECK_SCRIPT"
  remove_dir_if_exists "$CLAUDE_SKILL_DIR"
}

UNINSTALL_TARGET="${TASKMASTER_UNINSTALL_TARGET:-auto}"
UNINSTALL_CODEX=0
UNINSTALL_CLAUDE=0

case "$UNINSTALL_TARGET" in
  auto)
    if codex_artifacts_detected || codex_detected; then
      UNINSTALL_CODEX=1
    fi
    if claude_artifacts_detected || claude_detected; then
      UNINSTALL_CLAUDE=1
    fi
    ;;
  codex)
    UNINSTALL_CODEX=1
    ;;
  claude)
    UNINSTALL_CLAUDE=1
    ;;
  both)
    UNINSTALL_CODEX=1
    UNINSTALL_CLAUDE=1
    ;;
  *)
    echo "Invalid TASKMASTER_UNINSTALL_TARGET='$UNINSTALL_TARGET' (expected: auto|codex|claude|both)" >&2
    exit 4
    ;;
esac

if [[ "$UNINSTALL_CODEX" -eq 0 && "$UNINSTALL_CLAUDE" -eq 0 ]]; then
  echo "No Codex/Claude environment detected. Nothing to uninstall."
  exit 0
fi

if [[ "$UNINSTALL_CODEX" -eq 1 ]]; then
  uninstall_codex
fi

if [[ "$UNINSTALL_CLAUDE" -eq 1 ]]; then
  uninstall_claude
fi

echo ""
echo "Done. Taskmaster uninstall complete."
