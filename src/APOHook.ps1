#requires -version 5.1
<#
  APOHook.ps1 - 给任意音频输出端点挂 / 卸 Dolby APO（复刻 APO Driver Installer 机制）

  原理：
    音频引擎(audiodg)按端点的 FxProperties 里的 PKEY_FX_StreamEffectClsid 列表实例化 APO。
    本工具把 Dolby APO 包装器 CLSID 追加到目标端点的该列表，实现"为其他音频输出设备增加杜比"。
    与 Realtek 主输出(走 InterfaceSetting\ApoPreset 拓扑级)不同，这里是端点级直接挂接，
    对蓝牙 / USB / DP-HDMI / 任意输出设备都适用（前提：该设备在 Windows 里有渲染端点）。

  用法（需要管理员）：
    APOHook.ps1 -List                         列出所有渲染端点 + 当前 FX 链
    APOHook.ps1 -Add <名称或GUID>              给指定端点挂 Dolby APO（自动备份到 Backup\）
    APOHook.ps1 -AddAll                       给所有"激活"端点挂 Dolby APO
    APOHook.ps1 -Remove <名称或GUID>           从端点移除 Dolby APO
    APOHook.ps1 -Restore <名称或GUID>          从备份恢复端点原始 FX 链
    APOHook.ps1 -TuningAll                   全局兜底：给 MEDIA 类全部音频设备实例写 DaxExtFolder
    APOHook.ps1 -TuningRemoveAll             删除上述 DaxExtFolder（恢复原状）

  生效与恢复：
    修改后需重启电脑（或重启"Windows Audio"服务/audiodg）端点才会重载 APO 链。
    若端点声音异常/无声，立刻用 -Restore 恢复。
    Dolby APO 从宿主设备的 DaxExtFolder 读调音目录：Realtek 已由 Setup-Dolby 写好；
    蓝牙 / USB / DP-HDMI 设备没有，需先跑 -TuningAll 全局兜底（把 DaxExtFolder
    写到 MEDIA 类全部音频设备实例，指向 dolbyaposvc 的调音目录），否则 APO 找不到调音。
    属于实验性功能：无声或有声但无效都属正常，先在一个端点测试。

  English summary:
    Attach / remove / restore the Dolby APO on ANY audio output endpoint (bluetooth / USB / DP-HDMI / ...),
    by appending the Dolby wrapper CLSID to the endpoint's FxProperties FX-chain (PKEY_FX_StreamEffectClsid).
    This is endpoint-level (unlike Realtek main output which uses topology ApoPreset).
    Usage: APOHook.ps1 -List | -Add <name|GUID> | -AddAll | -Remove <name|GUID> | -Restore <name|GUID>
    | -TuningAll | -TuningRemoveAll   (admin; reboot / restart audiodg to take effect; changes auto-backed up)
#>
param(
    [switch]$List,
    [switch]$AddAll,
    [string]$Add,
    [string]$Remove,
    [string]$Restore,
    [switch]$TuningAll,
    [switch]$TuningRemoveAll,
    [string]$PackageRoot = ''   # 包根：内联执行由 exe 传 DM_BASE 环境变量；文件执行时自动定位
)
# 包根：内联执行（DM_BASE 进程环境变量）优先，否则文件自定位 / embedded run: DM_BASE env var; file run: auto-locate
if (-not $PackageRoot) { $PackageRoot = if ($env:DM_BASE) { $env:DM_BASE } else { Split-Path -Parent $MyInvocation.MyCommand.Path } }
$ErrorActionPreference = 'Stop'
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$FX_SET   = '{D04E05A6-594B-4FB6-A80D-01AF5EED7D1D}'
$FX_STREAM = "$FX_SET,5"      # PKEY_FX_StreamEffectClsid
$DOLBY_CLSID = '{0EBD8505-17BB-4AE7-AD76-E86F99A425E9}'   # DolbyAPO WRAPPER SFX
$RENDER_KEY = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render'
$NAME_PROP  = '{a45c254e-df1c-4efd-8020-67d146a850e0},2'
$MEDIA_CLASS = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e96c-e325-11ce-bfc1-08002be10318}'
$TUNING_DIR = 'C:\Windows\System32\dolbyaposvc'
$BackupDir  = Join-Path $PackageRoot 'Backup'

