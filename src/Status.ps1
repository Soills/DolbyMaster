#requires -version 5.1
<#
  Status.ps1 - 杜比管家首页状态总览 / DolbyMaster home status overview (app + config)
  输出结构化行供 DolbyMaster.exe 首页渲染成仪表盘。
  Emits structured lines rendered as a dashboard by DolbyMaster.exe:
    @@TITLE@@ 标题 / title
    @@META@@  机器信息 / machine info
    @@ROW@@ 状态|名称|详情   状态: OK / WARN / ERR / INFO
    @@TIP@@  提示行 / tip line
  用法 / Usage: Status.ps1 [-Lang zh|en]
#>
param([string]$Lang = 'zh')
$ErrorActionPreference = 'SilentlyContinue'

# 双语 / bilingual helper
function L($zh, $en) { if ($Lang -eq 'en') { $en } else { $zh } }

function ROW($st, $label, $detail) { Write-Host "@@ROW@@ $st|$label|$detail" }
function OK($l, $d)  { ROW 'OK'   $l $d }
function WN($l, $d)  { ROW 'WARN' $l $d }
function ER($l, $d)  { ROW 'ERR'  $l $d }
function IN($l, $d)  { ROW 'INFO' $l $d }

Write-Host ("@@TITLE@@ " + (L '杜比管家 · 状态总览' 'DolbyMaster · Status Overview'))
$os = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
$osName = if ($os.ProductName) { $os.ProductName } else { 'Windows' }
$osVer  = if ($os.DisplayVersion) { $os.DisplayVersion } else { [System.Environment]::OSVersion.Version.ToString() }
Write-Host ("@@META@@ " + (L '本机' 'Machine') + ": $env:COMPUTERNAME · $osName $osVer (build $($os.CurrentBuildNumber))")

# ---------- 1. Realtek 声卡（收集全部实例） / Realtek codec (collect all instances) ----------
$MEDIA = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e96c-e325-11ce-bfc1-08002be10318}'
$rtkList = @()
Get-ChildItem $MEDIA -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^\d+$' } | ForEach-Object {
    $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
    if ($p.MatchingDeviceId -match 'VEN_10EC') {
        $rtkList += [pscustomobject]@{ Path = $_.PSPath; Instance = $_.PSChildName; Mid = $p.MatchingDeviceId; Dax = $p.DaxExtFolder }
    }
}
$dev = '?'; $sub = '?'
if ($rtkList.Count -gt 0) {
    if ($rtkList[0].Mid -match 'DEV_([0-9A-Fa-f]{4})') { $dev = $Matches[1].ToUpper() }
    # SUBSYS 补全：MatchingDeviceId 通常没有 SUBSYS，从音频 PnP 实例路径补（HDAUDIO/INTELAUDIO，避免抓到网卡）
    # Fill SUBSYS from audio PnP instance paths (HDAUDIO/INTELAUDIO only, avoid picking up the NIC).
    try { Get-PnpDevice -ErrorAction Stop | Where-Object { $_.InstanceId -match '(HDAUDIO|INTELAUDIO).*VEN_10EC.*SUBSYS_([0-9A-Fa-f]{8})' } | Select-Object -First 1 | ForEach-Object {
        if ($_.InstanceId -match 'SUBSYS_([0-9A-Fa-f]{8})') { $sub = $Matches[1].ToUpper() }
    } } catch { }
    $subTxt = if ($sub -and $sub -ne '?') { "SUBSYS_$sub" } else { (L '(SUBSYS 未读取)' '(SUBSYS unknown)') }
    OK (L '声卡识别' 'Codec') ("Realtek DEV_$dev · $subTxt · $($rtkList.Count) " + (L '个实例' 'instance(s)') + " ($($rtkList.Instance -join '/'))")
} else { ER (L '声卡识别' 'Codec') (L '未检测到 Realtek (VEN_10EC) 声卡（杜比调音依赖 Realtek）' 'No Realtek (VEN_10EC) codec detected (Dolby tunings require Realtek)') }

