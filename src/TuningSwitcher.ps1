#requires -version 5.1
<#
  TuningSwitcher.ps1 - 杜比 DAX3 调音切换工具（切换 / 备份 / 恢复）

  作用：
    1) 检测本机 Realtek 音频设备的硬件 ID (DEV/SUBSYS)；
    2) 找到已安装的杜比调音目录（DriverStore 里的 dax3_ext 包文件夹）；
    3) 列出本机当前生效的调音，以及包里全部 239 个机型调音供挑选；
    4) 切换：把选中的调音文件替换成本机硬件 ID 对应的文件名（自动备份），
       重启 DolbyDAXAPI 服务使新调音生效；
    5) 恢复原调音。

  用法（需要管理员，切换要写 DriverStore 和重启服务）：
    powershell -ExecutionPolicy Bypass -File TuningSwitcher.ps1 -List
    powershell -ExecutionPolicy Bypass -File TuningSwitcher.ps1 -Switch "DEV_0257_SUBSYS_17AA3985_PCI_SUBSYS_380617AA.xml"
    powershell -ExecutionPolicy Bypass -File TuningSwitcher.ps1 -Restore
    powershell -ExecutionPolicy Bypass -File TuningSwitcher.ps1 -Check

  注意：
    每个调音文件内含 security-key，绑定到某个具体硬件 ID。若 DAX3 运行时校验
    security-key 与本机硬件 ID 是否一致，则跨机型切换会被拒绝并回落到默认调音。
    本工具用于实测这一点；切换后用声音/EQ 是否变化来判断是否生效。

  English summary:
    Dolby DAX3 tuning switcher (switch / backup / restore).
    1) detect the machine's Realtek hardware ID (DEV/SUBSYS);
    2) locate the installed tuning directory and the package tuning folder (auto-found);
    3) list current tuning + all package tunings (key-less [空key] switchable anywhere);
    4) switch: copy the chosen tuning to the machine-named file (auto-backup), restart DolbyDAXAPI;
       BOUND tunings (non-empty security-key) are auto-converted to key-less on write, so DAX3
       will not reject them on a different machine; use -KeepKey to keep the original key.
    5) restore the original.
    Usage: TuningSwitcher.ps1 -List | -Switch <file.xml> [-KeepKey] | -Restore | -Check   (admin; reboot to take effect)
#>
param(
    [switch]$List,       # 列出全部可用调音 + 当前生效调音
    [switch]$Check,      # 只检查本机状态，不做修改
    [string]$Switch,     # 切换：传入要启用的调音文件名（见 -List 输出）
    [switch]$KeepKey,    # 切换时保留原 security-key（默认清空转空key通用，避免被 DAX3 拒绝）
    [switch]$Restore,    # 恢复切换前的原调音
    [switch]$UsbTarget,  # 目标为 USB/蓝牙等非 Realtek 设备：切换/恢复/列表作用于通用调音文件
                         # （Headphone_Default_Generic_Default_DolbyAtmosSpeakerSystem.xml）
                         # USB 设备不匹配 DEV_*_SUBSYS_*.xml，DAX3 回退用该通用调音。
    [switch]$ListUsb,    # 仅显示当前 USB 通用调音内容（哪个机型），不改动
    [string]$PackageRoot = ''   # 包根：内联执行由 exe 传 DM_BASE 环境变量；文件执行时自动定位
)
# 包根：内联执行（DM_BASE 进程环境变量）优先，否则文件自定位 / embedded run: DM_BASE env var; file run: auto-locate
if (-not $PackageRoot) { $PackageRoot = if ($env:DM_BASE) { $env:DM_BASE } else { Split-Path -Parent $MyInvocation.MyCommand.Path } }
$ErrorActionPreference = 'Stop'
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

function Write-Ok   ($m) { Write-Host $m -ForegroundColor Green }
function Write-Warn ($m) { Write-Host $m -ForegroundColor Yellow }
function Write-Fail ($m) { Write-Host $m -ForegroundColor Red }
function Write-Head ($m) { Write-Host $m -ForegroundColor Cyan }

Write-Head "=========================================================="
Write-Head " 杜比 DAX3 调音切换工具"
Write-Head "=========================================================="

