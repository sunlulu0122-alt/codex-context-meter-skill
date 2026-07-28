#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common-macos.sh
source "$SCRIPT_DIR/common-macos.sh"

verify_macos
repo_root="$(git -C "$SKILL_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$repo_root" ]] || die "升级要求使用 Git 克隆的 Skill。"
verify_source_origin false
[[ -z "$(git -C "$repo_root" status --porcelain)" ]] || die "Skill 仓库有本地修改；为避免丢失内容，升级已停止。"
git -C "$repo_root" pull --ff-only
exec bash "$SCRIPT_DIR/install-macos.sh"