# ---------- 2. DAX3 组件目录（调音明细走快扫缓存） / DAX3 component dir (details from fast cache) ----------
$dir = 'C:\Windows\System32\dolbyaposvc'
$apodll = Join-Path $dir 'DolbyDax3Apo.dll'
if (Test-Path $dir) {
    $n = (Get-ChildItem $dir -File).Count
    $tun = Get-ChildItem $dir -Filter 'DEV_*.xml' | Where-Object { $_.Name -notmatch '_settings\.xml$' } | Measure-Object
    $empty = $null; $bound = $null
    # 包根：内联执行（DM_BASE 进程环境变量）优先；文件执行用 $PSScriptRoot / embedded run: DM_BASE env var first
    $baseDir = if ($env:DM_BASE) { $env:DM_BASE } else { $PSScriptRoot }
    $cacheF = Join-Path $baseDir 'Data\TuningCache.txt'
    if (Test-Path $cacheF) {
        $empty = 0; $bound = 0
        Get-Content $cacheF -Encoding UTF8 | ForEach-Object { if ($_ -match '\[空key\]$') { $empty++ } elseif ($_ -match '\[绑定\]$') { $bound++ } }
    }
    $state = 'OK'; $note = "$n " + (L '个文件' 'files') + " · $($tun.Count) " + (L '个调音' 'tunings')
    if ($empty -ne $null) { $note += (L "（空key 可自由切换 $empty / 绑定 $bound）" " (key-less switchable $empty / bound $bound)") } else { $note += (L '（进「切换调音」页后显示空key/绑定明细）' ' (open Tuning tab to see key-less/bound details)') }
    if (-not (Test-Path $apodll)) { $state = 'ERR'; $note += (L ' · 缺少 DolbyDax3Apo.dll！' ' · DolbyDax3Apo.dll missing!') }
    ROW $state (L 'DAX3 组件' 'DAX3 components') $note
} else { ER (L 'DAX3 组件' 'DAX3 components') (L '目录不存在 - 未安装或已损坏（跑「安装」页）' 'dir missing - not installed or broken (run Install tab)') }

# ---------- 3. APO COM 注册 / APO COM registration ----------
$cls = 'Registry::HKEY_CLASSES_ROOT\CLSID'
$eng = 'Registry::HKEY_CLASSES_ROOT\AudioEngine\AudioProcessingObjects'
$dolbyAp = 0
Get-ChildItem $eng -ErrorAction SilentlyContinue | ForEach-Object {
    $srv = (Get-Item "$cls\$($_.PSChildName)\InprocServer32" -ErrorAction SilentlyContinue).GetValue('')
    if ($srv -match 'dolbyaposvc') { $dolbyAp++ }
}
if ($dolbyAp -gt 0) { OK (L 'APO 注册' 'APO registration') ("Dolby APO " + (L '对象' 'objects') + " $dolbyAp " + (L '个（指向 dolbyaposvc）' '(pointing to dolbyaposvc)')) }
else { ER (L 'APO 注册' 'APO registration') (L 'Dolby APO 对象未注册（跑「安装」页安装杜比）' 'Dolby APO objects not registered (run Install tab)') }
$clsidDolby = (Get-Item "$cls\{0EBD8505-17BB-4AE7-AD76-E86F99A425E9}\InprocServer32" -ErrorAction SilentlyContinue).GetValue('')
if ($clsidDolby -match 'dolbyaposvc') { OK (L 'APO 包装器' 'APO wrapper') ("CLSID " + (L '已注册' 'registered') + " → $clsidDolby") }
else { ER (L 'APO 包装器' 'APO wrapper') (L 'Dolby APO 包装器 CLSID 缺失（跑「安装」页）' 'Dolby APO wrapper CLSID missing (run Install tab)') }

