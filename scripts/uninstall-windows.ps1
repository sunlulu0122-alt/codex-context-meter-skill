. (Join-Path $PSScriptRoot "common-windows.ps1")
Assert-Windows

$nativeExecutable = Join-Path $script:NativeInstallDir "CodexContextMeter.exe"
if (Test-Path -LiteralPath $nativeExecutable) {
    Get-Process CodexContextMeter -ErrorAction SilentlyContinue | Stop-Process -Force
    $runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    Remove-ItemProperty -Path $runKey -Name CodexContextMeter -ErrorAction SilentlyContinue
    $actual = [IO.Path]::GetFullPath($script:NativeInstallDir)
    $expected = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA "Codex Context Meter"))
    if ($actual -ne $expected) { Stop-WithError "拒绝删除非预期路径：$actual" }
    Remove-Item -LiteralPath $actual -Recurse -Force
    Write-Output "已卸载 Windows 轻量原生版：$actual"
    Write-Output "用户状态与交接包保留在 AppData\Roaming，Codex 对话和数据库未被修改。"
    exit 0
}

$executable = Get-InstalledExecutable
$installDir = Split-Path -Parent $executable
$uninstaller = Join-Path $installDir "Uninstall $($script:ProductName).exe"
Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($executable)) -ErrorAction SilentlyContinue | Stop-Process -Force
if (Test-Path -LiteralPath $uninstaller -PathType Leaf) {
    $process = Start-Process -FilePath $uninstaller -ArgumentList "/S" -Wait -PassThru
    if ($process.ExitCode -ne 0) { Stop-WithError "卸载器退出码为 $($process.ExitCode)。" }
    Write-Output "已卸载 Electron 兼容回退版。"
} else { Write-Output "未检测到已安装的 Windows 版本。" }