# ---------------------------------------------------------------
# 注册表写入助手：Windows 端点 FxProperties 的 ACL 只给 Audiosrv/
# TrustedInstaller 完整权限，管理员/用户只有 SetValue 而无
# KEY_CREATE_SUB_KEY——而 .NET/PowerShell 写值会以 KEY_WRITE
# (含 CreateSubKey) 打开键导致"访问被拒绝"。这里用 P/Invoke 只
# 请求 KEY_SET_VALUE 直接写值，绕开该限制（实测非管理员也可写）。
# ---------------------------------------------------------------
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class RegRaw {
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern int RegOpenKeyEx(IntPtr hKey, string lpSubKey, int ulOptions, int samDesired, out IntPtr phkResult);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern int RegSetValueEx(IntPtr hKey, string lpValueName, int reserved, int dwType, byte[] lpData, int cbData);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern int RegDeleteValue(IntPtr hKey, string lpValueName);
    [DllImport("advapi32.dll")]
    public static extern int RegCloseKey(IntPtr hKey);
    public const int HKEY_LOCAL_MACHINE = unchecked((int)0x80000002);
    public const int KEY_SET_VALUE = 0x0002;
    public const int REG_MULTI_SZ = 7;
    public const int REG_SZ = 1;
}
'@

function To-KeyPath($psPath) {
    $s = [string]$psPath
    $s = $s -replace '^Microsoft\.PowerShell\.Core\\Registry::HKEY_LOCAL_MACHINE\\', ''
    $s = $s -replace '^HKLM:\\', ''
    return $s
}

function Set-RegMulti([string]$keyPath, [string]$name, [string[]]$values) {
    $h = [IntPtr]::Zero
    $r = [RegRaw]::RegOpenKeyEx([RegRaw]::HKEY_LOCAL_MACHINE, $keyPath, 0, [RegRaw]::KEY_SET_VALUE, [ref]$h)
    if ($r -ne 0) { throw "无法打开注册表键 $keyPath (RegOpenKeyEx=$r)" }
    try {
        $sb = New-Object System.Text.StringBuilder
        foreach ($v in $values) { [void]$sb.Append($v); [void]$sb.Append([char]0) }
        [void]$sb.Append([char]0)
        $data = [System.Text.Encoding]::Unicode.GetBytes($sb.ToString())
        $r2 = [RegRaw]::RegSetValueEx($h, $name, 0, [RegRaw]::REG_MULTI_SZ, $data, $data.Length)
        if ($r2 -ne 0) { throw "写入值 $name 失败 (RegSetValueEx=$r2)" }
    } finally { [void][RegRaw]::RegCloseKey($h) }
}

# 写入 REG_SZ（Windows 端点 FxProperties 对 PKEY_FX_*Clsid 的原生格式；
# REG_MULTI_SZ 在 audiodg 重建端点图时会被 Windows 规范化/丢弃，导致挂接丢失）
function Set-RegString([string]$keyPath, [string]$name, [string]$value) {
    $h = [IntPtr]::Zero
    $r = [RegRaw]::RegOpenKeyEx([RegRaw]::HKEY_LOCAL_MACHINE, $keyPath, 0, [RegRaw]::KEY_SET_VALUE, [ref]$h)
    if ($r -ne 0) { throw "无法打开注册表键 $keyPath (RegOpenKeyEx=$r)" }
    try {
        $data = [System.Text.Encoding]::Unicode.GetBytes($value + [char]0)
        $r2 = [RegRaw]::RegSetValueEx($h, $name, 0, [RegRaw]::REG_SZ, $data, $data.Length)
        if ($r2 -ne 0) { throw "写入值 $name 失败 (RegSetValueEx=$r2)" }
    } finally { [void][RegRaw]::RegCloseKey($h) }
}