# ---------- 4. 服务（自启 + 路径） / Service (autostart + path) ----------
$svc = Get-Service DolbyDAXAPI -ErrorAction SilentlyContinue
if ($svc) {
    $reg = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\DolbyDAXAPI' -ErrorAction SilentlyContinue
    $start = if ($reg) { $reg.Start } else { '?' }
    $st = if ($svc.Status -eq 'Running') { (L '运行中' 'Running') } else { $svc.Status }
    $bin = if ($reg) { "$($reg.ImagePath)" } else { '' }
    $binOK = ($bin -match 'dolbyaposvc\\DAX3API\.exe')
    # 安全软件可能拦截 Start 值写入——检测“开机计划任务”兜底是否已建
    # Antivirus may block the Start value; check the autostart scheduled-task fallback.
    $taskOK = schtasks /query /tn "DolbyDAXAPI AutoStart" 2>$null | Select-String -Pattern 'DolbyDAXAPI AutoStart' -Quiet
    $pathNote = if ($binOK) { '' } else { (L ' · 路径异常' ' · bad path') + ":$bin" }
    if ($start -eq 2 -and $svc.Status -eq 'Running') { OK (L '服务（自启）' 'Service (autostart)') ("DolbyDAXAPI " + (L '运行中 · 开机自启已启用' 'Running · autostart enabled') + "$pathNote") }
    elseif ($start -eq 2) { WN (L '服务（自启）' 'Service (autostart)') ("DolbyDAXAPI " + (L '自启已设但未运行（跑「安装」页启动）' 'autostart set but not running (run Install tab)') + "$pathNote") }
    elseif ($taskOK -and $svc.Status -eq 'Running') { OK (L '服务（自启）' 'Service (autostart)') ("DolbyDAXAPI " + (L '运行中 · 开机自启=计划任务兜底（安全软件拦截了服务配置，已用开机任务代替）' 'Running · autostart via scheduled task (antivirus blocked service config)') + "$pathNote") }
    elseif ($taskOK) { WN (L '服务（自启）' 'Service (autostart)') ("DolbyDAXAPI " + (L '未运行 · 开机任务已建（跑「安装」页启动）' 'not running · autostart task exists (run Install tab)') + "$pathNote") }
    elseif ($start -eq 3 -and $svc.Status -eq 'Running') { WN (L '服务（自启）' 'Service (autostart)') ("DolbyDAXAPI " + (L '运行中 · 但开机自启是 手动(3) — 跑「安装」页一次设为自启（若被安全软件拦截会自动建开机任务兜底）' 'Running · but autostart is Manual(3) — run Install tab once (antivirus blocked => task fallback auto-created)') + "$pathNote") }
    else { ER (L '服务（自启）' 'Service (autostart)') ("DolbyDAXAPI " + (L '状态' 'state') + " $st · " + (L '启动值' 'start') + " $start（" + (L '跑「安装」页修复' 'run Install tab to fix') + "）$pathNote") }
} else { ER (L '服务（自启）' 'Service (autostart)') (L 'DolbyDAXAPI 服务不存在（未安装）' 'DolbyDAXAPI service missing (not installed)') }

