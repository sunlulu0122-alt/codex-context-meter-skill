. (Join-Path $PSScriptRoot "common-windows.ps1")
Assert-Windows

$executable = Get-InstalledExecutable
$installDir = Split-Path -Parent $executable
$uninstaller = Join-Path $installDir "Uninstall $($script:ProductName).exe"

$processName = [System.IO.Path]::GetFileNameWithoutExtension($executable)
Get-Process -Name $processName -ErrorAction SilentlyContinue | Stop-Process -Force

if (Test-Path -LiteralPath $uninstaller -PathType Leaf) {
    $process = Start-Process -FilePath $uninstaller -ArgumentList "/S" -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        Stop-WithError "卸载器退出码为 $($process.ExitCode)。"
    }
    Write-Output "已运行卸载器：$uninstaller"
} elseif (Test-Path -LiteralPath $installDir -PathType Container) {
    $expectedRoot = [System.IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA "Programs"))
    $actual = [System.IO.Path]::GetFullPath($installDir)
    if (-not $actual.StartsWith($expectedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        Stop-WithError "拒绝删除非预期路径：$actual"
    }
    Remove-Item -LiteralPath $installDir -Recurse -Force
    Write-Output "未找到卸载器，已移除应用目录：$installDir"
} else {
    Write-Output "应用未安装：$installDir"
}
Write-Output "卸载完成；Codex 对话和数据库未被修改。"
