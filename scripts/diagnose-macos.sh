#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common-macos.sh
source "$SCRIPT_DIR/common-macos.sh"

APP_DIR="${CODEX_CONTEXT_METER_APP_DIR:-$HOME/Applications/$APP_NAME}"
LAUNCH_AGENT_DIR="${CODEX_CONTEXT_METER_LAUNCH_AGENT_DIR:-$HOME/Library/LaunchAgents}"
SUPPORT_DIR="${CODEX_CONTEXT_METER_SUPPORT_DIR:-$HOME/Library/Application Support/Codex Context Meter}"
INSTALL_MANIFEST="$SUPPORT_DIR/install.json"
if [[ -z "${CODEX_CONTEXT_METER_APP_DIR:-}" && -f "$INSTALL_MANIFEST" ]]; then
  recorded_app_dir="$(/usr/bin/plutil -extract appPath raw -o - "$INSTALL_MANIFEST" 2>/dev/null || true)"
  if [[ -n "$recorded_app_dir" ]]; then
    APP_DIR="$recorded_app_dir"
  fi
fi
LAUNCH_AGENT="$LAUNCH_AGENT_DIR/$APP_IDENTIFIER.plist"
failures=0

check() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf '通过：%s\n' "$label"
  else
    printf '失败：%s\n' "$label"
    failures=$((failures + 1))
  fi
}

verify_macos
printf '系统：macOS %s (%s)\n' "$(sw_vers -productVersion)" "$(uname -m)"
check "应用存在" test -x "$APP_DIR/Contents/MacOS/$APP_EXECUTABLE"
check "应用签名结构有效" /usr/bin/codesign --verify --deep --strict "$APP_DIR"
check "登录启动配置存在" test -f "$LAUNCH_AGENT"
check "登录启动配置语法有效" /usr/bin/plutil -lint "$LAUNCH_AGENT"
check "应用进程正在运行" /usr/bin/pgrep -f "$APP_DIR/Contents/MacOS/$APP_EXECUTABLE"
check "Codex 会话索引可读" test -r "${CODEX_HOME:-$HOME/.codex}/session_index.jsonl"

if /usr/bin/codesign -d --entitlements :- "$APP_DIR" 2>&1 | /usr/bin/grep -q 'com.apple.security'; then
  printf '信息：检测到签名权限声明。\n'
fi
if /usr/bin/osascript -l JavaScript -e 'ObjC.import("ApplicationServices"); $.AXIsProcessTrusted() ? "true" : "false"' 2>/dev/null | /usr/bin/grep -q true; then
  printf '通过：当前诊断进程具有辅助功能权限（应用权限仍以系统设置列表为准）\n'
else
  printf '待用户确认：请在系统设置的“辅助功能”中启用 Codex 上下文仪表。\n'
fi

if [[ "$failures" -gt 0 ]]; then
  printf '诊断完成：%d 项失败。\n' "$failures" >&2
  exit 1
fi
printf '诊断完成：基础安装、启动项和进程检查均通过。\n'
