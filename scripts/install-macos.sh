#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common-macos.sh
source "$SCRIPT_DIR/common-macos.sh"

APP_DIR="${CODEX_CONTEXT_METER_APP_DIR:-$HOME/Applications/$APP_NAME}"
LAUNCH_AGENT_DIR="${CODEX_CONTEXT_METER_LAUNCH_AGENT_DIR:-$HOME/Library/LaunchAgents}"
SUPPORT_DIR="${CODEX_CONTEXT_METER_SUPPORT_DIR:-$HOME/Library/Application Support/Codex Context Meter}"
START_APP=true
ALLOW_LOCAL=false
FORCE_FALLBACK=false

if [[ "${CODEX_CONTEXT_METER_NO_START:-0}" == "1" ]]; then
  START_APP=false
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-start) START_APP=false ;;
    --allow-local-source) ALLOW_LOCAL=true ;;
    --force-fallback) FORCE_FALLBACK=true ;;
    *) die "未知参数：$1" ;;
  esac
  shift
done

if [[ -z "${CODEX_CONTEXT_METER_APP_DIR:-}" && -f "$SUPPORT_DIR/install.json" ]]; then
  recorded_app_dir="$(/usr/bin/plutil -extract appPath raw -o - "$SUPPORT_DIR/install.json" 2>/dev/null || true)"
  case "$recorded_app_dir" in
    "$HOME/Applications/"*.app) APP_DIR="$recorded_app_dir" ;;
    "") ;;
    *) die "安装清单中的应用路径不受支持：$recorded_app_dir" ;;
  esac
fi

verify_macos
verify_source_origin "$ALLOW_LOCAL"
verify_asset_hashes

if [[ -z "${CODEX_CONTEXT_METER_APP_DIR:-}" && -e "$APP_DIR" && ! -w "$APP_DIR" ]]; then
  APP_DIR="$HOME/Applications/Codex 上下文仪表（Skill）.app"
  printf '现有应用由其他用户拥有，将安装到可写路径：%s\n' "$APP_DIR"
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-context-meter.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
BUILT_APP="$WORK_DIR/$APP_NAME"
CONTENTS="$BUILT_APP/Contents"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

build_from_source() {
  command -v swiftc >/dev/null 2>&1 || return 1
  swiftc \
    "$SKILL_DIR/assets/macos/CodexContextMeter.swift" \
    -framework AppKit \
    -framework ApplicationServices \
    -framework SwiftUI \
    -framework UserNotifications \
    -o "$CONTENTS/MacOS/$APP_EXECUTABLE"
  cp "$SKILL_DIR/assets/macos/CodexContextMeter-Info.plist" "$CONTENTS/Info.plist"
  cp "$SKILL_DIR/assets/macos/WhaleContextIcon.png" "$CONTENTS/Resources/WhaleContextIcon.png"
}

install_fallback() {
  local architecture archive url expected actual
  architecture="$(uname -m)"
  case "$architecture" in
    arm64)
      archive="$WORK_DIR/CodexContextMeter-macOS-arm64.tar.gz"
      url="https://github.com/sunlulu0122-alt/codex-context-meter-skill/releases/download/v1.4.1/CodexContextMeter-macOS-arm64.tar.gz"
      expected="7960ed34577e5ba2f6ef87779a1e63c3e36d85adf169470378501418bf4b3925"
      ;;
    *)
      die "未找到 $architecture 的已校验回退包；请安装 Xcode Command Line Tools 后重试源码构建。"
      ;;
  esac
  /usr/bin/curl --fail --location --proto '=https' --tlsv1.2 "$url" --output "$archive"
  actual="$(/usr/bin/shasum -a 256 "$archive" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || die "回退包 SHA-256 不匹配。"
  rm -rf "$BUILT_APP"
  mkdir -p "$WORK_DIR/fallback"
  /usr/bin/tar -xzf "$archive" -C "$WORK_DIR/fallback"
  [[ -x "$WORK_DIR/fallback/$APP_NAME/Contents/MacOS/$APP_EXECUTABLE" ]] || die "回退包结构无效。"
  mv "$WORK_DIR/fallback/$APP_NAME" "$BUILT_APP"
}

if [[ "$FORCE_FALLBACK" == "true" ]] || ! build_from_source; then
  printf '本机 Swift 构建不可用，使用固定版本 SHA-256 校验回退包。\n'
  install_fallback
else
  printf '已从已校验源码完成本机构建。\n'
fi

chmod +x "$CONTENTS/MacOS/$APP_EXECUTABLE"
/usr/bin/codesign \
  --force \
  --deep \
  --sign - \
  --identifier "$APP_IDENTIFIER" \
  --requirements "$SKILL_DIR/assets/macos/CodexContextMeter.requirements" \
  "$BUILT_APP"
/usr/bin/codesign --verify --deep --strict "$BUILT_APP"

mkdir -p "$(dirname "$APP_DIR")" "$LAUNCH_AGENT_DIR" "$SUPPORT_DIR"
if [[ -e "$APP_DIR" ]]; then
  /bin/launchctl bootout "gui/$UID/$APP_IDENTIFIER" 2>/dev/null || true
  /usr/bin/pkill -f "$APP_DIR/Contents/MacOS/$APP_EXECUTABLE" 2>/dev/null || true
  for _ in 1 2 3 4 5; do
    if ! /usr/bin/pgrep -f "$APP_DIR/Contents/MacOS/$APP_EXECUTABLE" >/dev/null; then
      break
    fi
    sleep 1
  done
  /usr/bin/pgrep -f "$APP_DIR/Contents/MacOS/$APP_EXECUTABLE" >/dev/null \
    && die "旧应用进程未能停止，已取消替换。"
  mv "$APP_DIR" "$WORK_DIR/previous.app"
fi
/usr/bin/ditto "$BUILT_APP" "$APP_DIR"

LAUNCH_AGENT="$LAUNCH_AGENT_DIR/$APP_IDENTIFIER.plist"
cat > "$WORK_DIR/launch-agent.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$APP_IDENTIFIER</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string>
    <string>$APP_DIR</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
PLIST
/usr/bin/plutil -lint "$WORK_DIR/launch-agent.plist" >/dev/null
cp "$WORK_DIR/launch-agent.plist" "$LAUNCH_AGENT"

cat > "$WORK_DIR/install.json" <<JSON
{"version":"1.4.1","appPath":"$APP_DIR","source":"$EXPECTED_REPOSITORY"}
JSON
cp "$WORK_DIR/install.json" "$SUPPORT_DIR/install.json"

if [[ "$START_APP" == "true" ]]; then
  /bin/launchctl bootout "gui/$UID/$APP_IDENTIFIER" 2>/dev/null || true
  /bin/launchctl bootstrap "gui/$UID" "$LAUNCH_AGENT"
  /usr/bin/open "$APP_DIR"
  sleep 2
  /usr/bin/pgrep -f "$APP_DIR/Contents/MacOS/$APP_EXECUTABLE" >/dev/null \
    || die "应用文件已安装，但进程验证失败。"
fi

printf '安装完成：%s\n' "$APP_DIR"
printf '登录启动：%s\n' "$LAUNCH_AGENT"
printf '签名类型：本机 ad-hoc（非 Apple 公证）\n'
printf '下一步：请由用户本人启用“系统设置 → 隐私与安全性 → 辅助功能 → Codex 上下文仪表”。\n'
