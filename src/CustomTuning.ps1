#requires -version 5.1
<#
  CustomTuning.ps1 - 杜比 DAX3 自定义调音生成器（v2，全参数版）
  以现有调音为模板，按用户参数生成新的调音 XML（空 security-key，任意机器可切换）。

  用法（需要管理员，输出到包内调音目录才可被「切换调音」列表识别）：
    powershell -ExecutionPolicy Bypass -File CustomTuning.ps1 `
        -Template "DEV_0257_SUBSYS_17AA3985_PCI_SUBSYS_380617AA.xml" `
        -OutPath "DEV_0257_SUBSYS_17AA3985_Custom_我的调音.xml" `
        -GeqEnable 1 -GeqBands "60,40,20,0,0,0,0,0,0,0,0,0,0,0,0,10,20,30,40,50" `
        -BassEnable 1 -BassBoost 5 -BassCutoff 200 `
        -SurroundDecoderEnable 1 -SurroundVirtEnable 1 -HeightVirtEnable 1 `
        -VirtFrontAngle 5 -VirtSurroundAngle 5 -VirtRearAngle 10 `
        -SpeakerPeqEnable 1 -SpeakerPeqFilters "200,15,0.51,1;400,-12,1,1;1000,-3,1,1;6000,9,1,3;2000,5,1.5,1" `
        -RegulatorEnable 1 -MbCompressorEnable 1 `
        -Profiles "dynamic,movie"

  参数说明（DAX3 内部标度；新参数默认 -1 = 不动模板原值）：
    基础（沿用 v1）：
      -GeqEnable/-GeqBands     20 段图形EQ（-192..192，0=平直）
      -IeqEnable/-IeqAmount/-IeqPreset   智能EQ（ieq_balanced/ieq_detailed/ieq_warm）
      -BassEnable/-BassBoost/-BassCutoff 低音增强
      -LevelerEnable/-LevelerAmount      音量均衡
      -DialogEnable/-DialogAmount        对白增强
      -SurroundEnable/-SurroundBoost     兼容旧参数：SurroundEnable=1 时打开
                                          surround-decoder + 环绕/高度虚拟化
    环绕解码（v2）：
      -SurroundDecoderEnable 0/1          多声道(5.1/7.1/Atmos)解码下混
      -SurroundCenterSpreading 0/1        中置展开（0=对白稳定居中）
    虚拟化（v2）：
      -SurroundVirtEnable 0/1             环绕虚拟化（partial-surround）
      -HeightVirtEnable 0/1               高度虚拟化（partial-height）
      -MiVirtSteering 0/1                 Atmos 对象元数据驱动定位
      -VirtFrontAngle / -VirtSurroundAngle / -VirtRearAngle /
      -VirtRearHeightAngle / -VirtHeightAngle   虚拟扬声器角度（度）
    喇叭EQ（v2，调音核心）：
      -SpeakerPeqEnable 0/1
      -SpeakerPeqFilters "f0,gain,q,type;..."   每段 f0,gain,q,type
           type: 1=峰值 Peaking（用 q），3=架 Shelf（用 s）
           例（Yoga9 风格）："200,15,0.51,1;400,-12,1,1;1000,-3,1,1;6000,9,1,3;2000,5,1.5,1"
           自动对称写入 speaker=0/1（L/R）
    保护/动态（v2）：
      -RegulatorEnable 0/1                智能限幅防破音
      -RegulatorRelaxation 0..100         限幅恢复速度（默认 96）
      -RegulatorTimbre 0..100             音色保留（默认 12）
      -MbCompressorEnable 0/1             多段压缩
      -WooferRegulatorEnable 0/1          低音喇叭独立限幅
    低音（v2）：
      -BassExtractEnable/-BassExtractCutoff/-BassExtractLfeGain  低音提取（给小喇叭）
      -VirtualBassEnable 0/1              虚拟低音（谐波，小喇叭出"心理低音"）
      -VirtualBassGain                    虚拟低音增益
    增益（v2）：
      -Pregain/-Postgain                  前/后级增益（响度微调）
    作用范围（v2）：
      -Profiles "dynamic,movie"           仅改这些 profile（留空=全部 profile）
                                           可选值: dynamic/movie/game/music/voice/off
  无 OutPath 时仅做校验试跑（不写文件）。

  English summary:
    Dolby DAX3 custom tuning generator v2 (full-parameter). Takes an existing tuning as template
    and applies user parameters to produce a new tuning XML with an EMPTY security-key.
    New params (default -1 = leave template value): -SurroundDecoderEnable/-SurroundCenterSpreading,
    -SurroundVirtEnable/-HeightVirtEnable/-MiVirtSteering, -VirtFrontAngle/-VirtSurroundAngle/
    -VirtRearAngle/-VirtRearHeightAngle/-VirtHeightAngle, -SpeakerPeqEnable/-SpeakerPeqFilters
    ("f0,gain,q,type;..." type 1=peaking/3=shelf, written symmetrically to L/R),
    -RegulatorEnable/-RegulatorRelaxation/-RegulatorTimbre, -MbCompressorEnable,
    -WooferRegulatorEnable, -BassExtractEnable/-BassExtractCutoff/-BassExtractLfeGain,
    -VirtualBassEnable/-VirtualBassGain, -Pregain/-Postgain, -Profiles "dynamic,movie".
#>
param(
    [string]$Template,
    [string]$OutPath,
    [string]$Name = '',
    # 图形EQ
    [int]$GeqEnable = 0,
    [string]$GeqBands = '',
    # 智能EQ
    [int]$IeqEnable = 0,
    [int]$IeqAmount = 10,
    [string]$IeqPreset = 'ieq_balanced',
    # 低音增强
    [int]$BassEnable = 0,
    [int]$BassBoost = 0,
    [int]$BassCutoff = 200,
    # 音量均衡 / 对白
    [int]$LevelerEnable = 1,
    [int]$LevelerAmount = 5,
    [int]$DialogEnable = 0,
    [int]$DialogAmount = 5,
    # 环绕（v1 兼容：SurroundEnable=1 打开解码+虚拟化）
    [int]$SurroundEnable = 0,
    [int]$SurroundBoost = 96,
    # 环绕解码（v2，-1=不动）
    [int]$SurroundDecoderEnable = -1,
    [int]$SurroundCenterSpreading = -1,
    # 虚拟化（v2）
    [int]$SurroundVirtEnable = -1,
    [int]$HeightVirtEnable = -1,
    [int]$MiVirtSteering = -1,
    [int]$VirtFrontAngle = -1,
    [int]$VirtSurroundAngle = -1,
    [int]$VirtRearAngle = -1,
    [int]$VirtRearHeightAngle = -1,
    [int]$VirtHeightAngle = -1,
    # 喇叭EQ（v2）
    [int]$SpeakerPeqEnable = -1,
    [string]$SpeakerPeqFilters = '',
    # 保护（v2）
    [int]$RegulatorEnable = -1,
    [int]$RegulatorRelaxation = -1,
    [int]$RegulatorTimbre = -1,
    [int]$MbCompressorEnable = -1,
    [int]$WooferRegulatorEnable = -1,
    # 低音（v2）
    [int]$BassExtractEnable = -1,
    [int]$BassExtractCutoff = -1,
    [int]$BassExtractLfeGain = -1,
    [int]$VirtualBassEnable = -1,
    [int]$VirtualBassGain = -1,
    # 增益（v2）
    [int]$Pregain = -1,
    [int]$Postgain = -1,
    # 作用范围（v2）
    [string]$Profiles = ''
)
$ErrorActionPreference = 'Stop'
function Write-Ok   ($m) { Write-Host $m -ForegroundColor Green }
function Write-Warn ($m) { Write-Host $m -ForegroundColor Yellow }
function Write-Fail ($m) { Write-Host $m -ForegroundColor Red }

# ---------- 1. 校验模板 ----------
if (-not $Template -or -not (Test-Path $Template)) { Write-Fail "[错误] 模板不存在: $Template"; exit 1 }
$doc = New-Object System.Xml.XmlDocument
$doc.PreserveWhitespace = $true
$doc.Load($Template)
if ($doc.DocumentElement.Name -ne 'device_data') { Write-Fail "[错误] 模板不是 device_data 调音文件（root=$($doc.DocumentElement.Name)）"; exit 1 }
$ns = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
$ns.AddNamespace('x', $doc.DocumentElement.NamespaceURI)

# ---------- 作用域：-Profiles 限定只改指定 profile（空=全部） ----------
$profileScope = @()
if ($Profiles) { $profileScope = @($Profiles -split ',' | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ }) }

function Test-Scope($node) {
    if ($profileScope.Count -eq 0) { return $true }
    $anc = $node.SelectSingleNode("ancestor::*[local-name()='profile']", $ns)
    if (-not $anc) { return $true }   # profile 外（constant/setting 等）视为全局
    return ($profileScope -contains $anc.GetAttribute('type').ToLower())
}

# ---------- 通用改写：所有端点/形态/profile 内同名元素 ----------
function Set-All([string]$elem, [string]$value) {
    if ($value -eq '-1') { return 0 }   # 哨兵：-1 = 不动模板原值
    $nodes = $doc.SelectNodes("//*[local-name()='$elem']", $ns)
    $hit = 0
    foreach ($n in $nodes) {
        if (-not (Test-Scope $n)) { continue }
        $n.SetAttribute('value', $value); $hit++
    }
    if ($hit -eq 0) { Write-Warn "[警告] 作用域内没有 <$elem>，已跳过（$value）" }
    return $hit
}

$changed = @()

# ---------- 2. 基础效果（作用于所有端点/采样块） ----------
$changed += Set-All 'graphic-equalizer-enable' ([string]$GeqEnable)
$changed += Set-All 'ieq-enable' ([string]$IeqEnable)
$changed += Set-All 'ieq-amount' ([string]$IeqAmount)
$changed += Set-All 'bass-enhancer-enable' ([string]$BassEnable)
$changed += Set-All 'bass-enhancer-boost' ([string]$BassBoost)
$changed += Set-All 'bass-enhancer-cutoff-frequency' ([string]$BassCutoff)
$changed += Set-All 'volume-leveler-enable' ([string]$LevelerEnable)
$changed += Set-All 'volume-leveler-amount' ([string]$LevelerAmount)
$changed += Set-All 'dialog-enhancer-enable' ([string]$DialogEnable)
$changed += Set-All 'dialog-enhancer-amount' ([string]$DialogAmount)
$changed += Set-All 'surround-boost' ([string]$SurroundBoost)

# 图形EQ：启用时注入 20 段自定义曲线
if ($GeqEnable -eq 1) {
    $bands = ($GeqBands -split ',' | ForEach-Object { $_.Trim() })
    if ($bands.Count -ne 20) { Write-Fail "[错误] GeqBands 必须恰好 20 个数值，实际 $($bands.Count) 个"; exit 1 }
    $target = ($bands -join ',')
    $arrName = 'array_20_custom'
    $arr = $doc.SelectSingleNode("//*[local-name()='array_20_custom']", $ns)
    if ($arr) { $arr.SetAttribute('target', $target) }
    else {
        # 插到 constant 里（跟 array_20_zero 同级）
        $anchor = $doc.SelectSingleNode("//*[local-name()='array_20_zero']", $ns)
        if ($anchor) {
            $arr = $doc.CreateElement('array_20_custom')
            $arr.SetAttribute('target', $target)
            $anchor.ParentNode.InsertBefore($arr, $anchor)
        } else {
            Write-Warn "[警告] 模板里没有 array_20_zero 锚点，无法注入自定义EQ曲线"
        }
    }
    foreach ($n in $doc.SelectNodes("//*[local-name()='graphic-equalizer-bands']", $ns)) { if (Test-Scope $n) { $n.SetAttribute('preset', $arrName) } }
    Write-Host "  图形EQ: 启用 · 20段曲线已注入 (array_20_custom)"
} else {
    Write-Host "  图形EQ: 关闭（保留模板原曲线参考，不生效）"
}

# IEQ 预设
$ieqSet = $doc.SelectNodes("//*[local-name()='ieq-bands-set']", $ns)
foreach ($n in $ieqSet) { if (Test-Scope $n) { $n.SetAttribute('preset', $IeqPreset) } }

# ---------- 3. 环绕解码 + 虚拟化（v2） ----------
# v1 兼容：SurroundEnable=1 → 解码 + 环绕/高度虚拟化全开；0 = 不动
# （v1 脚本里该参数本就未生效，仅传 boost；避免旧 UI 的"关"误杀模板的解码/虚拟化）
if ($SurroundEnable -eq 1) {
    $changed += Set-All 'surround-decoder-enable' '1'
    $changed += Set-All 'output-mode-partial-surround-virtualizer-enable' '1'
    $changed += Set-All 'output-mode-partial-height-virtualizer-enable' '1'
    Write-Host "  环绕(兼容): SurroundEnable=1 → 解码+环绕/高度虚拟化全开"
}
# v2 显式参数（优先级更高，-1=不动）
$changed += Set-All 'surround-decoder-enable' ([string]$SurroundDecoderEnable)
$changed += Set-All 'surround-decoder-center-spreading-enable' ([string]$SurroundCenterSpreading)
$changed += Set-All 'output-mode-partial-surround-virtualizer-enable' ([string]$SurroundVirtEnable)
$changed += Set-All 'output-mode-partial-height-virtualizer-enable' ([string]$HeightVirtEnable)
$changed += Set-All 'mi-virt-steering-enable' ([string]$MiVirtSteering)
$changed += Set-All 'virtualizer-front-speaker-angle' ([string]$VirtFrontAngle)
$changed += Set-All 'virtualizer-surround-speaker-angle' ([string]$VirtSurroundAngle)
$changed += Set-All 'virtualizer-rear-speaker-angle' ([string]$VirtRearAngle)
$changed += Set-All 'virtualizer-rear-height-speaker-angle' ([string]$VirtRearHeightAngle)
$changed += Set-All 'virtualizer-height-speaker-angle' ([string]$VirtHeightAngle)

# ---------- 4. 喇叭EQ（调音核心，v2） ----------
if ($SpeakerPeqFilters) {
    $specs = @()
    foreach ($s in ($SpeakerPeqFilters -split ';')) {
        $s = $s.Trim(); if (-not $s) { continue }
        $p = @($s -split ',' | ForEach-Object { $_.Trim() })
        if ($p.Count -lt 3) { Write-Fail "[错误] PEQ 段格式应为 f0,gain,q[,type]，实际: $s"; exit 1 }
        $f0   = [int][double]::Parse($p[0], [Globalization.CultureInfo]::InvariantCulture)
        $gain = [double]::Parse($p[1], [Globalization.CultureInfo]::InvariantCulture)
        $q    = [double]::Parse($p[2], [Globalization.CultureInfo]::InvariantCulture)
        $type = if ($p.Count -ge 4) { [int]::Parse($p[3]) } else { 1 }
        $specs += ,@{ f0 = $f0; gain = $gain; q = $q; type = $type }
    }
    if ($specs.Count -eq 0) {
        Write-Warn "[警告] SpeakerPeqFilters 没有有效段，跳过"
    } else {
        $peqNodes = $doc.SelectNodes("//*[local-name()='speaker-peq-filters']", $ns)
        $rewritten = 0
        foreach ($peq in $peqNodes) {
            if (-not (Test-Scope $peq)) { continue }
            while ($peq.HasChildNodes) { [void]$peq.RemoveChild($peq.FirstChild) }
            foreach ($spk in 0, 1) {
                foreach ($spec in $specs) {
                    $f = $doc.CreateElement('filter')
                    $f.SetAttribute('speaker', "$spk")
                    $f.SetAttribute('enabled', '1')
                    $f.SetAttribute('type', "$($spec.type)")
                    $f.SetAttribute('f0', "$($spec.f0)")
                    $f.SetAttribute('gain', $spec.gain.ToString('0.000000', [Globalization.CultureInfo]::InvariantCulture))
                    if ($spec.type -eq 3) {
                        $f.SetAttribute('s', $spec.q.ToString('0.000000', [Globalization.CultureInfo]::InvariantCulture))
                    } else {
                        $f.SetAttribute('q', $spec.q.ToString('0.000000', [Globalization.CultureInfo]::InvariantCulture))
                    }
                    [void]$peq.AppendChild($f)
                }
            }
            $rewritten++
        }
        if ($rewritten -eq 0) { Write-Warn "[警告] 作用域内没有 <speaker-peq-filters>，PEQ 未写入" }
        else { Write-Host "  喇叭PEQ: 重写 $rewritten 处 · $($specs.Count) 段 × L/R（type: 1=峰值 3=架）" }
    }
}
$changed += Set-All 'speaker-peq-enable' ([string]$SpeakerPeqEnable)

# ---------- 5. 保护 / 动态（v2） ----------
$changed += Set-All 'regulator-enable' ([string]$RegulatorEnable)
$changed += Set-All 'regulator-relaxation-amount' ([string]$RegulatorRelaxation)
$changed += Set-All 'regulator-timbre-preservation' ([string]$RegulatorTimbre)
$changed += Set-All 'mb-compressor-enable' ([string]$MbCompressorEnable)
$changed += Set-All 'woofer-regulator-enable' ([string]$WooferRegulatorEnable)

# ---------- 6. 低音（v2） ----------
$changed += Set-All 'bass-extraction-enable' ([string]$BassExtractEnable)
$changed += Set-All 'bass-extraction-cutoff-frequency' ([string]$BassExtractCutoff)
$changed += Set-All 'bass-extraction-lfe-gain' ([string]$BassExtractLfeGain)
if ($VirtualBassEnable -ge 0) {
    $v = [string]$VirtualBassEnable
    # 主开关在 init-info（虚拟低音总开关）+ 模式（0=关，1..=开）
    $changed += Set-All 'virtual_bass_process_enable' $v
    if ($v -eq '1') { $changed += Set-All 'virtual-bass-mode' '1' } else { $changed += Set-All 'virtual-bass-mode' '0' }
}
$changed += Set-All 'virtual-bass-overall-gain' ([string]$VirtualBassGain)

# ---------- 7. 增益（v2） ----------
$changed += Set-All 'pregain' ([string]$Pregain)
$changed += Set-All 'postgain' ([string]$Postgain)

# ---------- 8. 安全 key 置空 -> 任意机器可切换 ----------
$keys = $doc.SelectNodes("//*[local-name()='security-key']", $ns)
foreach ($k in $keys) { $k.SetAttribute('value', '') }
Write-Host "  security-key: 已置空（空key，可自由切换）"

# ---------- 9. 输出 ----------
if (-not $OutPath) {
    Write-Ok "[校验] 参数合法，未指定 OutPath，未写文件。"
    exit 0
}
$doc.Save($OutPath)
Write-Ok "[完成] 已生成自定义调音: $OutPath"
if ($Name) { Write-Host "        名称: $Name" }
if ($profileScope.Count -gt 0) { Write-Host "        作用域 profiles: $($profileScope -join ', ')" }
Write-Host "        修改点: $($changed -join '+') 处元素"
Write-Warn "        到「切换调音」页选它点“切换”（或本页“保存并立即应用”）后重启电脑生效。"
exit 0
