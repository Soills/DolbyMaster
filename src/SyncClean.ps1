#requires -version 5.1
# SyncClean.ps1 — 把干净版需要的源码+构建代码同步进干净版（先删旧、再拷新）
# English: sync the source + build code needed by the clean edition INTO the clean edition (delete old, copy new).
# 用法 / Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File SyncClean.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File SyncClean.ps1 -Clean "D:\x\DolbyMaster_1.0.2026.0909_干净版"
param(
    [string]$Clean = ''   # 干净版目录；留空自动找 Release 下最新一个
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

function Copy-Tree([string]$From, [string]$To, [string[]]$Exclude) {
    # 纯 Copy-Item 递归（robocopy 在受限环境会被拒）/ plain Copy-Item recursion (robocopy denied in restricted shells)
    if (-not (Test-Path -LiteralPath $To)) { New-Item -ItemType Directory -Path $To -Force | Out-Null }
    foreach ($item in Get-ChildItem -LiteralPath $From -Force) {
        $skip = $false
        foreach ($ex in $Exclude) { if ($item.Name -like $ex) { $skip = $true; break } }
        if ($skip) { continue }
        $dest = Join-Path $To $item.Name
        if ($item.PSIsContainer) { Copy-Tree $item.FullName $dest $Exclude }
        else { Copy-Item -LiteralPath $item.FullName -Destination $dest -Force }
    }
}

# 定位干净版目录：-Clean 优先，否则 Release 下最新 / locate the clean edition: -Clean wins, else newest under Release
if (-not $Clean) {
    $rel = Get-ChildItem (Join-Path (Split-Path -Parent $here) 'Release') -Directory -Filter 'DolbyMaster_*_干净版' -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1
    if ($rel) { $Clean = $rel.FullName }
}
if (-not $Clean -or -not (Test-Path -LiteralPath $Clean)) { throw "找不到干净版目录（用 -Clean 指定） / clean edition dir not found (pass -Clean)" }
Write-Host "[SyncClean] 目标: $Clean"

$srcDir = Join-Path $Clean 'src'
# ---- 1) 删除旧的源码/构建副本（保留 exe/Web/Data/docs 运行物） / delete old source+build copies ----
if (Test-Path -LiteralPath $srcDir) {
    Remove-Item -LiteralPath $srcDir -Recurse -Force
    Write-Host "[SyncClean] 已删除旧 src: $srcDir"
}

# ---- 2) 复制新的源码 + 构建代码 / copy new source + build code ----
New-Item -ItemType Directory -Path $srcDir -Force | Out-Null
$files = @(
    'DolbyMaster.cs','Spectrum.cs','SpectrumWeb.cs','app.manifest',
    'build_exe.ps1','MakeRelease.ps1','SyncClean.ps1',
    'APOHook.ps1','TuningSwitcher.ps1','CustomTuning.ps1','AutoProfile.ps1','RebuildData.ps1','Status.ps1'
)
foreach ($f in $files) {
    $from = Join-Path $here $f
    if (Test-Path -LiteralPath $from) { Copy-Item -LiteralPath $from -Destination (Join-Path $srcDir $f) -Force }
}
$ss = Join-Path $here 'Scripts'
if (Test-Path -LiteralPath $ss) {
    New-Item -ItemType Directory -Path (Join-Path $srcDir 'Scripts') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $ss 'Setup-Dolby.ps1') -Destination (Join-Path $srcDir 'Scripts\Setup-Dolby.ps1') -Force
}
foreach ($d in 'WebView2','Web') {
    $from = Join-Path $here $d
    if (Test-Path -LiteralPath $from) { Copy-Tree $from (Join-Path $srcDir $d) @() }
}

# ---- 3) 同步构建入口 build.cmd（删旧 exe → 构建 → 新 exe） / sync the build entry ----
$buildCmd = "@echo off`r`n" +
    "cd /d `"%~dp0`"`r`n" +
    "taskkill /f /im DolbyMaster.exe 2>nul`r`n" +
    "echo [build] deleting old exe...`r`n" +
    "del /q `"%~dp0DolbyMaster.exe`" 2>nul`r`n" +
    "echo [build] building (src\build_exe.ps1)...`r`n" +
    "powershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0src\build_exe.ps1`" -Dst `"%~dp0.`"`r`n" +
    "if errorlevel 1 ( echo [build] FAILED & pause & exit /b 1 )`r`n" +
    "echo [build] done: %~dp0DolbyMaster.exe`r`n" +
    "pause`r`n"
[IO.File]::WriteAllText((Join-Path $Clean 'build.cmd'), $buildCmd, [Text.Encoding]::ASCII)

# 记下本次目标路径，供 build_clean.cmd 使用 / record the target for build_clean.cmd
[IO.File]::WriteAllText((Join-Path $here 'last_clean.txt'), $Clean, [Text.Encoding]::ASCII)

$n = (Get-ChildItem -LiteralPath $srcDir -Recurse -File).Count
Write-Host "[SyncClean] 完成：源码/构建已同步（$n 个文件）到 $srcDir"
Write-Host "[SyncClean] 双击目标内的 build.cmd 即可重建 exe；或运行 build_clean.cmd 一键同步+构建。"
