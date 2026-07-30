param([string]$OutputPath = (Join-Path $PSScriptRoot 'dist\CodexContextMeter.exe'))
$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'CodexContextMeter.cs'
$output = [System.IO.Path]::GetFullPath($OutputPath)
$dist = Split-Path $output -Parent
New-Item -ItemType Directory -Force -Path $dist | Out-Null

$frameworkRoots = @(
  "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319",
  "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319"
)
$compiler = $frameworkRoots | ForEach-Object { Join-Path $_ 'csc.exe' } | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $compiler) { throw '找不到 Windows .NET Framework C# 编译器。请启用 .NET Framework 4.8。' }

& $compiler /nologo /target:winexe /optimize+ /platform:anycpu /out:$output `
  /reference:System.dll /reference:System.Core.dll /reference:System.Drawing.dll `
  /reference:System.Windows.Forms.dll /reference:System.Web.Extensions.dll `
  /reference:UIAutomationClient.dll /reference:UIAutomationTypes.dll $source
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $output)) { throw 'Windows 原生版编译失败。' }

$hash = (Get-FileHash -Algorithm SHA256 $output).Hash.ToLowerInvariant()
$size = (Get-Item $output).Length
Write-Host "Built: $output"
Write-Host "Size:  $size bytes"
Write-Host "SHA256: $hash"
