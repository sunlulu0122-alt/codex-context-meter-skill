#!/bin/bash
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXPECTED_REPOSITORY="https://github.com/sunlulu0122-alt/codex-context-meter-skill"
APP_NAME="Codex 上下文仪表.app"
APP_IDENTIFIER="com.sunlulu.codex-context-meter"
APP_EXECUTABLE="CodexContextMeter"

die() {
  printf '错误：%s\n' "$*" >&2
  exit 1
}

verify_macos() {
  [[ "$(uname -s)" == "Darwin" ]] || die "此脚本只支持 macOS。"
}

verify_source_origin() {
  local allow_local="${1:-false}"
  local repo_root remote normalized
  repo_root="$(git -C "$SKILL_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -z "$repo_root" ]]; then
    [[ "$allow_local" == "true" ]] || die "无法验证 Git 来源；仅对已人工核验的副本使用 --allow-local-source。"
    printf '警告：已显式允许无法通过 Git 验证的本地来源。\n'
    return
  fi
  remote="$(git -C "$repo_root" remote get-url origin 2>/dev/null || true)"
  normalized="${remote%.git}"
  normalized="${normalized/git@github.com:/https:\/\/github.com\/}"
  [[ "$normalized" == "$EXPECTED_REPOSITORY" ]] || die "Git 来源不受信任：${remote:-未设置 origin}"
  printf '来源已验证：%s @ %s\n' "$EXPECTED_REPOSITORY" "$(git -C "$repo_root" rev-parse --short=12 HEAD)"
}

verify_asset_hashes() {
  local manifest="$SKILL_DIR/assets/SHA256SUMS"
  [[ -f "$manifest" ]] || die "缺少资产校验清单：$manifest"
  (
    cd "$SKILL_DIR"
    /usr/bin/shasum -a 256 -c "assets/SHA256SUMS"
  ) || die "资产 SHA-256 校验失败。"
}