# ---- 1. 检测本机 Realtek 设备 ----
$dev = $null
try {
    $dev = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object {
        $_.InstanceId -match 'HDAUDIO|INTELAUDIO' -and $_.InstanceId -match 'VEN_10EC'
    } | Select-Object -First 1
} catch { }
if (-not $dev) {
    Write-Fail "[错误] 未检测到 Realtek (VEN_10EC) 音频设备。"
    exit 1
}
$devId  = $dev.InstanceId
$devVal = [regex]::Match($devId, 'DEV_([0-9A-F]{4})').Groups[1].Value
$subsys = [regex]::Match($devId, 'SUBSYS_([0-9A-F]{8})').Groups[1].Value
Write-Host "设备     : $($dev.FriendlyName)  [$($dev.Status)]"
Write-Host "硬件ID   : $devId"
Write-Host ("解析     : DEV={0}  SUBSYS={1}" -f $devVal, $subsys)
if (-not $devVal -or -not $subsys) { Write-Fail "[错误] 无法解析 DEV/SUBSYS"; exit 1 }

# ---- 2. 定位已安装的杜比调音目录（Setup-Dolby 写到设备实例 DaxExtFolder，通常是 C:\Windows\System32\dolbyaposvc）----
function Get-TuningDir {
    # 1) 设备实例上的 DaxExtFolder（最权威：免签名方案写这里）
    $clsKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e96c-e325-11ce-bfc1-08002be10318}'
    if (Test-Path $clsKey) {
        foreach ($i in (Get-ChildItem $clsKey -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty $i.PSPath -ErrorAction SilentlyContinue
            if ($p.MatchingDeviceId -match 'VEN_10EC' -and $p.DaxExtFolder -and (Test-Path $p.DaxExtFolder)) {
                return Get-Item $p.DaxExtFolder
            }
        }
    }
    # 2) 常见部署目录
    foreach ($cand in @('C:\Windows\System32\dolbyaposvc',
                        'C:\Program Files\Dolby\DAX3',
                        'C:\Program Files (x86)\Dolby\DAX3')) {
        if (Test-Path $cand) { return Get-Item $cand }
    }
    # 3) DriverStore 里的 dax3_ext 包（联想驱动正规安装路径）
    return (Get-ChildItem 'C:\Windows\System32\DriverStore\FileRepository' -Directory -Filter 'dax3_ext_rtk.inf*' -ErrorAction SilentlyContinue | Select-Object -First 1)
}
$tunDir = Get-TuningDir
if (-not $tunDir) {
    Write-Warn "[警告] 未找到杜比调音目录（DaxExtFolder / dolbyaposvc / DriverStore 均无）。"
    Write-Warn "       请先运行 Setup-Dolby.ps1（或 Setup.cmd）安装杜比后再切换调音。"
}

# ---- USB/蓝牙 等非 Realtek 设备的通用调音文件（DAX3 回退目标）----
# 实测（DAX3API 内存 dump）：USB 设备（无 DEV_*_SUBSYS 匹配）由 DAX3 回退加载
# Headphone_Default_Generic_Default_DolbyAtmosSpeakerSystem.xml。
# 因此给 USB 设备"切换调音" = 把选中的机型调音内容（空 key）写进该通用调音文件。
$USB_GENERIC = 'Headphone_Default_Generic_Default_DolbyAtmosSpeakerSystem.xml'
$usbGenericFile = $null
if ($tunDir) { $usbGenericFile = Join-Path $tunDir.FullName $USB_GENERIC }

function Get-UsbGenericInfo {
    # 返回 USB 通用调音文件的当前信息：存在性 + 内容机型匹配（归一哈希 vs 包内 DEV_*.xml）
    if (-not $usbGenericFile -or -not (Test-Path $usbGenericFile)) {
        return [pscustomobject]@{ Exists = $false; Size = 0; MatchName = ''; MatchModel = '' }
    }
    $norm = Get-NormHash $usbGenericFile
    $matchName = ''; $matchModel = ''
    foreach ($f in (Get-Tunings $tunDir.FullName)) {
        if ((Get-NormHash $f.FullName) -eq $norm) { $matchName = $f.Name; break }
    }
    if ($matchName) {
        $m = [regex]::Match($matchName, '^DEV_([0-9A-Fa-f]{4})_SUBSYS_([0-9A-Fa-f]{8})')
        if ($m.Success) {
            $subsys = $m.Groups[2].Value
            $names = Get-Content (Join-Path $PackageRoot 'Data\TuningNames.txt') -Encoding UTF8 -ErrorAction SilentlyContinue
            foreach ($line in $names) {
                $parts = $line -split "`t"
                if ($parts.Count -ge 2 -and $parts[0].Trim().ToUpperInvariant() -eq $subsys) { $matchModel = $parts[1].Trim(); break }
            }
        }
    }
    return [pscustomobject]@{ Exists = $true; Size = (Get-Item $usbGenericFile).Length; MatchName = $matchName; MatchModel = $matchModel }
}

