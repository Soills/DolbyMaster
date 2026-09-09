#requires -version 5.1
<#
  RebuildData.ps1 - 重建 Data 目录下的数据文件（删除后可重新生成）
  Data\ 结构（本工具全部数据，可整目录删除后重跑本脚本）：
    TuningNames.txt   型号名映射（SUBSYS -> 型号名）。有 model_map.json 时据此重建；
                      无则全部标"待查型号"（工具功能不受影响）。
    TuningCache.txt   调音快扫缓存（文件名 -> 空key/绑定）。扫描包内调音真实读取生成。
    model_map.json    可选"型号知识库"（有版权顾虑可删除；删除后型号名显示为待查型号）
    model_report.txt  型号对照说明（纯文档，可随时重建为生成摘要）

  用法（管理员）：
    powershell -ExecutionPolicy Bypass -File RebuildData.ps1            # 默认以本脚本所在目录的上级为根
    powershell -ExecutionPolicy Bypass -File RebuildData.ps1 -Root C:\x # 指定根目录（含 Data\ 与包内调音目录）

  English summary:
    Rebuild the data files under Data\ (deletable — regenerate anytime):
      TuningNames.txt  model map "SUBSYS<TAB>name" (from model_map.json if present, else "unknown model")
      TuningCache.txt  fast-scan cache "file<TAB>[key-less]/[bound]" (real scan of package tunings)
      model_map.json   optional knowledge base (delete to hide model names)
      model_report.txt documentation (regenerated as a summary header)
    Usage: RebuildData.ps1 [-Root <package dir>]
#>
param([string]$Root = '')
$ErrorActionPreference = 'SilentlyContinue'
function Write-Ok   ($m) { Write-Host $m -ForegroundColor Green }
function Write-Warn ($m) { Write-Host $m -ForegroundColor Yellow }
function Write-Fail ($m) { Write-Host $m -ForegroundColor Red }

if (-not $Root) { $Root = if ($env:DM_BASE) { $env:DM_BASE } else { Split-Path -Parent $MyInvocation.MyCommand.Path } }
if (-not (Test-Path $Root)) { Write-Fail "[错误] 根目录不存在: $Root"; exit 1 }
$data = Join-Path $Root 'Data'
New-Item -ItemType Directory -Path $data -Force | Out-Null

# 包内调音目录：Drivers 全树下第一个含 DEV_*.xml 的目录
# （布局无关：Drivers\ThirdParty\ext 或 Drivers\ext 均可，不硬编码包名）
$pkg = $null
$drvRoot = Join-Path $Root 'Drivers'
if (Test-Path $drvRoot) {
    $pkg = Get-ChildItem $drvRoot -Directory -Recurse -ErrorAction SilentlyContinue |
        Where-Object { @(Get-ChildItem $_.FullName -Filter 'DEV_*.xml' -ErrorAction SilentlyContinue).Count -gt 0 } |
        Select-Object -First 1 | ForEach-Object { $_.FullName }
}
if (-not $pkg) { Write-Warn "[警告] 未找到包内调音目录，TuningCache 将重建为空（0 个调音）。" }

# ---------- 1. TuningCache.txt ----------
$cacheLines = New-Object System.Collections.Generic.List[string]
$empty = 0; $bound = 0; $none = 0
if ($pkg) {
    # 只扫真调音：排除 *_settings.xml（联想包的 <Config> 设置文件，非调音）
    Get-ChildItem $pkg -Filter 'DEV_*.xml' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch '_settings\.xml$' } | ForEach-Object {
        $ks = '[无key]'
        try {
            $c = Get-Content $_.FullName -Raw -Encoding UTF8
            $m = [regex]::Match($c, '<security-key value="([^"]*)"')
            if ($m.Success) {
                if ($m.Groups[1].Value -eq '') { $ks = '[空key]'; $empty++ }
                else { $ks = '[绑定]'; $bound++ }
            } else { $none++ }
        } catch { $none++ }
        $cacheLines.Add($_.Name + "`t" + $ks)
    }
}
[System.IO.File]::WriteAllLines((Join-Path $data 'TuningCache.txt'), $cacheLines, [System.Text.UTF8Encoding]::new($true))
Write-Ok ("TuningCache.txt 重建完成: 共 {0} 个（空key {1} / 绑定 {2} / 无key {3}）" -f $cacheLines.Count, $empty, $bound, $none)

# ---------- 2. TuningNames.txt（model_map.json 存在则重建，否则保持/生成待查） ----------
$mapFile = Join-Path $data 'model_map.json'
$tnFile  = Join-Path $data 'TuningNames.txt'
$tnLines = New-Object System.Collections.Generic.List[string]
if (Test-Path $mapFile) {
    try {
        $j = Get-Content $mapFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $j.PSObject.Properties | ForEach-Object {
            $name = [string]$_.Value
            $name = $name -replace '^(Lenovo|联想)\s*', ''   # 去品牌前缀（版权中性化）
            $tnLines.Add("$($_.Name)`t$name")
        }
        $tnLines.Add('17AA38BE' + "`t" + '待查型号')          # 已知未确认，保留占位
        $tnLines.Sort()
        [System.IO.File]::WriteAllLines($tnFile, $tnLines, [System.Text.UTF8Encoding]::new($true))
        Write-Ok ("TuningNames.txt 重建完成: 共 {0} 条型号映射（已去品牌前缀）" -f $tnLines.Count)
    } catch {
        Write-Warn "model_map.json 解析失败: $($_.Exception.Message)；保留现有 TuningNames.txt"
    }
} else {
    if (-not (Test-Path $tnFile)) {
        [System.IO.File]::WriteAllLines($tnFile, @("# 无型号知识库(model_map.json)，所有机型显示为待查型号"), [System.Text.UTF8Encoding]::new($true))
    }
    Write-Warn "model_map.json 不存在（已删除？）：型号名将显示为待查型号（工具功能不受影响）。"
}

# ---------- 3. model_report.txt ----------
$stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$rep = @(
    "# 型号对照说明（自动生成，$stamp）",
    "# 本文件仅为研发过程记录：SUBSYS 与具体机型的对照、线索与置信度。",
    "# 有版权顾虑可整行/整段删除，或直接删除本文件——不影响工具任何功能。",
    "# 重新生成：运行 RebuildData.ps1（仅生成此摘要头，原研究记录需人工补充）。",
    ""
)
[System.IO.File]::WriteAllLines((Join-Path $data 'model_report.txt'), $rep, [System.Text.UTF8Encoding]::new($true))
Write-Ok "model_report.txt 已重建（摘要头）。"

Write-Ok "[完成] Data 目录数据文件已重建。"
Write-Warn "提示：TuningCache.txt 也会在每次打开「切换调音」页时自动增量重建；删除后无需手动跑本脚本也能恢复。"
