#requires -version 5.1
<#
  AutoProfile.ps1 - 杜比 DAX3 按应用自动切档配置器
  编辑 dolbyaposvc\operator_settings.xml 的 AutoProfile 应用映射表：
  打开/关闭 auto_profile、增删 应用->档位 映射、设置默认档，可选重启 DolbyDAXAPI 服务。

  用法（改文件需管理员，脚本会自动提权重跑）：
    # 打开自动切档 + 加两条游戏映射（游戏运行时自动切到 personalize_user1 柔和档）
    powershell -ExecutionPolicy Bypass -File AutoProfile.ps1 -Enable `
        -AddGame "cs2.exe|personalize_user1;valorant.exe|personalize_user1" -RestartService
    # 只查看当前状态
    powershell -ExecutionPolicy Bypass -File AutoProfile.ps1 -Show
    # 关闭自动切档
    powershell -ExecutionPolicy Bypass -File AutoProfile.ps1 -Disable -RestartService
    # 设默认档为 music
    powershell -ExecutionPolicy Bypass -File AutoProfile.ps1 -SetDefault music
    # 删掉某应用映射
    powershell -ExecutionPolicy Bypass -File AutoProfile.ps1 -RemoveGame "cs2.exe" -RestartService

  可选 -Settings 指向别的 operator_settings.xml（默认本机部署的 C:\Windows\System32\dolbyaposvc\operator_settings.xml）。

  English summary:
    DAX3 per-app auto-profile configurator. Edits AutoProfile in operator_settings.xml:
    enable/disable auto_profile, add/remove exe->profile mappings, set default profile,
    optionally restart the DolbyDAXAPI service. Elevated re-launch is automatic when needed.
#>
param(
    [string]$Settings = "$env:WINDIR\System32\dolbyaposvc\operator_settings.xml",
    [switch]$Enable,          # 打开 auto_profile / enable auto profile
    [switch]$Disable,         # 关闭 / disable
    [string]$AddGame = '',    # "exe|profile;exe|profile"（profile 空=用默认档名）
    [string]$RemoveGame = '', # "exe;exe"
    [string]$SetDefault = '', # 默认档名（music/dynamic/movie/game/voice/off/personalize_user1...）
    [switch]$RestartService,  # 改完重启 DolbyDAXAPI 服务
    [switch]$Show             # 只显示当前状态
)
$ErrorActionPreference = 'Stop'
function Write-Ok   ($m) { Write-Host $m -ForegroundColor Green }
function Write-Warn ($m) { Write-Host $m -ForegroundColor Yellow }
function Write-Fail ($m) { Write-Host $m -ForegroundColor Red }

$isAdmin = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$needWrite = $Enable -or $Disable -or $AddGame -or $RemoveGame -or $SetDefault

# 提权重跑（写 System32 需要管理员）/ self-elevate for writes
# 只有目标在系统目录下才需要提权（临时/用户路径直接写）/
# elevate only when the target sits under the system dir
$needsAdminPath = $Settings -like "$env:WINDIR*"
if ($needWrite -and -not $isAdmin -and $needsAdminPath) {
    $arg = "-NoProfile -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`""
    foreach ($k in 'Settings','AddGame','RemoveGame','SetDefault') { if ($PSBoundParameters.ContainsKey($k) -and $PSBoundParameters[$k]) { $arg += " -$k `"$($PSBoundParameters[$k])`"" } }
    foreach ($sw in 'Enable','Disable','RestartService') { if ($PSBoundParameters.ContainsKey($sw) -and $PSBoundParameters[$sw]) { $arg += " -$sw" } }
    Write-Warn "[提权] 需要管理员写 System32，正在以管理员重跑…"
    Start-Process powershell -Verb RunAs -ArgumentList $arg
    exit 0
}

if (-not (Test-Path $Settings)) { Write-Fail "[错误] 找不到 operator_settings: $Settings"; exit 1 }
$doc = New-Object System.Xml.XmlDocument
$doc.PreserveWhitespace = $true
$doc.Load($Settings)
$ns = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
$ns.AddNamespace('x', $doc.DocumentElement.NamespaceURI)

function Get-AP([string]$name) {
    $doc.SelectSingleNode("//*[local-name()='AutoProfile']/*[local-name()='$name']", $ns)
}

# ---------- 查看 ----------
if ($Show -and -not $needWrite) {
    $ap = $doc.SelectSingleNode("//*[local-name()='AutoProfile']", $ns)
    $on = $ap.SelectSingleNode("*[local-name()='AutoProfileEnabled']", $ns)
    $btn = $ap.SelectSingleNode("*[local-name()='ShowAutoProfileButton']", $ns)
    Write-Host "AutoProfileEnabled: $($on.GetAttribute('value'))  ShowButton: $($btn.GetAttribute('value'))"
    foreach ($grp in $ap.SelectNodes("*[local-name()='Applications']", $ns)) {
        $pri = $grp.GetAttribute('priority')
        foreach ($app in $grp.SelectNodes("*[local-name()='APP']", $ns)) {
            Write-Host ("  [pri $pri] {0} -> {1}" -f $app.GetAttribute('name'), $app.GetAttribute('profile'))
        }
    }
    foreach ($dp in $doc.SelectNodes("//*[local-name()='default_profile']", $ns)) {
        Write-Host ("default_profile endpoint={0} spatial={1} -> {2}" -f $dp.GetAttribute('endpoint'), $dp.GetAttribute('spatial_audio'), $dp.GetAttribute('value'))
    }
    Write-Ok "[完成]"
    exit 0
}

# ---------- 开关 ----------
if ($Enable) {
    (Get-AP 'AutoProfileEnabled').SetAttribute('value', 'true')
    (Get-AP 'ShowAutoProfileButton').SetAttribute('value', 'true')
    Write-Host "  auto_profile: 已打开"
} elseif ($Disable) {
    (Get-AP 'AutoProfileEnabled').SetAttribute('value', 'false')
    Write-Host "  auto_profile: 已关闭"
}

# ---------- 增删映射 ----------
if ($AddGame) {
    $grp = $null
    # 找 priority=10 的分组，没有就新建（放最后，优先级最低，不覆盖联想默认映射）
    foreach ($g in $doc.SelectNodes("//*[local-name()='AutoProfile']/*[local-name()='Applications']", $ns)) {
        if ($g.GetAttribute('priority') -eq '10') { $grp = $g }
    }
    if (-not $grp) {
        $grp = $doc.CreateElement('Applications')
        $grp.SetAttribute('priority', '10')
        $last = $doc.SelectSingleNode("//*[local-name()='AutoProfile']/*[local-name()='Applications'][last()]", $ns)
        $last.ParentNode.InsertAfter($grp, $last)
    }
    foreach ($pair in ($AddGame -split ';')) {
        $pair = $pair.Trim(); if (-not $pair) { continue }
        $parts = @($pair -split '\|')
        $exe = $parts[0].Trim().ToLower()
        $prof = if ($parts.Count -ge 2 -and $parts[1].Trim()) { $parts[1].Trim() } else { 'personalize_user1' }
        if (-not $exe -or -not $exe.EndsWith('.exe')) { Write-Warn "[警告] 忽略非法条目: $pair（需 exe 名）"; continue }
        # 去重：同 exe 已有则更新 profile
        $found = $null
        foreach ($g in $doc.SelectNodes("//*[local-name()='AutoProfile']/*[local-name()='Applications']", $ns)) {
            foreach ($a in $g.SelectNodes("*[local-name()='APP']", $ns)) {
                if ($a.GetAttribute('name').ToLower() -eq $exe) { $found = $a }
            }
        }
        if ($found) { $found.SetAttribute('profile', $prof); Write-Host "  更新映射: $exe -> $prof" }
        else {
            $app = $doc.CreateElement('APP')
            $app.SetAttribute('name', $exe)
            $app.SetAttribute('profile', $prof)
            $grp.AppendChild($app) | Out-Null
            Write-Host "  添加映射: $exe -> $prof"
        }
    }
}

if ($RemoveGame) {
    foreach ($exe in ($RemoveGame -split ';')) {
        $exe = $exe.Trim().ToLower(); if (-not $exe) { continue }
        $removed = $false
        foreach ($g in $doc.SelectNodes("//*[local-name()='AutoProfile']/*[local-name()='Applications']", $ns)) {
            foreach ($a in @($g.SelectNodes("*[local-name()='APP']", $ns))) {
                if ($a.GetAttribute('name').ToLower() -eq $exe) { $g.RemoveChild($a) | Out-Null; $removed = $true }
            }
        }
        if ($removed) { Write-Host "  删除映射: $exe" } else { Write-Warn "[警告] 未找到 $exe 的映射" }
    }
}

# ---------- 默认档 ----------
if ($SetDefault) {
    $n = 0
    foreach ($dp in $doc.SelectNodes("//*[local-name()='default_profile']", $ns)) { $dp.SetAttribute('value', $SetDefault); $n++ }
    Write-Host "  default_profile -> $SetDefault ($n 个端点)"
}

# ---------- 保存 + 备份 ----------
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$bak = "$Settings.bak_$stamp"
Copy-Item $Settings $bak -Force
$doc.Save($Settings)
Write-Ok "[已保存] $Settings（备份: $bak）"

# ---------- 重启服务 ----------
if ($RestartService) {
    try {
        Restart-Service -Name 'DolbyDAXAPI' -Force -ErrorAction Stop
        Write-Ok "  DolbyDAXAPI 服务已重启"
    } catch {
        Write-Warn "  服务重启失败: $($_.Exception.Message)（可在管理员 PowerShell 里手动执行 Restart-Service DolbyDAXAPI）"
    }
}
Write-Warn "  提示：若档位未立即生效，设备管理器禁用再启用音频设备，或重启电脑。"
Write-Ok "[完成]"
exit 0
