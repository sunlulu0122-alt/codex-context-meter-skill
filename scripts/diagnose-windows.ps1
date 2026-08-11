. (Join-Path $PSScriptRoot "common-windows.ps1")
Assert-Windows
Assert-SupportedWindowsArchitecture

$failures = 0
function Test-Diagnostic([string]$Label, [scriptblock]$Check) {
    try {
        if (& $Check) { Write-Output "通过：$Label" }
        else { Write-Output "失败：$Label"; $script:failures += 1 }
    } catch { Write-Output "失败：$Label（$($_.Exception.Message)）"; $script:failures += 1 }
}

$executable = Get-InstalledExecutable
$native = $executable -eq (Join-Path $script:NativeInstallDir "CodexContextMeter.exe")
$runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$startup = (Get-ItemProperty -Path $runKey -Name CodexContextMeter -ErrorAction SilentlyContinue).CodexContextMeter

Write-Output "系统：Windows $([Environment]::OSVersion.Version) ($env:PROCESSOR_ARCHITECTURE)"
Write-Output "实现：$(if ($native) { '轻量原生 .NET Framework / WinForms' } else { 'Electron 兼容回退版' })"
Test-Diagnostic "应用存在" { Test-Path -LiteralPath $executable -PathType Leaf }
Test-Diagnostic "应用为有效 PE 文件" { $bytes = [System.IO.File]::ReadAllBytes($executable); $bytes.Length -gt 2 -and $bytes[0] -eq 0x4d -and $bytes[1] -eq 0x5a }
Test-Diagnostic "应用进程正在运行" { $null -ne (Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($executable)) -ErrorAction SilentlyContinue) }
Test-Diagnostic "登录启动已配置" { $startup -and $startup.Contains($executable) }
Test-Diagnostic "Codex 会话索引可读" { $home = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME ".codex" }; Test-Path -LiteralPath (Join-Path $home "session_index.jsonl") -PathType Leaf }

if ($native -and (Test-Path $executable)) { Write-Output "应用体积：$((Get-Item $executable).Length) bytes" }
$errorLog = Join-Path $env:APPDATA "Codex Context Meter\handoff-error.log"
if (Test-Path $errorLog) { Write-Warning "检测到自动交接错误日志：$errorLog" }
if ($failures -gt 0) { throw "诊断完成：$failures 项失败。" }
Write-Output "诊断完成：安装、进程、登录启动和会话索引均通过。UI 只在 Codex 对话窗口位于前台时显示。"