function Get-NormHash([string]$path) {
    # 归一哈希：security-key 置空后 SHA256 前 16 位（机型内容识别）
    $c = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
    $c = [regex]::Replace($c, '<security-key value="[^"]*"', '<security-key value=""')
    $sha = [Security.Cryptography.SHA256]::Create()
    $bytes = [Text.Encoding]::UTF8.GetBytes($c)
    return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').Substring(0, 16)
}

function Test-UsbDolbyActive {
    # 自动目标判断：本机是否有「激活且挂了 Dolby APO」的 USB/蓝牙端点。
    # 有 → 默认把切换/恢复作用于 USB 通用调音；无 → 走 Realtek DEV_*。
    # Returns: $true if an active USB/BT endpoint has the Dolby wrapper attached.
    $R = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render'
    $fxKey = '{D04E05A6-594B-4FB6-A80D-01AF5EED7D1D},5'
    $hwKey = '{b3f8fa53-0004-438e-9003-51a46e139bfc},6'
    $ifKey = '{a45c254e-df1c-4efd-8020-67d146a850e0},24'
    $dolbyCls = '{0EBD8505-17BB-4AE7-AD76-E86F99A425E9}'
    try {
        foreach ($ep in (Get-ChildItem $R -ErrorAction SilentlyContinue)) {
            $st = (Get-ItemProperty $ep.PSPath -ErrorAction SilentlyContinue).DeviceState
            if ($st -ne 1) { continue }
            $fx = Get-ItemProperty "$($ep.PSPath)\FxProperties" -ErrorAction SilentlyContinue
            if (-not $fx) { continue }
            $fxv = $fx.$fxKey
            if ($null -eq $fxv) { continue }
            $fxvs = if ($fxv -is [array]) { $fxv -join ';' } else { "$fxv" }
            if ($fxvs -notmatch [regex]::Escape($dolbyCls)) { continue }
            $props = Get-ItemProperty "$($ep.PSPath)\Properties" -ErrorAction SilentlyContinue
            $ifc = "$($props.$ifKey)"
            $hw  = "$($props.$hwKey)"
            if ($ifc -match '^USB|^BTH' -or $hw -match 'USB|Bluetooth|BTH') { return $true }
        }
    } catch { }
    return $false
}
# 动态定位包内调音目录：Drivers 全树下第一个含 DEV_*.xml 的目录
# （布局无关：Drivers\ThirdParty\ext 或 Drivers\ext 均可，不硬编码包名）
$pkgTunDir = $null
$drvRoot = Join-Path $PackageRoot 'Drivers'
if (Test-Path $drvRoot) {
    $pkgTunDir = Get-ChildItem $drvRoot -Directory -Recurse -ErrorAction SilentlyContinue |
        Where-Object { @(Get-ChildItem $_.FullName -Filter 'DEV_*.xml' -ErrorAction SilentlyContinue).Count -gt 0 } |
        Select-Object -First 1 | ForEach-Object { $_.FullName }
}

# ---- 3. 本机期望的调音文件名模式 ----
$pattern = "DEV_${devVal}_SUBSYS_${subsys}*"
Write-Host ("本机调音匹配模式: {0}" -f $pattern)

function Get-Tunings($dir) {
    # 只取真调音：排除 *_settings.xml（联想包内的 <Config> 设置文件，非调音）
    if (-not $dir -or -not (Test-Path $dir)) { return @() }
    Get-ChildItem $dir -File -Filter 'DEV_*.xml' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch '_settings\.xml$' }
}