# ---------- 5. HSA 软件设备（严格：Dolby Atmos + Dolby Audio 都绑定） / HSA software devices (both must be bound) ----------
$hsa = @{}   # DeviceDesc -> @('已绑定'/'无驱动')
Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Enum\ROOT\DOLBYATMOS","HKLM:\SYSTEM\CurrentControlSet\Enum\ROOT\DOLBYAUDIO" -ErrorAction SilentlyContinue | ForEach-Object {
    $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
    if ($p.DeviceDesc -match 'Dolby') {
        $st2 = if ($p.Driver) { (L '已绑定' 'bound') } else { (L '无驱动' 'no driver') }
        if (-not $hsa.ContainsKey($p.DeviceDesc)) { $hsa[$p.DeviceDesc] = @() }
        $hsa[$p.DeviceDesc] += $st2
    }
}
$atmosOK = ($hsa.GetEnumerator() | Where-Object { $_.Key -eq 'Dolby Atmos' -and $_.Value -contains (L '已绑定' 'bound') })
$audioOK = ($hsa.GetEnumerator() | Where-Object { $_.Key -eq 'Dolby Audio' -and $_.Value -contains (L '已绑定' 'bound') })
if ($atmosOK -and $audioOK) { OK (L 'HSA 软件设备' 'HSA devices') (L 'Dolby Atmos(已绑定) + Dolby Audio(已绑定) 就绪' 'Dolby Atmos(bound) + Dolby Audio(bound) ready') }
else {
    $parts = @()
    foreach ($kv in $hsa.GetEnumerator()) { $parts += "$($kv.Key)($($kv.Value -join '/'))" }
    $detail = if ($parts.Count -gt 0) { $parts -join (L '、' ', ') } else { (L '无' 'none') }
    if (-not $atmosOK -and -not $audioOK) { WN (L 'HSA 软件设备' 'HSA devices') ((L '缺少 Dolby Atmos/Dolby Audio 设备' 'Missing Dolby Atmos/Dolby Audio devices') + "（$detail）— " + (L '跑「安装→修复 SWC」' 'run Install > Fix SWC')) }
    elseif (-not $atmosOK) { WN (L 'HSA 软件设备' 'HSA devices') ((L '缺少 Dolby Atmos 设备' 'Missing Dolby Atmos device') + "（$detail）— " + (L '跑「安装→修复 SWC」' 'run Install > Fix SWC')) }
    elseif (-not $audioOK) { WN (L 'HSA 软件设备' 'HSA devices') ((L '缺少 Dolby Audio 设备' 'Missing Dolby Audio device') + "（$detail）— " + (L '跑「安装→修复 SWC」' 'run Install > Fix SWC')) }
    else { WN (L 'HSA 软件设备' 'HSA devices') ((L '设备存在但未全部绑定' 'Devices exist but not all bound') + "（$detail）— " + (L '多为安全软件拦驱动，可暂停后跑「修复 SWC」' 'usually antivirus blocked driver; pause it and run Fix SWC')) }
}
$legacy = Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Enum\ROOT\SWC_VEN_DOLBY_PID_DAX3HSA_DOLBYATMOS'
if ($legacy) { IN (L 'HSA 软件设备' 'HSA devices') (L '（另发现旧版未绑定 SWC 设备，可忽略或手动删除）' '(legacy unbound SWC device found; ignore or delete manually)') }

# ---------- 6. 应用 / App ----------
# 新版架构：DolbyAccess (v3.x) 已内置全部 Dolby Atmos 编码器（DolbyHrtfEnc.dll 的
# Headphones/Speakers + DolbyMatEnc.dll 的 Home Theater），无需再装独立 DolbyAtmos 应用。
# 独立 DolbyAtmos (旧版纯 UI) 仅作为可选附件，缺失不报错。
$appAcc = Get-AppxPackage -Name 'DolbyLaboratories.DolbyAccess' -ErrorAction SilentlyContinue
$appAtmos = Get-AppxPackage -Name 'DolbyLaboratories.DolbyAtmos' -ErrorAction SilentlyContinue
if ($appAcc) {
    OK (L 'Dolby 应用' 'Dolby app') ("DolbyAccess v$($appAcc.Version)（" + (L '已安装 · 内含 Dolby Atmos 编码器' 'installed · includes Dolby Atmos encoders') + "）")
} elseif ($appAtmos) {
    OK (L 'Dolby 应用' 'Dolby app') ("DolbyAtmos v$($appAtmos.Version)（" + (L '已安装' 'installed') + "）")
} else {
    ER (L 'Dolby 应用' 'Dolby app') (L '未安装 DolbyAccess/DolbyAtmos 应用（跑「安装」页补装）' 'no DolbyAccess/DolbyAtmos app (run Install tab)')
}
if ($appAtmos) { IN (L 'Dolby 附应用' 'Dolby extra apps') ("DolbyAtmos v$($appAtmos.Version)（" + (L '旧版纯 UI 附件' 'legacy UI add-on') + "）") }
$extra = Get-AppxPackage -Name 'DolbyLaboratories.*' -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'DolbyLaboratories.DolbyAccess' -and $_.Name -ne 'DolbyLaboratories.DolbyAtmos' }
if ($extra) { IN (L 'Dolby 附应用' 'Dolby extra apps') (($extra | ForEach-Object { "$($_.Name -replace 'DolbyLaboratories\.','') v$($_.Version)" }) -join (L '、' ', ')) }