function Remove-RegValue([string]$keyPath, [string]$name) {
    $h = [IntPtr]::Zero
    $r = [RegRaw]::RegOpenKeyEx([RegRaw]::HKEY_LOCAL_MACHINE, $keyPath, 0, [RegRaw]::KEY_SET_VALUE, [ref]$h)
    if ($r -ne 0) { throw "无法打开注册表键 $keyPath (RegOpenKeyEx=$r)" }
    try {
        $r2 = [RegRaw]::RegDeleteValue($h, $name)
        if ($r2 -ne 0 -and $r2 -ne 2) { throw "删除值 $name 失败 (RegDeleteValue=$r2)" }  # 2=值不存在
    } finally { [void][RegRaw]::RegCloseKey($h) }
}

function Write-Ok   ($m) { Write-Host $m -ForegroundColor Green }
function Write-Warn ($m) { Write-Host $m -ForegroundColor Yellow }
function Write-Fail ($m) { Write-Host $m -ForegroundColor Red }
function Write-Head ($m) { Write-Host $m -ForegroundColor Cyan }

Write-Head "=========================================================="
Write-Head " Dolby APO 端点挂接工具（APO Driver Installer 同款机制）"
Write-Head "=========================================================="

if (-not $IsAdmin) {
    Write-Fail "[错误] 需要管理员权限（修改 HKLM 的端点 FxProperties）。"
    exit 1
}
if (-not $List -and -not $AddAll -and -not $Add -and -not $Remove -and -not $Restore -and -not $TuningAll -and -not $TuningRemoveAll) {
    Write-Warn "用法: APOHook.ps1 -List | -Add <端点> | -AddAll | -Remove <端点> | -Restore <端点> | -TuningAll | -TuningRemoveAll"
    exit 1
}

function Get-RenderEndpoints {
    $out = @()
    Get-ChildItem $RENDER_KEY -ErrorAction SilentlyContinue | ForEach-Object {
        $guid = $_.PSChildName
        $props = Get-ItemProperty "$($_.PSPath)\Properties" -ErrorAction SilentlyContinue
        $name = $props.$NAME_PROP
        if (-not $name) { $name = '(未命名)' }
        $state = (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).DeviceState
        $out += [pscustomobject]@{ Guid = $guid; Name = $name; State = $state; Key = $_.PSPath }
    }
    return $out
}

function Get-FxValues($epKey) {
    $fx = Join-Path $epKey 'FxProperties'
    if (-not (Test-Path $fx)) { return @{} }
    $p = Get-ItemProperty $fx
    $map = @{}
    foreach ($prop in $p.PSObject.Properties) {
        if ($prop.Name -notmatch '^PS') { $map[$prop.Name] = $prop.Value }
    }
    return $map
}

function Show-List {
    $eps = Get-RenderEndpoints
    Write-Host ""
    Write-Head "---- 渲染端点（State: 1=激活 4=未插 8=不存在 553648132=已插未激活）----"
    foreach ($ep in $eps) {
        Write-Host ""
        Write-Host "  $($ep.Name)  [$($ep.State)]"
        Write-Host "    GUID : $($ep.Guid)"
        $fx = Get-FxValues $ep.Key
        if ($fx.ContainsKey($FX_STREAM)) {
            $v = $fx[$FX_STREAM]
            $vs = if ($v -is [string]) { $v } else { ($v -join '; ') }
            Write-Host "    StreamEffect : $vs"
        } else {
            Write-Host "    StreamEffect : (无)"
        }
    }
    Write-Host ""
    Write-Host "匹配方法: 名称模糊匹配或完整 GUID。例: -Add \"扬声器\"  -Add \"{3d57bdfc-...}\""
}

function Find-Endpoint($match) {
    $eps = Get-RenderEndpoints
    if ($match -match '^\{[0-9A-Fa-f-]{36}\}$') {
        $ep = $eps | Where-Object { $_.Guid -eq $match } | Select-Object -First 1
        if ($ep) { return $ep }
    }
    # 优先匹配激活(State=1)端点；没有再取任意匹配
    $ep = $eps | Where-Object { $_.Name -like "*$match*" -and $_.State -eq 1 } | Select-Object -First 1
    if (-not $ep) { $ep = $eps | Where-Object { $_.Name -like "*$match*" } | Select-Object -First 1 }
    return $ep
}