$installed = @()
$active = @()
if ($tunDir) {
    $installed = Get-Tunings $tunDir.FullName
    $active    = @($installed | Where-Object { $_.Name -like $pattern })
    Write-Host "已安装调音目录 : $($tunDir.FullName)"
    Write-Host "已安装调音数量 : $($installed.Count)"
    Write-Host ("当前生效调音   : " + ($(if ($active) { ($active | ForEach-Object Name) -join ', ' } else { '（未匹配，可能走默认调音）' })))
} else {
    Write-Host "已安装调音目录 : （未找到）"
}

$pkgTunings = Get-Tunings $pkgTunDir
Write-Host "包内调音数量   : $($pkgTunings.Count)"

# ---- 4. 检查 security-key 与本机硬件 ID 的关系 ----
Write-Host ""
Write-Head "---- security-key 检查 ----"
function Get-KeyEmpty($file) {
    try {
        $c = Get-Content $file.FullName -Raw -Encoding UTF8
        $m = [regex]::Match($c, '<security-key value="([^"]*)"')
        if (-not $m.Success) { return $null }
        return $m.Groups[1].Value.Length -eq 0
    } catch { return $null }
}
$ownKey = $null
if ($active) {
    try {
        $xm = [xml](Get-Content $active[0].FullName -Raw)
        $ownKey = $xm.device_data.setting.'security-key'.value
    } catch { }
}
if ($ownKey) {
    $keyDevice = ([regex]::Match($ownKey, '^(HDAUDIO[^=]+)')).Groups[1].Value
    Write-Host ("当前调音的 security-key 硬件ID: {0}" -f $keyDevice)
    $idNorm = $devId.ToUpperInvariant()
    if ($keyDevice.ToUpperInvariant() -eq $idNorm) {
        Write-Ok   "  -> 与本机硬件 ID 一致：本机可正常使用该调音。"
    } else {
        Write-Warn "  -> 与 hardware ID 不一致。若切换其他机型调音，DAX3 可能据此拒绝加载（需实测）。"
    }
} else {
    if ($active) {
        $ke = Get-KeyEmpty $active[0]
        if ($ke -eq $true) { Write-Ok   "  当前调音 security-key 为空（无硬件绑定），切换可自由生效。" }
        elseif ($ke -eq $false) { Write-Warn "  当前调音带 security-key 绑定。" }
        else { Write-Warn "  当前调音无 security-key 标签。" }
    } else {
        Write-Warn "  当前无匹配本机的机型调音（DAX3 走 Default.xml 默认调音）。"
        Write-Host "  提示：包内 236 个机型调音中大部分 security-key 为空（无绑定），可自由切换；"
        Write-Host "        带 key 的绑定机型调音（-List 中标 [绑定]）切换时也会自动转为空key通用调音，不会被拒。"
    }
}

# ---- 5. 列出可选调音 ----
if ($ListUsb) {
    Write-Host ""
    Write-Head "---- USB/蓝牙 通用调音（Headphone_Default_Generic_Default_DolbyAtmosSpeakerSystem.xml）----"
    $info = Get-UsbGenericInfo
    if (-not $info.Exists) {
        Write-Fail "[错误] 通用调音文件不存在: $USB_GENERIC（调音目录: $($tunDir.FullName)）"
        exit 1
    }
    Write-Host "文件     : $usbGenericFile"
    Write-Host "大小     : $($info.Size) 字节"
    if ($info.MatchName) {
        Write-Ok   "当前内容 : 匹配机型调音 $($info.MatchName)  $($info.MatchModel)"
    } else {
        Write-Warn "当前内容 : （未匹配到包内机型调音，可能为 DAX3 出厂通用内容）"
    }
    Write-Host ""
    Write-Host "切换方法: TuningSwitcher.ps1 -Switch <机型调音文件名> -UsbTarget"
    Write-Host "恢复方法: TuningSwitcher.ps1 -Restore -UsbTarget"
    exit 0
}

if ($List) {
    Write-Host ""
    Write-Head "---- 包内全部可切换调音（共 $($pkgTunings.Count) 个；[空key] 无绑定自由切，[绑定] 切换时自动转空key通用）----"
    $pkgTunings | Sort-Object Name | ForEach-Object {
        $mark = if ($active -and $active.Name -contains $_.Name) { '  <-- 当前生效' } else { '' }
        $ke = Get-KeyEmpty $_
        $tag = if ($ke -eq $true) { '  [空key]' } elseif ($ke -eq $false) { '  [绑定]' } else { '  [无key标签]' }
        Write-Host ("  {0}{1}{2}" -f $_.Name, $tag, $mark)
    }
    exit 0
}

