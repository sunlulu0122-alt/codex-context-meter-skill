param(
    [switch]$AllowLocalSource,
    [switch]$NoStart,
    [switch]$UseElectronFallback,
    [string]$InstallerPath = ""
)

. (Join-Path $PSScriptRoot "common-windows.ps1")
Assert-Windows
Assert-SupportedWindowsArchitecture
Assert-SourceOrigin -AllowLocalSource:$AllowLocalSource

if ($UseElectronFallback) {
    if (-not $InstallerPath) {
        Stop-WithError "Electron 回退版必须显式提供 -InstallerPath；不会从私有仓库猜测或匿名下载。"
    }
    Assert-FileSha256 -Path $InstallerPath -Expected $script:ExpectedInstallerSha256
    Write-Warning "正在安装约 95MB 的 Electron 兼容回退版；它没有 Authenticode 发布者签名。"
    $process = Start-Process -FilePath $InstallerPath -ArgumentList "/S" -Wait -PassThru
    if ($process.ExitCode -ne 0) { Stop-WithError "Electron 安装器退出码为 $($process.ExitCode)。" }
    Write-Output "Electron 兼容回退版安装完成。"
    exit 0
}

$nativeDir = Join-Path $script:SkillDir "assets\windows-native"
$buildScript = Join-Path $nativeDir "build.ps1"
$sourceFile = Join-Path $nativeDir "CodexContextMeter.cs"
if (-not (Test-Path -LiteralPath $buildScript) -or -not (Test-Path -LiteralPath $sourceFile)) {
    Stop-WithError "Skill 缺少 Windows 原生版源码或构建脚本。"
}
Assert-BundledAssetHash "assets\windows-native\CodexContextMeter.cs"
Assert-BundledAssetHash "assets\windows-native\build.ps1"

$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-context-meter-native-" + [Guid]::NewGuid().ToString("N"))
$tempExe = Join-Path $tempDir "CodexContextMeter.exe"
$installDir = $script:NativeInstallDir
$target = Join-Path $installDir "CodexContextMeter.exe"
New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
try {
    & $buildScript -OutputPath $tempExe
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $tempExe)) {
        Stop-WithError "原生版本机编译失败。可在确认旧安装器校验值后显式使用 -UseElectronFallback。"
    }
    $bytes = [System.IO.File]::ReadAllBytes($tempExe)
    if ($bytes.Length -lt 3 -or $bytes[0] -ne 0x4d -or $bytes[1] -ne 0x5a) {
        Stop-WithError "原生版输出不是有效的 Windows PE 文件。"
    }
    Get-Process CodexContextMeter -ErrorAction SilentlyContinue | Stop-Process -Force
    New-Item -ItemType Directory -Force -Path $installDir | Out-Null
    Copy-Item -LiteralPath $tempExe -Destination $target -Force
    $runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    New-Item -Path $runKey -Force | Out-Null
    New-ItemProperty -Path $runKey -Name "CodexContextMeter" -Value ('"{0}"' -f $target) -PropertyType String -Force | Out-Null
    if (-not $NoStart) {
        Start-Process -FilePath $target
        Start-Sleep -Seconds 2
        if (-not (Get-Process CodexContextMeter -ErrorAction SilentlyContinue)) {
            Stop-WithError "原生应用已安装，但进程验证失败。"
        }
    }
    $hash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Output "Windows 轻量原生版安装完成：$target"
    Write-Output "安装体积：$((Get-Item $target).Length) bytes"
    Write-Output "SHA-256：$hash"
    Write-Output "登录启动：HKCU Run（仅当前用户）。"
} finally {
    if (Test-Path -LiteralPath $tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force }
}
