#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common-macos.sh
source "$SCRIPT_DIR/common-macos.sh"

verify_macos
APP_DIR="${CODEX_CONTEXT_METER_APP_DIR:-$HOME/Applications/$APP_NAME}"
LAUNCH_AGENT_DIR="${CODEX_CONTEXT_METER_LAUNCH_AGENT_DIR:-$HOME/Library/LaunchAgents}"
SUPPORT_DIR="${CODEX_CONTEXT_METER_SUPPORT_DIR:-$HOME/Library/Application Support/Codex Context Meter}"
LAUNCH_AGENT="$LAUNCH_AGENT_DIR/$APP_IDENTIFIER.plist"

if [[ "${CODEX_CONTEXT_METER_SKIP_LAUNCHCTL:-0}" != "1" ]]; then
  /bin/launchctl bootout "gui/$UID/$APP_IDENTIFIER" 2>/dev/null || true
fi
/usr/bin/pkill -f "$APP_DIR/Contents/MacOS/$APP_EXECUTABLE" 2>/dev/null || true

for target in "$LAUNCH_AGENT" "$APP_DIR" "$SUPPORT_DIR"; do
  case "$target" in
    "$HOME/Applications/"*|"$HOME/Library/LaunchAgents/"*|"$HOME/Library/Application Support/"*|/tmp/*|/private/tmp/*)
      if [[ -e "$target" ]]; then
        rm -rf "$target"
        printf '已移除：%s\n' "$target"
      else
        printf '不存在：%s\n' "$target"
      fi
      ;;
    *) die "拒绝删除非预期路径：$target" ;;
  esac
done
printf '卸载完成；Codex 对话和数据库未被修改。\n'
