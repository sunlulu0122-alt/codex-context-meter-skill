param(
    [switch]$AllowLocalSource,
    [string]$InstallerPath = "",
    [switch]$NoStart
)

. (Join-Path $PSScriptRoot "common-windows.ps1")
Assert-Windows
Assert-SupportedWindowsArchitecture
Assert-SourceOrigin -AllowLocalSource:$AllowLocalSource

$downloaded = $false
if (-not $InstallerPath) {
    $InstallerPath = Join-Path ([System.IO.Path]::GetTempPath()) "CodexContextMeter-Windows-Setup-1.3.0.exe"
    $url = "https://github.com/sunlulu0122-alt/codex-context-meter-skill/releases/download/v1.3.0/CodexContextMeter-Windows-Setup-1.3.0.exe"
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $InstallerPath
    $downloaded = $true
}

try {
    Assert-FileSha256 -Path $InstallerPath -Expected $script:ExpectedInstallerSha256
    Write-Warning "此 1.3.0 安装器没有 Authenticode 发布者签名；可信性依赖上方已验证的固定 SHA-256。"
    $process = Start-Process -FilePath $InstallerPath -ArgumentList "/S" -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        Stop-WithError "Windows 安装器退出码为 $($process.ExitCode)。"
    }
    $executable = Get-InstalledExecutable
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
        Stop-WithError "安装器已结束，但没有找到应用：$executable"
    }
    if (-not $NoStart) {
        Start-Process -FilePath $executable
        Start-Sleep -Seconds 3
        $processName = [System.IO.Path]::GetFileNameWithoutExtension($executable)
        if (-not (Get-Process -Name $processName -ErrorAction SilentlyContinue)) {
            Stop-WithError "应用已安装，但进程验证失败。"
        }
    }
    Write-Output "安装完成：$executable"
    Write-Output "登录启动：应用已调用 Electron setLoginItemSettings(openAtLogin=true)。"
} finally {
    if ($downloaded -and (Test-Path -LiteralPath $InstallerPath)) {
        Remove-Item -LiteralPath $InstallerPath -Force
    }
}