function Save-Backup($ep, $map) {
    if (-not (Test-Path $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null }
    $file = Join-Path $BackupDir ("fxhook_{0}.json" -f $ep.Guid)
    $arr = @()
    foreach ($k in $map.Keys) {
        $v = $map[$k]
        $data = if ($v -is [array]) { @($v) } else { @($v.ToString()) }
        $arr += @{ n = $k; d = $data }
    }
    @{ guid = $ep.Guid; name = $ep.Name; values = $arr } | ConvertTo-Json -Depth 5 | Set-Content -Path $file -Encoding UTF8
    return $file
}

function Load-Backup($ep) {
    $file = Join-Path $BackupDir ("fxhook_{0}.json" -f $ep.Guid)
    if (-not (Test-Path $file)) { return $null }
    return (Get-Content $file -Raw | ConvertFrom-Json)
}

function Restore-Fx($ep) {
    $bk = Load-Backup $ep
    if (-not $bk) { Write-Fail "[错误] 没有 $($ep.Name) 的备份。"; return }
    $fx = Join-Path $ep.Key 'FxProperties'
    if (-not (Test-Path $fx)) { try { New-Item -ItemType Directory -Path $fx -Force | Out-Null } catch { } }
    foreach ($kv in $bk.values) {
        $cur = Get-ItemProperty $fx -ErrorAction SilentlyContinue
        if ($cur.PSObject.Properties.Name -contains $kv.n) {
            Remove-RegValue (To-KeyPath $fx) $kv.n
        }
        if ($kv.d.Count -gt 0) {
            Set-RegMulti (To-KeyPath $fx) $kv.n @($kv.d)
        }
    }
    Write-Ok   "[完成] 已从备份恢复 $($ep.Name) 的 FX 链。"
    Write-Warn "       重启电脑或重启 Windows Audio 服务后生效。"
}

function Add-DolbyToEp($ep) {
    $fx = Join-Path $ep.Key 'FxProperties'
    if (-not (Test-Path $fx)) { try { New-Item -ItemType Directory -Path $fx -Force | Out-Null } catch { } }
    $map = Get-FxValues $ep.Key
    Save-Backup $ep $map | Out-Null
    $slot = $FX_STREAM
    $cur = $null
    if ($map.ContainsKey($slot)) { $cur = $map[$slot] }
    # PKEY_FX_StreamEffectClsid 是单值 CLSID（Windows 原生格式=REG_SZ）。
    # 旧实现用 REG_MULTI_SZ 会在 audiodg 重建端点图时被规范化丢弃 → 杜比挂接丢失。
    if ($cur -is [array]) { $cur = @($cur)[0] }
    $curStr = if ($null -ne $cur) { "$cur" } else { '' }
    if ($curStr -and $curStr -ne $DOLBY_CLSID) {
        Set-RegString (To-KeyPath $fx) $slot $DOLBY_CLSID
        Write-Ok   "  $slot 由 [$curStr] 替换为 $DOLBY_CLSID (REG_SZ)"
    } elseif (-not $curStr) {
        Set-RegString (To-KeyPath $fx) $slot $DOLBY_CLSID
        Write-Ok   "  $slot <= $DOLBY_CLSID (REG_SZ)"
    } else {
        Write-Ok   "  $slot 已是 $DOLBY_CLSID，无需重复挂接"
    }
    Write-Ok   "[完成] 已给 $($ep.Name) 挂上 Dolby APO（StreamEffect 槽）。"
    Write-Warn "       重启电脑（或重启 Windows Audio 服务/audiodg）后生效。"
    Write-Warn "       若该端点无声/异常，运行: APOHook.ps1 -Restore \"$($ep.Guid)\" 恢复。"
}

function Remove-DolbyFromEp($ep) {
    $fx = Join-Path $ep.Key 'FxProperties'
    if (-not (Test-Path $fx)) { Write-Warn "  该端点没有 FxProperties。"; return }
    $map = Get-FxValues $ep.Key
    $slot = $FX_STREAM
    if (-not $map.ContainsKey($slot)) { Write-Warn "  该端点没有 StreamEffect 链。"; return }
    $cur = $map[$slot]
    if ($cur -is [array]) { $cur = @($cur)[0] }
    if ("$cur" -eq $DOLBY_CLSID) {
        Remove-RegValue (To-KeyPath $fx) $slot
        Write-Ok   "  $slot 已移除（恢复原状请用 -Restore）。"
    } else {
        Write-Warn "  $slot 当前不是杜比（$cur），无需移除。"
    }
    Write-Ok   "[完成] 已从 $($ep.Name) 移除 Dolby APO。重启后生效。"
}

if ($List) { Show-List; exit 0 }

# ---- 全局 DaxExtFolder 兜底：给 MEDIA 类全部音频设备实例写调音目录 ----
function Set-TuningAll {
    Write-Host ""
    Write-Head "---- 全局 DaxExtFolder 兜底（MEDIA 类全部音频设备实例）----"
    if (-not (Test-Path $TUNING_DIR)) { Write-Fail "[错误] 调音目录不存在: $TUNING_DIR（先运行 Setup-Dolby.ps1）"; return }
    $changed = 0
    foreach ($i in (Get-ChildItem $MEDIA_CLASS -ErrorAction SilentlyContinue)) {
        $n = $i.PSChildName
        if ($n -notmatch '^\d+$') { continue }   # 跳过 Configuration 等非实例键
        $p = Get-ItemProperty $i.PSPath -ErrorAction SilentlyContinue
        $mid = $p.MatchingDeviceId
        $cur = $p.DaxExtFolder
        if ($mid -and -not $cur) {
            Set-ItemProperty -Path $i.PSPath -Name 'DaxExtFolder' -Value $TUNING_DIR -ErrorAction SilentlyContinue
            Write-Ok   "  $n  $mid  => DaxExtFolder=$TUNING_DIR"
            $changed++
        } elseif ($cur) {
            Write-Host "  $n  $mid  (已有 DaxExtFolder=$cur，跳过)"
        }
    }
    if ($changed -eq 0) { Write-Warn "  没有需要写入的实例（都已写好或无法识别）。" }
    Write-Ok   "[完成] 已写 $changed 个设备实例的 DaxExtFolder。"
    Write-Warn "       之后把 Dolby APO 挂到这些设备的端点（-Add）即可。重启电脑后生效。"
}

function Remove-TuningAll {
    Write-Host ""
    Write-Head "---- 删除全局 DaxExtFolder（恢复原状）----"
    $removed = 0
    foreach ($i in (Get-ChildItem $MEDIA_CLASS -ErrorAction SilentlyContinue)) {
        $n = $i.PSChildName
        if ($n -notmatch '^\d+$') { continue }
        $p = Get-ItemProperty $i.PSPath -ErrorAction SilentlyContinue
        if ($p.DaxExtFolder) {
            if ($p.MatchingDeviceId -match 'VEN_10EC') { Write-Host "  $n  保留（Realtek 主设备，由 Setup-Dolby 管理）。"; continue }
            Remove-ItemProperty -Path $i.PSPath -Name 'DaxExtFolder' -ErrorAction SilentlyContinue
            Write-Ok   "  $n  $($p.MatchingDeviceId)  DaxExtFolder 已删除"
            $removed++
        }
    }
    Write-Ok   "[完成] 已删除 $removed 个实例的 DaxExtFolder。"
}

if ($TuningAll)       { Set-TuningAll; exit 0 }
if ($TuningRemoveAll) { Remove-TuningAll; exit 0 }

if ($AddAll) {
    $eps = Get-RenderEndpoints | Where-Object { $_.State -eq 1 }
    if (-not $eps) { Write-Fail "[错误] 没有激活的渲染端点。"; exit 1 }
    Write-Warn "将给以下激活端点全部挂 Dolby APO（先备份）："
    $eps | ForEach-Object { Write-Host "  - $($_.Name)  $($_.Guid)" }
    foreach ($ep in $eps) { Add-DolbyToEp $ep }
    exit 0
}

if ($Add -or $Remove -or $Restore) {
    $target = if ($Add) { $Add } elseif ($Remove) { $Remove } else { $Restore }
    $ep = Find-Endpoint $target
    if (-not $ep) { Write-Fail "[错误] 找不到匹配 '$target' 的端点。用 -List 看全部。"; exit 1 }
    Write-Host "目标端点: $($ep.Name)  $($ep.Guid)"
    if ($Add)    { Add-DolbyToEp $ep }
    if ($Remove) { Remove-DolbyFromEp $ep }
    if ($Restore){ Restore-Fx $ep }
    exit 0
}