# ---------- 7. 端点挂接（含设备名） / Endpoint hookups (with device names) ----------
$R = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render'
$fxKey = '{D04E05A6-594B-4FB6-A80D-01AF5EED7D1D},5'
$nameKey = '{a45c254e-df1c-4efd-8020-67d146a850e0},2'
$hwKey = '{b3f8fa53-0004-438e-9003-51a46e139bfc},6'
$dolbyCls = '{0EBD8505-17BB-4AE7-AD76-E86F99A425E9}'
$hooked = @()
Get-ChildItem $R | ForEach-Object {
    $fx = Get-ItemProperty "$($_.PSPath)\FxProperties" -ErrorAction SilentlyContinue
    if ($fx) {
        $v = $fx.$fxKey
        if ($v) { $vs = if ($v -is [array]) { $v -join ';' } else { "$v" }; if ($vs -match $dolbyCls) {
            $nm = (Get-ItemProperty "$($_.PSPath)\Properties" -ErrorAction SilentlyContinue).$nameKey
            $hw = (Get-ItemProperty "$($_.PSPath)\Properties" -ErrorAction SilentlyContinue).$hwKey
            $hooked += "$nm($hw)"
        } }
    }
}
if ($hooked.Count -gt 0) { OK (L '端点挂接' 'Endpoint hookup') ((L '已给' 'Dolby attached to') + " $($hooked.Count) " + (L '个设备挂上杜比' 'device(s)') + "：$($hooked -join (L '、' ', '))") }
else { IN (L '端点挂接' 'Endpoint hookup') (L '暂无（蓝牙/USB/HDMI 设备用「添加设备」页加杜比）' 'none (use Devices tab for BT/USB/HDMI)') }

# ---------- 8. Realtek 主输出挂接（DaxExtFolder + 拓扑 ApoPreset + EP 指示器） / Main output hookup ----------
if ($rtkList.Count -gt 0) {
    $daxOK = $false; $topoOK = $false; $epOK = $false; $nTopo = 0
    foreach ($inst in $rtkList) {
        if ($inst.Dax) { $daxOK = $true }
        $isKey = Join-Path $inst.Path 'InterfaceSetting'
        $props = (Get-ItemProperty $isKey -ErrorAction SilentlyContinue).PSObject.Properties | Where-Object {
            $_.Name -notmatch '^PS' -and $_.Name -match 'Topo' -and $_.Value -is [array] -and (($_.Value -join ';') -match 'ApoPreset[12]') }
        if ($props) { $topoOK = $true; $nTopo = $props.Count }
        if ((Test-Path (Join-Path $isKey 'ApoPreset1\EP\0')) -or (Test-Path (Join-Path $isKey 'ApoPreset2\EP\0'))) { $epOK = $true }
    }
    if ($daxOK -and $topoOK -and $epOK) { OK (L '主输出调音' 'Main output tuning') ((L 'DaxExtFolder 已写 +' 'DaxExtFolder set +') + " $nTopo " + (L '条拓扑挂 ApoPreset（Realtek 扬声器走杜比调音）' 'topology entries with ApoPreset (Realtek speakers use Dolby)')) }
    elseif ($daxOK -and $topoOK) { WN (L '主输出调音' 'Main output tuning') (L 'DaxExtFolder 已写 + 拓扑已挂，但缺 EP 指示器（跑「安装」页修复）' 'DaxExtFolder set + topology hooked, but EP indicator missing (run Install tab)') }
    elseif ($daxOK) { WN (L '主输出调音' 'Main output tuning') (L 'DaxExtFolder 已写，但拓扑未挂 ApoPreset（跑「安装」页修复）' 'DaxExtFolder set but no topology ApoPreset (run Install tab)') }
    else { WN (L '主输出调音' 'Main output tuning') (L 'DaxExtFolder 未写 - 主输出调音可能不生效（跑「安装」页）' 'DaxExtFolder not set - main output tuning may not apply (run Install tab)') }
} else { IN (L '主输出调音' 'Main output tuning') (L '（无 Realtek 声卡，跳过）' '(no Realtek codec, skipped)') }

# ---------- 9. 音频引擎 / Audio engine ----------
$adg = Get-Process audiodg -ErrorAction SilentlyContinue
if ($adg) { OK (L '音频引擎' 'Audio engine') ("audiodg " + (L '运行中' 'running') + "（PID $($adg.Id)）") }
else { ER (L '音频引擎' 'Audio engine') (L 'audiodg 未运行 - 声音可能异常（重启电脑）' 'audiodg not running - audio may be broken (reboot)') }