# ---- 6. 切换 / 恢复 ----
if ($Restore) {
    if (-not $IsAdmin) { Write-Fail "[错误] 恢复需要管理员权限，请以管理员运行。"; exit 1 }
    if (-not $tunDir)  { Write-Fail "[错误] 未找到已安装调音目录。"; exit 1 }
    # 自动目标：未显式指定 -UsbTarget 时，若本机有激活的 USB Dolby 端点 → 恢复 USB 通用调音
    $autoUsb = $UsbTarget
    if (-not $UsbTarget) { $autoUsb = Test-UsbDolbyActive }
    if ($autoUsb) {
        # ---- USB 目标：恢复通用调音文件 ----
        $bk = "$usbGenericFile.bak"
        if (Test-Path $bk) {
            Copy-Item $bk $usbGenericFile -Force
            Write-Ok   "  已恢复: $USB_GENERIC <- $($bk)"
        } else {
            Write-Warn "  [提示] 没有 USB 通用调音备份（$USB_GENERIC.bak），跳过。"
        }
        Restart-Service DolbyDAXAPI -Force -ErrorAction SilentlyContinue
        Write-Ok "[完成] 已恢复 USB 通用调音并重启 DolbyDAXAPI 服务。"
        Write-Warn "       重启电脑（或设备管理器禁用再启用音频设备）使 audiodg 重新加载后再听效果。"
        exit 0
    }
    $bk = Get-ChildItem $tunDir.FullName -File -Filter '*.bak' -ErrorAction SilentlyContinue
    if (-not $bk) { Write-Warn "[提示] 没有找到备份，无法恢复。"; exit 0 }
    foreach ($b in $bk) {
        $orig = $b.FullName -replace '\.bak$',''
        Copy-Item $b.FullName $orig -Force
        Write-Ok   "  已恢复: $($b.Name)"
    }
    Restart-Service DolbyDAXAPI -Force -ErrorAction SilentlyContinue
    Write-Ok "[完成] 已恢复原调音并重启 DolbyDAXAPI 服务。"
    Write-Warn "       重启电脑（或设备管理器禁用再启用音频设备）使 audiodg 重新加载后再听效果。"
    exit 0
}

