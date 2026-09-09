# build_exe.ps1 — 编译 杜比管家 DolbyMaster.exe（作者 soil，版本号=构建日期自动）
# English: compile DolbyMaster.exe from src (author soil; version = build date; AssemblyInfo auto-generated).
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File build_exe.ps1 [-Dst <输出目录>]
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File build_exe.ps1 [-Dst <output dir>]
# -Dst：输出目录；默认 F:\Audio\DolbyMaster（开发）。干净版自构建传自身目录（build.cmd 已处理）。
# -Dst: output dir; defaults to F:\Audio\DolbyMaster (dev). The clean edition passes its own dir (handled by build.cmd).
param(
    [string]$Dst = ''   # 输出目录 / output directory
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$date = Get-Date
$ver  = "1.0.$($date.Year).$($date.ToString('MMdd'))"   # 例 1.0.2026.0907（各段 <=65535）
if (-not $Dst) { $Dst = 'F:\Audio\DolbyMaster' }

$asm = @"
using System.Reflection;
[assembly: AssemblyTitle("杜比管家（通用版）")]
[assembly: AssemblyDescription("Dolby DAX3 通用安装 / 设备挂接 / 调音切换 / 卸载")]
[assembly: AssemblyCompany("soil")]
[assembly: AssemblyProduct("杜比管家")]
[assembly: AssemblyCopyright("Copyright (c) soil")]
[assembly: AssemblyVersion("$ver")]
[assembly: AssemblyFileVersion("$ver")]
"@
[System.IO.File]::WriteAllText((Join-Path $here 'AssemblyInfo.cs'), $asm, [System.Text.UTF8Encoding]::new($true))

$csc = @(
  'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe',
  'C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe'
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $csc) { Write-Error '未找到 csc.exe（.NET Framework 编译器）'; exit 1 }

$out      = Join-Path $dst 'DolbyMaster.exe'
$manifest = '/win32manifest:' + (Join-Path $here 'app.manifest')
$srcCs    = Join-Path $here 'DolbyMaster.cs'
$srcSpec  = Join-Path $here 'Spectrum.cs'      # 频谱可视化（WASAPI 环回 + FFT）/ spectrum (WASAPI loopback + FFT)
$srcWeb   = Join-Path $here 'SpectrumWeb.cs'   # WebView2 3D-Spectrogram 宿主 / WebView2 3D-Spectrogram host
$srcAsm   = Join-Path $here 'AssemblyInfo.cs'
# WebView2 SDK（Microsoft.Web.WebView2）引用 / WebView2 SDK references
$wvCore     = Join-Path $here 'WebView2\lib\net462\Microsoft.Web.WebView2.Core.dll'
$wvWinForms = Join-Path $here 'WebView2\lib\net462\Microsoft.Web.WebView2.WinForms.dll'

# ---- 内嵌原创脚本（内存执行，不落盘）：/resource:<file>,DolbyMaster.Scripts.<name> ----
# 源码位于 src\（$here）；交付包 DolbyMaster\ 不含 .ps1。
# 嵌入前预处理：剥 BOM + 剥首行 #requires（scriptblock 里它非法；运行时 C# 再剥一次作双保险）。
# Embedded original scripts (executed in memory, never written to disk). Sources live in src\ ($here).
# Pre-process before embedding: strip BOM and a leading #requires line (illegal inside a scriptblock;
# the C# runtime strips it again as a second line of defense).
$embedTmp = Join-Path $here '.embed_tmp'
if (Test-Path $embedTmp) { Remove-Item $embedTmp -Recurse -Force }
New-Item -ItemType Directory -Path $embedTmp -Force | Out-Null
$embed = @()
foreach ($e in @(
  @{ File = Join-Path $here 'APOHook.ps1';        Name = 'APOHook.ps1' },
  @{ File = Join-Path $here 'TuningSwitcher.ps1'; Name = 'TuningSwitcher.ps1' },
  @{ File = Join-Path $here 'CustomTuning.ps1';   Name = 'CustomTuning.ps1' },
  @{ File = Join-Path $here 'AutoProfile.ps1';    Name = 'AutoProfile.ps1' },
  @{ File = Join-Path $here 'RebuildData.ps1';    Name = 'RebuildData.ps1' },
  @{ File = Join-Path $here 'Status.ps1';         Name = 'Status.ps1' },
  @{ File = Join-Path $here 'Scripts\Setup-Dolby.ps1'; Name = 'Setup-Dolby.ps1' }
)) {
    if (-not (Test-Path $e.File)) { continue }
    $t = [IO.File]::ReadAllText($e.File, [Text.Encoding]::UTF8)
    $t = $t -replace "^\uFEFF", ''
    $t = $t -replace '(?m)^[ \t]*#requires[^\r\n]*(\r?\n|$)', ''
    $tmp = Join-Path $embedTmp $e.Name
    [IO.File]::WriteAllText($tmp, $t, [Text.Encoding]::UTF8)   # 无 BOM 写入（资源按 UTF-8 无 BOM）
    $embed += '/resource:' + $tmp + ',DolbyMaster.Scripts.' + $e.Name
}
Write-Host "[嵌入脚本] $($embed.Count) 个"

& $csc '/nologo' '/target:winexe' '/optimize+' '/debug+' '/r:System.IO.Compression.dll' '/r:System.Drawing.dll' '/r:System.Windows.Forms.dll' ('/r:' + $wvCore) ('/r:' + $wvWinForms) $manifest ('/out:' + $out) $srcCs $srcSpec $srcWeb $srcAsm @embed
if ($LASTEXITCODE -ne 0) { Write-Error "编译失败 (exit $LASTEXITCODE)"; exit 1 }

# 复制 WebView2 运行时依赖（托管 dll + WebView2Loader native）到 exe 目录 / copy WebView2 runtime deps to exe dir
$copyWebDeps = @(
  @{ Src = $wvCore;       Dst = Join-Path $dst 'Microsoft.Web.WebView2.Core.dll' },
  @{ Src = $wvWinForms;   Dst = Join-Path $dst 'Microsoft.Web.WebView2.WinForms.dll' },
  @{ Src = Join-Path $here 'WebView2\runtimes\win-x64\native\WebView2Loader.dll'; Dst = Join-Path $dst 'WebView2Loader.dll' }
)
foreach ($c in $copyWebDeps) { if (Test-Path $c.Src) { Copy-Item $c.Src $c.Dst -Force } }

# 复制 3D-Spectrogram 页面资源（Three.js 原版 + 注入桥接）到 exe 目录 / copy the 3D-Spectrogram web assets
$webSrc = Join-Path $here 'Web'
$webDst = Join-Path $dst 'Web'
if (Test-Path $webSrc) {
  if (-not (Test-Path $webDst)) { New-Item -ItemType Directory -Path $webDst -Force | Out-Null }
  Copy-Item (Join-Path $webSrc '*') $webDst -Recurse -Force
  Write-Host "[Web] 3D-Spectrogram 资源已复制到 $webDst"
}

$vi = (Get-Item $out).VersionInfo
Write-Host ("[完成] {0}  {1} KB" -f $out, [math]::Round((Get-Item $out).Length/1KB))
Write-Host ("       产品: {0}  版本: {1}  公司: {2}" -f $vi.ProductName, $vi.FileVersion, $vi.CompanyName)
if (Test-Path $embedTmp) { Remove-Item $embedTmp -Recurse -Force }   # 清理嵌入预处理临时目录
