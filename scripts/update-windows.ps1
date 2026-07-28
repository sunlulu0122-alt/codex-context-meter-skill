. (Join-Path $PSScriptRoot "common-windows.ps1")
Assert-Windows

$repoRoot = (& git -C $script:SkillDir rev-parse --show-toplevel 2>$null)
if (-not $repoRoot) {
    Stop-WithError "升级要求使用 Git 克隆的 Skill。"
}
Assert-SourceOrigin
$dirty = (& git -C $repoRoot status --porcelain)
if ($dirty) {
    Stop-WithError "Skill 仓库有本地修改；为避免丢失内容，升级已停止。"
}
& git -C $repoRoot pull --ff-only
if ($LASTEXITCODE -ne 0) {
    Stop-WithError "Git 快进更新失败。"
}
& (Join-Path $PSScriptRoot "install-windows.ps1")
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