if ($Switch) {
    if (-not $IsAdmin) { Write-Fail "[错误] 切换需要管理员权限，请以管理员运行。"; exit 1 }
    if (-not $tunDir)  { Write-Fail "[错误] 未找到已安装调音目录。"; exit 1 }
    $src = $pkgTunings | Where-Object { $_.Name -eq $Switch }
    if (-not $src) {
        # 也允许传入完整路径
        $src = if (Test-Path $Switch) { Get-Item $Switch } else { $null }
    }
    if (-not $src) { Write-Fail "[错误] 找不到调音文件: $Switch（用 -List 查看可用列表）"; exit 1 }

    Write-Host ("切换来源 : {0}" -f $src.FullName)

    # 读取源调音内容；带绑定 key 的调音跨机型会被 DAX3 拒绝加载，默认转为空key 通用调音写入
    # （源文件保持原样不动，备份/恢复仍可用；-KeepKey 可保留原 key 原样实测）
    $srcContent = Get-Content $src.FullName -Raw -Encoding UTF8
    $keyMatch = [regex]::Match($srcContent, '<security-key value="([^"]+)"')
    if ($keyMatch.Success -and -not $KeepKey) {
        $srcContent = [regex]::Replace($srcContent, '(<security-key\b[^>]*?\bvalue=")[^"]*(")', '$1$2')
        Write-Warn "  该调音带 security-key 绑定（DAX3 会拒绝跨机型加载），已将【写入内容】转为空key 通用调音（任意机器可切换）。"
        Write-Host "        源文件未改动；若想保留原 key 原样切换实测，用 -KeepKey 参数。"
    } elseif ($keyMatch.Success) {
        Write-Warn "  已按 -KeepKey 保留原 security-key 绑定（绑定 $($src.Name) 的机型），DAX3 可能拒绝加载，需实测。"
    }

    # ---- 目标选择：显式 -UsbTarget 优先；否则自动判断（有激活的 USB Dolby 端点 → USB 通用调音）----
    if (-not $UsbTarget -and (Test-UsbDolbyActive)) {
        $UsbTarget = $true
        Write-Host ""
        Write-Warn "[自动] 检测到激活的 USB/蓝牙端点挂了杜比（MBQUART 等），本次切换作用于 USB 通用调音。"
    }
    if ($UsbTarget) {
        # ---- USB 目标：写入通用调音文件（MBQUART 等 USB/蓝牙设备实际加载的文件）----
        if (-not $usbGenericFile -or -not (Test-Path $usbGenericFile)) {
            Write-Fail "[错误] USB 通用调音文件不存在: $USB_GENERIC"
            exit 1
        }
        Copy-Item $usbGenericFile "$usbGenericFile.bak" -Force
        Write-Host "  已备份: $USB_GENERIC -> .bak"
        [System.IO.File]::WriteAllText($usbGenericFile, $srcContent, (New-Object System.Text.UTF8Encoding($false)))
        Write-Ok   "  已写入: $usbGenericFile"
        Restart-Service DolbyDAXAPI -Force -ErrorAction SilentlyContinue
        Write-Ok ""
        Write-Ok "[完成] 已切换调音（USB 目标）并重启 DolbyDAXAPI 服务。"
        Write-Warn "       重要：调音由 audiodg 进程加载，需重启电脑（或设备管理器-禁用再启用音频设备）才能生效。"
        Write-Warn "       重启后播放音乐测试：若声音/EQ 明显变化则切换生效；若与默认相同，说明 DAX3 拒绝加载。"
        Write-Warn "       恢复: TuningSwitcher.ps1 -Restore"
        exit 0
    }

    # 备份当前生效调音
    foreach ($a in $active) {
        Copy-Item $a.FullName "$($a.FullName).bak" -Force
        Write-Host "  已备份: $($a.Name) -> .bak"
    }
    # 用目标调音覆盖本机期望文件名
    $targets = @()
    if ($active) {
        $targets = $active | ForEach-Object { $_.FullName }
    } else {
        # 没有本机匹配文件：按包内命名规则生成本机名
        $newName = "DEV_${devVal}_SUBSYS_${subsys}_PCI_SUBSYS_00000000.xml"
        $targets = @(Join-Path $tunDir.FullName $newName)
    }
    foreach ($t in $targets) {
        [System.IO.File]::WriteAllText($t, $srcContent, (New-Object System.Text.UTF8Encoding($false)))
        Write-Ok   "  已写入: $t"
    }
    Restart-Service DolbyDAXAPI -Force -ErrorAction SilentlyContinue
    Write-Ok ""
    Write-Ok "[完成] 已切换调音并重启 DolbyDAXAPI 服务。"
    Write-Warn "       重要：调音由 audiodg 进程加载，需重启电脑（或设备管理器-禁用再启用音频设备）才能生效。"
    Write-Warn "       重启后播放音乐测试：若声音/EQ 明显变化则切换生效；若与默认相同，说明 DAX3 拒绝加载"
    Write-Warn "       （仅当用 -KeepKey 保留了绑定 security-key 时才会发生），此时用 -Restore 恢复。"
    exit 0
}

# ---- 默认：检查状态 ----
Write-Host ""
Write-Head "---- 结论 ----"
if ($active) {
    Write-Ok   "[状态] 本机杜比调音已安装并生效（匹配机型）。"
    Write-Host "       切换其他机型调音：  TuningSwitcher.ps1 -List  （先看有哪些）"
    Write-Host "       然后：              TuningSwitcher.ps1 -Switch <文件名>"
    Write-Host "       恢复：              TuningSwitcher.ps1 -Restore"
} else {
    Write-Warn "[状态] 本机没有匹配的机型调音文件（当前为默认调音）。"
    Write-Warn "       仍可尝试切换任意机型调音测试 DAX3 是否校验 security-key："
    Write-Host "       TuningSwitcher.ps1 -List"
    Write-Host "       TuningSwitcher.ps1 -Switch <文件名>"
}
