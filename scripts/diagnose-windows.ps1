. (Join-Path $PSScriptRoot "common-windows.ps1")
Assert-Windows
Assert-SupportedWindowsArchitecture

$failures = 0
function Test-Diagnostic([string]$Label, [scriptblock]$Check) {
    try {
        if (& $Check) {
            Write-Output "通过：$Label"
        } else {
            Write-Output "失败：$Label"
            $script:failures += 1
        }
    } catch {
        Write-Output "失败：$Label（$($_.Exception.Message)）"
        $script:failures += 1
    }
}

$executable = Get-InstalledExecutable
$processName = [System.IO.Path]::GetFileNameWithoutExtension($executable)
$startupApproved = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"

Write-Output "系统：Windows $([Environment]::OSVersion.Version) ($env:PROCESSOR_ARCHITECTURE)"
Test-Diagnostic "应用存在" { Test-Path -LiteralPath $executable -PathType Leaf }
Test-Diagnostic "应用为有效 PE 文件" {
    $bytes = [System.IO.File]::ReadAllBytes($executable)
    $bytes.Length -gt 2 -and $bytes[0] -eq 0x4d -and $bytes[1] -eq 0x5a
}
Test-Diagnostic "应用进程正在运行" {
    $null -ne (Get-Process -Name $processName -ErrorAction SilentlyContinue)
}
Test-Diagnostic "Codex 会话索引可读" {
    $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME ".codex" }
    Test-Path -LiteralPath (Join-Path $codexHome "session_index.jsonl") -PathType Leaf
}

if (Test-Path $startupApproved) {
    Write-Output "信息：Windows 登录启动审批注册表存在；具体应用项由 Electron 管理。"
} else {
    Write-Output "提示：未找到登录启动审批注册表；请启动应用一次后重新诊断。"
}

if ($failures -gt 0) {
    throw "诊断完成：$failures 项失败。"
}
Write-Output "诊断完成：基础安装和进程检查均通过。UI 仅在 Codex 支持的对话视图处于前台时显示。"
