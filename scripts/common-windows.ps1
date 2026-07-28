$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$script:SkillDir = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$script:ExpectedRepository = "https://github.com/sunlulu0122-alt/codex-context-meter-skill"
$script:ProductName = "Codex 上下文仪表"
$script:DefaultInstallDir = Join-Path $env:LOCALAPPDATA "Programs\codex-context-meter"
$script:ExpectedInstallerSha256 = "ff248a8193e17cf94019b5821755f67a20ac54cae208d2c92e5cf901c66b0703"

function Stop-WithError([string]$Message) {
    throw "错误：$Message"
}

function Assert-Windows {
    if ($env:OS -ne "Windows_NT") {
        Stop-WithError "此脚本只支持 Windows。"
    }
}

function Assert-SupportedWindowsArchitecture {
    $architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    if ($architecture -ne "X64") {
        Stop-WithError "版本 1.3.0 的 Windows 安装器仅支持 x64；当前系统为 $architecture。"
    }
    Write-Output "系统架构已验证：Windows x64"
}

function Get-NormalizedRemote([string]$Remote) {
    $value = $Remote.Trim()
    if ($value.EndsWith(".git")) {
        $value = $value.Substring(0, $value.Length - 4)
    }
    if ($value.StartsWith("git@github.com:")) {
        $value = "https://github.com/" + $value.Substring("git@github.com:".Length)
    }
    return $value
}

function Assert-SourceOrigin([switch]$AllowLocalSource) {
    $repoRoot = (& git -C $script:SkillDir rev-parse --show-toplevel 2>$null)
    if (-not $repoRoot) {
        if (-not $AllowLocalSource) {
            Stop-WithError "无法验证 Git 来源；仅对已人工核验的副本使用 -AllowLocalSource。"
        }
        Write-Warning "已显式允许无法通过 Git 验证的本地来源。"
        return
    }
    $remote = (& git -C $repoRoot remote get-url origin 2>$null)
    if ((Get-NormalizedRemote $remote) -ne $script:ExpectedRepository) {
        Stop-WithError "Git 来源不受信任：$remote"
    }
    $revision = (& git -C $repoRoot rev-parse --short=12 HEAD)
    Write-Output "来源已验证：$($script:ExpectedRepository) @ $revision"
}

function Assert-FileSha256([string]$Path, [string]$Expected) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Stop-WithError "文件不存在：$Path"
    }
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $Expected.ToLowerInvariant()) {
        Stop-WithError "SHA-256 不匹配：$Path"
    }
    Write-Output "SHA-256 已验证：$actual"
}

function Get-InstalledExecutable {
    $candidates = @(
        (Join-Path $script:DefaultInstallDir "$($script:ProductName).exe"),
        (Join-Path $env:LOCALAPPDATA "Programs\Codex Context Meter\$($script:ProductName).exe")
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }
    return $candidates[0]
}
