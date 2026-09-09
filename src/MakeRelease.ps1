#requires -version 5.1
param(
    [string]$Ver = '',
    [string]$Out = 'F:\Audio\Release',
    [ValidateSet('Full','Clean','Both')]
    [string]$Edition = 'Full'
)
$ErrorActionPreference = 'Stop'
$src = Split-Path -Parent $MyInvocation.MyCommand.Path
$pkg = Join-Path (Split-Path -Parent $src) 'DolbyMaster'
if (-not (Test-Path -LiteralPath $pkg)) { throw "找不到交付包: $pkg" }
if (-not $Ver) {
    $asm = Join-Path $src 'AssemblyInfo.cs'
    if (Test-Path -LiteralPath $asm) {
        $m = [regex]::Match((Get-Content -Raw -LiteralPath $asm), 'AssemblyVersion\("([^"]+)"\)')
        if ($m.Success) { $Ver = $m.Groups[1].Value }
    }
}
if (-not $Ver) { $Ver = '1.0.' + (Get-Date -Format 'yyyy.MMdd') }
New-Item -ItemType Directory -Path $Out -Force | Out-Null
$full = Join-Path $Out "DolbyMaster_${Ver}_完整版"
$clean = Join-Path $Out "DolbyMaster_${Ver}_干净版"

function Reset-Dir([string]$Path) {
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}
function Copy-Tree([string]$From, [string]$To, [string[]]$Exclude) {
    # 纯 Copy-Item 递归（robocopy 在受限环境会被拒）；Exclude 按文件名/通配符匹配
    # plain Copy-Item recursion (robocopy is denied in restricted shells); Exclude matches names/wildcards
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

if ($Edition -eq 'Full' -or $Edition -eq 'Both') {
    Write-Host "==> 生成完整版: $full"
    Reset-Dir $full
    Copy-Tree $pkg $full @('error.log','*.cmd')
    Write-Host ("    [完成] {0} 个文件" -f (Get-ChildItem -LiteralPath $full -Recurse -File).Count)
}

if ($Edition -eq 'Clean' -or $Edition -eq 'Both') {
    Write-Host "==> 生成干净版: $clean"
    Reset-Dir $clean
    # 可运行的最小包：exe + WebView2 运行库(否则启动即崩) + 频谱 Web 资源 + 数据缓存 Data + 说明。
    # 不含驱动/安装负载（Drivers/Appx/Crack/Scripts）：干净版面向已装杜比的机器。
    # 全部 README.md 文档收集到 docs\ 保留原始相对路径，不丢任何说明。
    # Minimal runnable package: exe + WebView2 runtime DLLs (else crash) + spectrum Web assets + data cache.
    # No driver/install payload (Drivers/Appx/Crack/Scripts): Clean targets machines that already have Dolby.
    # All README.md docs collected under docs\ (original relative paths preserved).
    Copy-Item -LiteralPath (Join-Path $pkg 'DolbyMaster.exe') -Destination $clean
    foreach ($dll in 'Microsoft.Web.WebView2.Core.dll','Microsoft.Web.WebView2.WinForms.dll','WebView2Loader.dll') {
        $from = Join-Path $pkg $dll
        if (Test-Path -LiteralPath $from) { Copy-Item -LiteralPath $from -Destination $clean }
    }
    $data = Join-Path $pkg 'Data'
    if (Test-Path -LiteralPath $data) { Copy-Tree $data (Join-Path $clean 'Data') @('error.log') }
    $web = Join-Path $pkg 'Web'
    if (Test-Path -LiteralPath $web) { Copy-Tree $web (Join-Path $clean 'Web') @() }
    # 收集被精简掉文件夹（Appx/Crack/Drivers/Scripts）的 README.md 到 docs\；Data/Web 自带的不重复收
    # collect README.md from dropped folders (Appx/Crack/Drivers/Scripts) into docs\; Data/Web ship in place
    foreach ($md in (Get-ChildItem $pkg -Recurse -Filter 'README.md' -File -ErrorAction SilentlyContinue)) {
        $rel = $md.FullName.Substring($pkg.Length).TrimStart('\')
        if ($rel -eq 'README.md' -or $rel -like 'Data\*' -or $rel -like 'Web\*') { continue }
        $dest = Join-Path $clean ('docs\' + $rel)
        $dd = Split-Path -Parent $dest
        if (-not (Test-Path -LiteralPath $dd)) { New-Item -ItemType Directory -Path $dd -Force | Out-Null }
        Copy-Item -LiteralPath $md.FullName -Destination $dest -Force
    }
    # 源码 + 构建代码（干净版可自行改码重建）：src\ 镜像 + build.cmd 入口
    # source + build kit (clean edition is rebuildable): src\ mirror + build.cmd entry
    $srcDir = Join-Path $clean 'src'
    New-Item -ItemType Directory -Path $srcDir -Force | Out-Null
    foreach ($f in 'DolbyMaster.cs','Spectrum.cs','SpectrumWeb.cs','app.manifest',
                   'build_exe.ps1','MakeRelease.ps1','SyncClean.ps1',
                   'APOHook.ps1','TuningSwitcher.ps1','CustomTuning.ps1','AutoProfile.ps1','RebuildData.ps1','Status.ps1') {
        $from = Join-Path $src $f
        if (Test-Path -LiteralPath $from) { Copy-Item -LiteralPath $from -Destination (Join-Path $srcDir $f) -Force }
    }
    $ss = Join-Path $src 'Scripts'
    if (Test-Path -LiteralPath $ss) {
        New-Item -ItemType Directory -Path (Join-Path $srcDir 'Scripts') -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $ss 'Setup-Dolby.ps1') -Destination (Join-Path $srcDir 'Scripts\Setup-Dolby.ps1') -Force
    }
    foreach ($d in 'WebView2','Web') {
        $from = Join-Path $src $d
        if (Test-Path -LiteralPath $from) { Copy-Tree $from (Join-Path $srcDir $d) @() }
    }
    # 自构建入口 build.cmd：删旧 exe → 用 src\build_exe.ps1 重建 / self-build entry: delete old exe -> rebuild
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
    [IO.File]::WriteAllText((Join-Path $clean 'build.cmd'), $buildCmd, [Text.Encoding]::ASCII)

    # 双语 README.md（仓库根为规范副本）/ bilingual README.md (canonical copy at the repo root)
    $rootReadme = Join-Path (Split-Path -Parent $src) 'README.md'
    if (Test-Path -LiteralPath $rootReadme) { Copy-Item -LiteralPath $rootReadme -Destination (Join-Path $clean 'README.md') -Force }
    Write-Host ("    [完成] {0} 个文件" -f (Get-ChildItem -LiteralPath $clean -Recurse -File).Count)
}
Write-Host "[全部完成] Edition=$Edition"
if ($Edition -eq 'Full' -or $Edition -eq 'Both') { Write-Host "  完整版: $full" }
if ($Edition -eq 'Clean' -or $Edition -eq 'Both') { Write-Host "  干净版: $clean" }