# ---------- 10. 空间音效（真实读取：audiodg 加载的编码器 + 端点属性兜底） / Spatial audio (real detection) ----------
# 旧实现用编造的 PKEY GUID ({C1D2D4F2-...}) 读端点注册表，永远读不到、永远显示"未开启"。
# 真实机制：空间音效开启时，Windows 把空间编码器（DolbyHrtfEnc.dll / DolbyAudioProcessing.dll）加载进 audiodg。
# 因此：
#   1) 首选证据：audiodg 进程模块里出现 Dolby 空间编码器（HrtfEnc / AudioProcessing）= 当前有开启空间音效的设备。
#   2) 同时给出开启位置线索：哪些激活端点挂了 Dolby APO（空间音效通常作用在其上）。
# 局限：audiodg 模块仅在播放流时稳定存在；无流播放时可能看不到，提示用户播放后刷新。
$spatialOn = $false
$spatialDetail = ''
try {
    $adgMods = @(Get-Process audiodg -ErrorAction SilentlyContinue | ForEach-Object { $_.Modules } | Where-Object {
        $_.FileName -match 'DolbyHrtfEnc\.dll|DolbyAudioProcessing\.dll|DolbyAPOv251\.dll' })
    $hrtf = $adgMods | Where-Object { $_.ModuleName -match 'HrtfEnc' }
    $procDll = $adgMods | Where-Object { $_.ModuleName -match 'AudioProcessing' }
    if ($hrtf) {
        $spatialOn = $true
        $spatialDetail = (L '已开启' 'ON') + "：Dolby Atmos for Headphones（audiodg 已加载 " + $hrtf[0].ModuleName + "）"
    } elseif ($procDll) {
        # DolbyAudioProcessing 加载但无 HrtfEnc：可能是杜比音效处理而非空间格式，标记为部分证据
        $spatialDetail = (L '杜比处理已加载（' 'Dolby processing loaded (') + $procDll[0].ModuleName + (L '），空间编码器未确认' '); spatial encoder unconfirmed')
        $spatialOn = $false
    } else {
        $spatialDetail = L '未检测到空间编码器加载（audiodg 模块里无 DolbyHrtfEnc/AudioProcessing）' 'no spatial encoder in audiodg modules'
    }
} catch { $spatialDetail = L '检测异常' 'detection error' }
# 补充端点线索：哪些激活端点挂了 Dolby APO（空间音效作用对象）
$saEps = @()
Get-ChildItem $R -ErrorAction SilentlyContinue | ForEach-Object {
    $state = (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).DeviceState
    if ($state -ne 1) { return }
    $fx = Get-ItemProperty "$($_.PSPath)\FxProperties" -ErrorAction SilentlyContinue
    if ($fx -and $fx.$fxKey -and ("$($fx.$fxKey)" -match $dolbyCls)) {
        $nm = (Get-ItemProperty "$($_.PSPath)\Properties" -ErrorAction SilentlyContinue).$nameKey
        if ($nm) { $saEps += $nm }
    }
}
if ($saEps.Count -gt 0) { $spatialDetail += (L ' · 作用于' ' on') + "：$($saEps -join (L '、' ', '))" }
if ($spatialOn) { OK (L '空间音效' 'Spatial audio') ($spatialDetail + (L '（点该行打开声音设置→设备属性→空间音效）' ' (click row: Sound settings > device properties > Spatial audio)')) }
else { WN (L '空间音效' 'Spatial audio') ($spatialDetail + (L '；若无音频播放请先播放任意声音再点刷新（空间编码器仅在播放时驻留 audiodg）' '; play any sound first then refresh (spatial encoder only resides in audiodg while playing)')) }

# ---------- 汇总提示 / Summary tip ----------
Write-Host ("@@TIP@@ " + (L '提示：修改配置后重启电脑让 audiodg 重载；本工具所有改动自动备份，可恢复。' 'Tip: reboot after config changes so audiodg reloads; every change is backed up and restorable.'))
