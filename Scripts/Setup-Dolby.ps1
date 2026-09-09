#requires -version 5.1
<#
  Setup-Dolby.ps1 - 杜比 DAX3 通用激活器（免签名方案，任意 Realtek 机器通用）

  原理：包内 Dolby DAX3 组件全部带 Dolby Laboratories 官方签名，可直接被音频服务加载。
  因此无需 pnputil / 测试模式 / 改 INF —— 只做与官方 INF 安装等效的 5 件事：
    1) 部署 DAX3 组件（DolbyDax3Apo.dll / DAX3API.exe 等）
    2) 重放 dax3_swc_aposvc.inf 的全部 APO 注册（315 条，实时从 INF 解析）
    3) 创建/启用 DolbyDAXAPI 服务
    4) 在所有 Realtek 音频设备实例上挂接端点（InterfaceSetting\ApoPreset + DaxExtFolder）
    5) 部署调音（本包全部调音 + 耳机调音）

  通用性：不针对任何具体机型。自动发现：
    - 机器上所有 Realtek (VEN_10EC) 音频设备实例；
    - 已存在的任何杜比部署目录（dolbyaposvc / drivers\DolbyDAX3 / Program Files 等）；
    - 各实例上已有的端点拓扑值（SST/HAP/Primary/Single/Dock... 任意命名）。

  【重复处理】检测到已安装（服务存在 / APO 已注册）时：默认先卸载清理再重装，绝不叠加。

  用法（管理员）：
    powershell -ExecutionPolicy Bypass -File Setup-Dolby.ps1             # 安装；已装则先卸载再重装
    powershell -ExecutionPolicy Bypass -File Setup-Dolby.ps1 -Reinstall  # 强制 卸载+重装
    powershell -ExecutionPolicy Bypass -File Setup-Dolby.ps1 -Uninstall  # 只卸载（清服务+APO注册+端点挂接）
    powershell -ExecutionPolicy Bypass -File Setup-Dolby.ps1 -Uninstall -Purge   # 卸载并删除部署目录
    powershell -ExecutionPolicy Bypass -File Setup-Dolby.ps1 -Diagnose   # 只诊断（只读）
    powershell -ExecutionPolicy Bypass -File Setup-Dolby.ps1 -Appx       # 安装 DolbyAtmos 应用(若缺)
    powershell -ExecutionPolicy Bypass -File Setup-Dolby.ps1 -SWC        # 只补建 Dolby SWC 软件设备(HSA)

  English summary:
    Generic Dolby DAX3 installer for ANY Realtek machine (no signature / test-mode / INF hack needed):
    the bundled DAX3 components are Dolby-signed, so we just do what the official INF install does:
      1) deploy DAX3 components (DolbyDax3Apo.dll / DAX3API.exe ...)
      2) replay all APO registrations from dax3_swc_aposvc.inf (~315 entries, parsed live)
      3) create/enable the DolbyDAXAPI service
      4) hook endpoints on every Realtek (VEN_10EC) audio instance (InterfaceSetting\ApoPreset + DaxExtFolder)
      5) deploy tunings (package tunings + optional headphone tunings)
    Re-running = clean uninstall then reinstall (never stacks). Driver paths are auto-discovered by
    filename anywhere under Drivers (ThirdParty\swc_factory or swc_factory, any version folder name),
    tuning dir auto-found as the first folder holding DEV_*.xml under Drivers (ThirdParty\ext or ext).
    Usage: Setup-Dolby.ps1 [-Reinstall|-Uninstall|-Uninstall -Purge|-Diagnose|-Appx|-SWC]
#>
param(
    [switch]$Diagnose,
    [switch]$Uninstall,
    [switch]$Reinstall,
    [switch]$Purge,
    [switch]$Appx,
    [switch]$SWC,
    [switch]$Access
)
$ErrorActionPreference = 'Stop'

# ---------- 输出着色（须在使用前定义，脚本按顺序执行） ----------
# Colored output helpers (must be defined before first use — the script runs top-to-bottom).
function Write-Ok   ($m) { Write-Host $m -ForegroundColor Green }
function Write-Warn ($m) { Write-Host $m -ForegroundColor Yellow }
function Write-Fail ($m) { Write-Host $m -ForegroundColor Red }
function Write-Head ($m) { Write-Host $m -ForegroundColor Cyan }

# ---------- 路径 ----------
# 包根定位：内联执行（exe 内存运行，DM_BASE 经进程环境变量传入 = 包根）或文件执行（cmd/手动）都兼容。
# Root: works when run embedded (DM_BASE passed via process env var = package root) or as a file (auto-locate).
$DM_Base = if ($env:DM_BASE) { $env:DM_BASE } else { $null }
if (-not $DM_Base) {
    $crack = Split-Path -Parent $MyInvocation.MyCommand.Path   # 文件执行：脚本在 Scripts\，Crack 在上一级
    $proj  = Split-Path -Parent $crack
} else {
    $proj  = $DM_Base                                          # 内联执行：exe 目录即包根
    $crack = Join-Path $proj 'Crack'
}
# ---- 驱动/资源定位：全部动态查找，不硬编码包名/版本目录名（便于自备任意版本） ----
# 布局兼容：Drivers\ThirdParty\{ext,swc_factory}（推荐）与 Drivers\{ext,swc_factory}（旧布局）均可，
# 一律在 Drivers 全树递归按文件名/内容定位。
$drvRoot = Join-Path $proj 'Drivers'
# 调音目录：Drivers 下第一个含 DEV_*.xml 的目录（任意层，通常为 ThirdParty\ext 或 ext）
$extDir = $null
if (Test-Path $drvRoot) {
    $extDir = Get-ChildItem $drvRoot -Directory -Recurse -ErrorAction SilentlyContinue |
        Where-Object { @(Get-ChildItem $_.FullName -Filter 'DEV_*.xml' -ErrorAction SilentlyContinue).Count -gt 0 } |
        Select-Object -First 1 | ForEach-Object { $_.FullName }
}
if (-not $extDir) { Write-Warn "[警告] 未找到包内调音目录（Drivers 下无含 DEV_*.xml 的目录），将跳过调音部署。" }
# swc_aposvc（APO 注册 INF）与 swc_hsa（软件设备 INF）：
# 在 Drivers 全树按文件名递归扫描任意层（版本目录名可能不同，如 swc_aposvc_19h1_..._v3.30400.413.0），
# media 版 HSA 优先；找不到 media 版时退回任意第一个。
$SWC_INF = Get-ChildItem $drvRoot -Recurse -File -Filter 'dax3_swc_aposvc.inf' -ErrorAction SilentlyContinue | Select-Object -First 1 | ForEach-Object { $_.FullName }
$HSA_INF = Get-ChildItem $drvRoot -Recurse -File -Filter 'dax3_swc_hsa.inf' -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match 'media' } | Select-Object -First 1 | ForEach-Object { $_.FullName }
if (-not $HSA_INF) { $HSA_INF = Get-ChildItem $drvRoot -Recurse -File -Filter 'dax3_swc_hsa.inf' -ErrorAction SilentlyContinue | Select-Object -First 1 | ForEach-Object { $_.FullName } }
$swcDir = if ($SWC_INF) { Split-Path -Parent $SWC_INF } else { '' }
$hdTun  = Join-Path $crack 'Extracted'                                   # 安装器解出的耳机调音（可选，缺失则跳过）
# HSA 软件设备用官方 INF 里声明的模型 ID（Media 类），这样 SetupDi 创建后能按 HWID
# 匹配到已暂存的 oem*.inf 并绑定驱动，设备管理器干净、无“未安装驱动”警告。
# 注意：必须用 Media 类 INF（dax3_swc_hsa.inf，Class=Media），而不是同目录 SoftwareComponent 版。
$HSA_DEVICE_ID = 'DolbyAtmos'                  # dax3_swc_hsa.inf 的 Models 硬件 ID
$HSA_DESC      = 'Dolby Atmos'
$HSA_DEVICE_ID2 = 'DolbyAudio'                 # 应用需要两个 HSA 设备：Dolby Atmos + Dolby Audio
$HSA_DESC2     = 'Dolby Audio'
$HSA_CLASS_GUID = '{4d36e96c-e325-11ce-bfc1-08002be10318}'               # Media 类（与 INF 一致）
$HSA_CLASS_NAME = 'MEDIA'

$AUDIO_CLASS = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e96c-e325-11ce-bfc1-08002be10318}'
$DP_INDICATOR = '{6CA6A085-3041-482B-9113-C61E7F250356},0'               # Dolby enabled 指示器
$DP_IND_VER   = '0.4.0'
$canonicalDir = 'C:\Windows\System32\dolbyaposvc'                        # 首选部署目录
$candidateDirs = @($canonicalDir, 'C:\Windows\System32\drivers\DolbyDAX3',
                   'C:\Program Files\Dolby', 'C:\Program Files (x86)\Dolby')

function Write-Ok   ($m) { Write-Host $m -ForegroundColor Green }
function Write-Warn ($m) { Write-Host $m -ForegroundColor Yellow }
function Write-Fail ($m) { Write-Host $m -ForegroundColor Red }
function Write-Head ($m) { Write-Host $m -ForegroundColor Cyan }
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# ---------- 通用发现 ----------
function Get-RealtekInstances {
    Get-ChildItem $AUDIO_CLASS -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match '^\d{4}$' -and ((Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).MatchingDeviceId -match 'VEN_10EC') }
}
function Find-Deployment {
    # 优先看服务当前指向的目录，再扫描候选目录
    $bin = $null
    try { $bin = (Get-CimInstance Win32_Service -Filter "Name='DolbyDAXAPI'" -ErrorAction SilentlyContinue).PathName } catch { }
    if ($bin) {
        $dir = Split-Path ($bin -replace '"','')
        if (Test-Path (Join-Path $dir 'DolbyDax3Apo.dll')) { return $dir }
    }
    foreach ($d in $candidateDirs) {
        if ((Test-Path (Join-Path $d 'DAX3API.exe')) -and (Test-Path (Join-Path $d 'DolbyDax3Apo.dll'))) { return $d }
    }
    return $null
}
function Get-ServiceInfo {
    $svc = Get-Service DolbyDAXAPI -ErrorAction SilentlyContinue
    if (-not $svc) { return $null }
    $bin = $null
    try { $bin = (Get-CimInstance Win32_Service -Filter "Name='DolbyDAXAPI'" -ErrorAction SilentlyContinue).PathName } catch { }
    return [pscustomobject]@{ Name='DolbyDAXAPI'; Status=$svc.Status; Start=$svc.StartType; Binary=$bin }
}

# ---------- SWC 软件设备（HSA 硬件支持声明 + 应用 pfn 关联）----------
# CM_Create_DevNode 建不了 SWC（PnP 总线设备）——devcon/官方用的是 SetupDi：
# SetupDiCreateDeviceInfoW -> 设 SPDRP_HARDWAREID -> DIF_REGISTERDEVICE -> DIF_INSTALLDEVICE
function Add-Type-SWCSetup {
    if (-not ('SWCSetup' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class SWCSetup {
    [StructLayout(LayoutKind.Sequential)]
    public struct SP_DEVINFO_DATA {
        public uint cbSize;
        public Guid ClassGuid;
        public uint DevInst;
        public IntPtr Reserved;
    }
    [DllImport("setupapi.dll", CharSet=CharSet.Ansi, EntryPoint="SetupDiCreateDeviceInfoList", SetLastError=true)]
    public static extern IntPtr SetupDiCreateDeviceInfoList(ref Guid ClassGuid, IntPtr hwndParent);
    [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern bool SetupDiCreateDeviceInfoW(IntPtr DeviceInfoSet, string DeviceName, ref Guid ClassGuid, string DeviceDescription, IntPtr hwndParent, uint CreationFlags, ref SP_DEVINFO_DATA DeviceInfoData);
    [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern bool SetupDiSetDeviceRegistryPropertyW(IntPtr DeviceInfoSet, ref SP_DEVINFO_DATA DeviceInfoData, uint Property, byte[] PropertyBuffer, uint PropertyBufferSize);
    [DllImport("setupapi.dll", SetLastError=true)]
    public static extern bool SetupDiCallClassInstaller(uint InstallFunction, IntPtr DeviceInfoSet, ref SP_DEVINFO_DATA DeviceInfoData);
    [DllImport("setupapi.dll", SetLastError=true)]
    public static extern bool SetupDiDestroyDeviceInfoList(IntPtr DeviceInfoSet);

    public const uint DICD_GENERATE_ID = 0x00000001;
    public const uint SPDRP_HARDWAREID  = 0x00000001;
    public const uint DIF_REGISTERDEVICE = 0x00000019;
    public const uint DIF_INSTALLDEVICE  = 0x0000001C;

    // 返回：0=成功且已装驱动；1=设备已存在；2=devnode 已建但驱动安装失败（调用方继续触发）；负数=建前失败
    public static int Create(string hwid, string desc, string classGuid, out uint devInst) {
        devInst = 0;
        Guid g = new Guid(classGuid);
        IntPtr set = SetupDiCreateDeviceInfoList(ref g, IntPtr.Zero);
        if (set == IntPtr.Zero || set == new IntPtr(-1)) {
            int e = Marshal.GetLastWin32Error();
            Console.WriteLine("  [1/5] SetupDiCreateDeviceInfoList 失败 Win32={0} ({1})", e, new System.ComponentModel.Win32Exception(e).Message);
            return -e;
        }
        Console.WriteLine("  [1/5] SetupDiCreateDeviceInfoList OK (class={0})", classGuid);
        // [2/5] 创建设备信息元素：先试原始 HWID 名，失败再试净化名（\ & 换 _），HWID 属性始终写完整 ID
        string san = hwid.Replace('\\', '_').Replace('&', '_').Replace('.', '_');
        string[] nameCands = { hwid, san };
        SP_DEVINFO_DATA did = new SP_DEVINFO_DATA();
        did.cbSize = (uint)Marshal.SizeOf(typeof(SP_DEVINFO_DATA));
        bool created = false; int step2Err = 0;
        foreach (string nm in nameCands) {
            did = new SP_DEVINFO_DATA(); did.cbSize = (uint)Marshal.SizeOf(typeof(SP_DEVINFO_DATA));
            if (SetupDiCreateDeviceInfoW(set, nm, ref g, desc, IntPtr.Zero, DICD_GENERATE_ID, ref did)) {
                created = true;
                Console.WriteLine("  [2/5] SetupDiCreateDeviceInfoW OK (name='{0}', DevInst={1})", nm, did.DevInst);
                break;
            }
            int e = Marshal.GetLastWin32Error(); step2Err = e;
            Console.WriteLine("  [2/5] SetupDiCreateDeviceInfoW 尝试 '{0}' 失败 Win32={1} ({2})", nm, e, new System.ComponentModel.Win32Exception(e).Message);
        }
        if (!created) {
            SetupDiDestroyDeviceInfoList(set);
            return (step2Err == 0x16D) ? 1 : -step2Err; // ERROR_DEVINST_ALREADY_EXISTS=0x16D
        }
        string hwids = hwid + "\0\0";
        byte[] buf = System.Text.Encoding.Unicode.GetBytes(hwids);
        if (!SetupDiSetDeviceRegistryPropertyW(set, ref did, SPDRP_HARDWAREID, buf, (uint)buf.Length)) {
            int e = Marshal.GetLastWin32Error();
            Console.WriteLine("  [3/5] SetupDiSetDeviceRegistryPropertyW 失败 Win32={0} ({1})", e, new System.ComponentModel.Win32Exception(e).Message);
            SetupDiDestroyDeviceInfoList(set);
            return -e;
        }
        Console.WriteLine("  [3/5] SetupDiSetDeviceRegistryPropertyW OK (HWID={0})", hwid);
        if (!SetupDiCallClassInstaller(DIF_REGISTERDEVICE, set, ref did)) {
            int e = Marshal.GetLastWin32Error();
            Console.WriteLine("  [4/5] DIF_REGISTERDEVICE 失败 Win32={0} ({1})", e, new System.ComponentModel.Win32Exception(e).Message);
            SetupDiDestroyDeviceInfoList(set);
            return -e;
        }
        Console.WriteLine("  [4/5] DIF_REGISTERDEVICE OK (DevInst={0})", did.DevInst);
        devInst = did.DevInst;
        bool ok = SetupDiCallClassInstaller(DIF_INSTALLDEVICE, set, ref did); // 按硬件 ID 匹配已暂存的 oem*.inf
        if (!ok) {
            int e = Marshal.GetLastWin32Error();
            Console.WriteLine("  [5/5] DIF_INSTALLDEVICE 失败 Win32={0} ({1})  -> 仍返回 devInst 交给后续触发", e, new System.ComponentModel.Win32Exception(e).Message);
            SetupDiDestroyDeviceInfoList(set);
            return 2;
        }
        Console.WriteLine("  [5/5] DIF_INSTALLDEVICE OK");
        SetupDiDestroyDeviceInfoList(set);
        return 0;
    }
}
'@
    }
}
function Add-Type-CfgMgr {
    if (-not ('CfgMgrSWC' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CfgMgrSWC {
    [DllImport("cfgmgr32.dll", SetLastError=true)]
    public static extern int CM_Setup_DevNode(uint dnDevInst, uint ulFlags);
}
'@
    }
}
function Add-HSADevice {
    param([string]$ClassGuid = $HSA_CLASS_GUID)
    # 0) 清理旧版遗留的未绑定 SWC 设备（SWC\VEN_DOLBY… 与任何 INF 都不匹配，永远显示“未安装驱动”）
    $legacy = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match 'SWC_VEN_DOLBY' }
    foreach ($d in $legacy) {
        Write-Host "移除旧版未绑定 SWC 设备: $($d.InstanceId)"
        & pnputil /remove-device $d.InstanceId /subtree /force | Out-Null
    }
    if (-not (Test-Path $HSA_INF)) { Write-Warn "找不到 HSA INF: $HSA_INF，跳过 SWC 设备创建"; return $false }
    # 1) 暂存驱动包到 DriverStore（Media 类 INF + .cat 签名包，pnputil 校验通过）
    Write-Host "暂存驱动包: $HSA_INF"
    & pnputil /add-driver $HSA_INF
    if ($LASTEXITCODE -ne 0) { Write-Warn "pnputil 暂存失败(rc=$LASTEXITCODE)" }
    # 1b) 确保设备类已安装（类键缺失会导致 SetupDiCreateDeviceInfoW 报 0xE0000205）
    $dcKey = "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceClass\$ClassGuid"
    if (-not (Test-Path $dcKey)) {
        try {
            New-Item -Path $dcKey -Force | Out-Null
            Set-Item -Path $dcKey -Value $HSA_CLASS_NAME
            New-ItemProperty -Path $dcKey -Name 'Class' -PropertyType String -Value $HSA_CLASS_NAME -Force | Out-Null
            New-ItemProperty -Path $dcKey -Name 'ClassGuid' -PropertyType String -Value $ClassGuid -Force | Out-Null
            New-ItemProperty -Path $dcKey -Name 'Icon' -PropertyType String -Value '-5' -Force | Out-Null
            Write-Ok "已补建设备类键 ($dcKey)"
        } catch { Write-Warn "补建设备类键失败: $($_.Exception.Message)" }
    } else { Write-Ok "设备类已安装" }
    # 2) 逐个创建/修复两个 HSA 设备（应用需要：Dolby Atmos + Dolby Audio）
    $ok1 = New-OneHSADevice -DeviceId $HSA_DEVICE_ID  -Desc $HSA_DESC  -ClassGuid $ClassGuid
    $ok2 = New-OneHSADevice -DeviceId $HSA_DEVICE_ID2 -Desc $HSA_DESC2 -ClassGuid $ClassGuid
    # 3) 扫描确认
    & pnputil /scan-devices *
    Start-Sleep -Seconds 3
    $pat = 'ROOT\\DOLBYATMOS|ROOT\\DOLBYAUDIO|ROOT\\MEDIA'
    $after = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match $pat -and $_.FriendlyName -match 'Dolby' }
    if ($after) {
        if (Test-HSABound $after) { Write-Ok "Dolby HSA 设备就绪: $($after.InstanceId -join '; ') (已绑定)" }
        $loose = $after | Where-Object { -not (Test-HSABound @($_)) }
        if ($loose) { Write-Warn "部分 HSA 设备未绑定驱动: $($loose.InstanceId -join '; ')" }
        return ($ok1 -and $ok2)
    }
    Write-Warn "HSA 设备创建未确认（可能需重启后生效）。"
    return $false
}

function Test-HSABound {
    # Get-PnpDevice 对 ROOT 软件设备的 Status=OK 有迷惑性，必须看 Enum 注册表 Driver 值才算绑定
    param($Device)
    foreach ($d in $Device) {
        $rp = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Enum\$($d.InstanceId)" -ErrorAction SilentlyContinue
        if ($rp.Driver) { return $true }
    }
    return $false
}

function New-OneHSADevice {
    param([string]$DeviceId, [string]$Desc, [string]$ClassGuid)
    $idPat = 'ROOT\\' + $DeviceId.ToUpperInvariant()
    # 已存在？
    $exists = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match $idPat -or ($_.InstanceId -match 'ROOT\\MEDIA' -and $_.FriendlyName -eq $Desc) }
    if ($exists) {
        if (Test-HSABound $exists) { Write-Ok "HSA 设备已就绪: $($exists.InstanceId -join '; ')" ; return $true }
        # 已存在但未绑定 → pnputil /install 补绑（DIF_INSTALLDEVICE 可能因 .cat 冲突失败）
        Write-Host "HSA 设备已存在但未绑定: $($exists.InstanceId -join '; ') -> pnputil /install 补绑"
        & pnputil /add-driver $HSA_INF /install
        Start-Sleep -Seconds 2
        $chk = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match $idPat }
        if ($chk -and (Test-HSABound $chk)) { Write-Ok "HSA 设备补绑成功: $($chk.InstanceId)" }
        return $true
    }
    # 2) SetupDi 创建设备（devcon 同款：CreateDeviceInfo -> HWID -> REGISTER -> INSTALL）
    Add-Type-SWCSetup
    $devInst = [uint32]0
    $rc = [SWCSetup]::Create($DeviceId, $Desc, $ClassGuid, [ref]$devInst)
    Write-Host "SWCSetup.Create($DeviceId) rc=$rc (0=成功/已装驱动; 1=已存在; 2=devnode已建但待装; 负数=建前失败)"
    if ($rc -lt 0) { $winerr = -$rc; $msg = $null; try { $msg = [System.ComponentModel.Win32Exception]::new([int]$winerr).Message } catch { }; Write-Warn "创建 HSA 设备 $DeviceId 失败 (Win32 错误 ${winerr}: $msg)"; return $false }
    # 3) 触发 PnP 安装（READY）
    if ($devInst -ne 0) {
        Add-Type-CfgMgr
        $rc2 = [CfgMgrSWC]::CM_Setup_DevNode($devInst, 1)
        Write-Host "CM_Setup_DevNode(READY) rc=$rc2"
    }
    Start-Sleep -Seconds 2
    # 4) DIF_INSTALLDEVICE 可能因 .cat 冲突失败(0xE000020E) -> pnputil /install 兜底绑定
    $chk = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match $idPat }
    if (-not (Test-HSABound $chk)) {
        Write-Host "DIF_INSTALLDEVICE 未绑定 -> pnputil /add-driver /install 兜底 ($DeviceId)"
        & pnputil /add-driver $HSA_INF /install
        Start-Sleep -Seconds 2
    }
    $chk = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match $idPat }
    if ($chk) {
        if (Test-HSABound $chk) { Write-Ok "HSA 设备就绪: $($chk.InstanceId) (已绑定 oem74.inf)" }
        else { Write-Warn "HSA 设备已建但未绑定: $($chk.InstanceId)——多为安全软件(火绒/360)拦驱动安装；可暂停安全软件后重跑本步骤，或重启一次" }
        return $true
    }
    Write-Warn "HSA 设备 $DeviceId 创建未确认（可能需重启后生效）。"
    return $false
}
function Remove-HSADevice {
    $dev = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match 'ROOT\\MEDIA|ROOT\\DOLBYATMOS|ROOT\\DOLBYAUDIO|SWC_VEN_DOLBY' -and $_.FriendlyName -match 'Dolby|DAX3' }
    foreach ($d in $dev) {
        Write-Host "移除 Dolby HSA 设备: $($d.InstanceId)"
        & pnputil /remove-device $d.InstanceId /subtree /force
    }
}

# ---------- INF AddReg 解析（install 用）----------
function Invoke-INFAddReg {
    param([string]$InfPath, [hashtable]$VarMap, [string]$LogPath = $null)
    $lines = Get-Content $InfPath
    $logEntries = New-Object System.Collections.Generic.List[string]
    $strings = @{}; $inStrings = $false
    foreach ($l in $lines) {
        if ($l -match '^\[Strings\]') { $inStrings = $true; continue }
        if ($inStrings -and $l -match '^\[[^\]]+\]') { $inStrings = $false }
        if ($inStrings -and $l -match '^\s*([A-Za-z0-9_]+)\s*=\s*"?(.*?)"?\s*$') { $strings[$matches[1]] = $matches[2] }
    }
    $regSections = @()
    foreach ($l in $lines) { if ($l -match '^\s*AddReg\s*=\s*(.+)$') { $regSections += ($matches[1] -split ',' | ForEach-Object { $_.Trim() }) } }
    $expand = {
        param($v)
        $v = [regex]::Replace($v, '%([A-Za-z0-9_]+)%', {
            param($m) $n = $m.Groups[1].Value
            if ($strings.ContainsKey($n)) { return $strings[$n] }
            if ($VarMap.ContainsKey($n))  { return $VarMap[$n] }
            return $m.Value })
        $v -replace '^"(.*)"$', '$1'
    }
    $applied = 0; $failed = 0
    foreach ($sec in $regSections) {
        $i = ($lines | Select-String -Pattern "^\[$sec\]$").LineNumber
        if (-not $i) { continue }
        for ($j = $i; $j -lt $lines.Count; $j++) {
            $t = $lines[$j].Trim()
            if ($t -eq '') { continue }
            if ($t.StartsWith('[')) { break }
            if ($t.StartsWith(';')) { continue }
            if ($t -notmatch '^HKCR,') { continue }
            $parts = $t -split ',', 5
            $sub   = (& $expand $parts[1].Trim()).TrimEnd('\')
            $name  = if ($parts.Count -ge 3) { (& $expand $parts[2].Trim()) } else { '' }
            $flag  = if ($parts.Count -ge 4) { $parts[3].Trim() } else { '' }
            $val   = if ($parts.Count -ge 5) { & $expand ($parts[4].Trim()) } else { '' }
            $key   = "Registry::HKEY_CLASSES_ROOT\$sub"
            try {
                if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
                $flagN = 0
                if ($flag -match '0x([0-9A-Fa-f]+)') { $flagN = [Convert]::ToInt32($matches[1], 16) }
                if ($name -eq '') {
                    # 空值名 = 设置键的默认值
                    if ($flagN -eq 0x20000) { Set-Item -Path $key -Value ([Environment]::ExpandEnvironmentVariables($val)) }
                    else { Set-Item -Path $key -Value $val }
                }
                elseif ($flagN -eq 0x10001)     { New-ItemProperty -Path $key -Name $name -PropertyType DWord -Value ([Convert]::ToInt32($val,16)) -Force | Out-Null }
                elseif ($flagN -eq 0x20000)     { New-ItemProperty -Path $key -Name $name -PropertyType ExpandString -Value $val -Force | Out-Null }
                elseif ($flagN -eq 0x10008)     { $old=(Get-ItemProperty -Path $key -Name $name -ErrorAction SilentlyContinue).$name; New-ItemProperty -Path $key -Name $name -PropertyType MultiString -Value (@($old)+@($val)) -Force | Out-Null }
                else                            { New-ItemProperty -Path $key -Name $name -PropertyType String -Value $val -Force | Out-Null }
                $applied++
                if ($LogPath) { $logEntries.Add("$sub`t$name`t$val") }
            } catch {
                $failed++
                Write-Warn ("  [注册失败] {0}  ({1})" -f $sub, $_.Exception.Message)
                if ($LogPath) { $logEntries.Add("$sub`t$name`t#FAIL: $($_.Exception.Message)") }
            }
        }
    }
    if ($LogPath -and $logEntries.Count -gt 0) {
        try { [System.IO.File]::WriteAllLines($LogPath, $logEntries.ToArray()) } catch { }
    }
    return [pscustomobject]@{ Applied = $applied; Failed = $failed }
}
# 取 APO 注册的子键列表（uninstall 用）
function Get-APOSubKeys {
    param([string]$InfPath, [hashtable]$VarMap)
    $lines = Get-Content $InfPath
    $strings = @{}; $inStrings = $false
    foreach ($l in $lines) {
        if ($l -match '^\[Strings\]') { $inStrings = $true; continue }
        if ($inStrings -and $l -match '^\[[^\]]+\]') { $inStrings = $false }
        if ($inStrings -and $l -match '^\s*([A-Za-z0-9_]+)\s*=\s*"?(.*?)"?\s*$') { $strings[$matches[1]] = $matches[2] }
    }
    $regSections = @()
    foreach ($l in $lines) { if ($l -match '^\s*AddReg\s*=\s*(.+)$') { $regSections += ($matches[1] -split ',' | ForEach-Object { $_.Trim() }) } }
    $expand = {
        param($v)
        $v = [regex]::Replace($v, '%([A-Za-z0-9_]+)%', {
            param($m) $n = $m.Groups[1].Value
            if ($strings.ContainsKey($n)) { return $strings[$n] }
            if ($VarMap.ContainsKey($n))  { return $VarMap[$n] }
            return $m.Value })
        $v -replace '^"(.*)"$', '$1'
    }
    $subs = New-Object System.Collections.Generic.List[string]
    foreach ($sec in $regSections) {
        $i = ($lines | Select-String -Pattern "^\[$sec\]$").LineNumber
        if (-not $i) { continue }
        for ($j = $i; $j -lt $lines.Count; $j++) {
            $t = $lines[$j].Trim()
            if ($t -eq '') { continue }
            if ($t.StartsWith('[')) { break }
            if ($t.StartsWith(';')) { continue }
            if ($t -notmatch '^HKCR,') { continue }
            $parts = $t -split ',', 5
            $sub = (& $expand $parts[1].Trim()).TrimEnd('\')
            if ($sub -and -not $subs.Contains($sub)) { $subs.Add($sub) }
        }
    }
    return ,$subs
}

# ---------- 卸载 ----------
function Remove-Hookup {
    # 从所有 Realtek 实例上移除 Dolby 挂接
    foreach ($k in Get-RealtekInstances) {
        $d = $k.PSPath
        $p = Get-ItemProperty $d -ErrorAction SilentlyContinue
        if ($p.DaxExtFolder) { Remove-ItemProperty -Path $d -Name 'DaxExtFolder' -ErrorAction SilentlyContinue; Write-Ok "  移除 DaxExtFolder (实例 $($k.PSChildName))" }
        $isKey = Join-Path $d 'InterfaceSetting'
        if (Test-Path $isKey) {
            foreach ($pre in 'ApoPreset1','ApoPreset2') {
                $epKey = Join-Path $isKey "$pre"
                if (Test-Path $epKey) { Remove-Item $epKey -Recurse -Force -ErrorAction SilentlyContinue; Write-Ok "  移除 $pre (实例 $($k.PSChildName))" }
            }
            # 从拓扑列表移除 ApoPreset 引用
            (Get-ItemProperty $isKey).PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' -and $_.Value -is [array] } | ForEach-Object {
                if ($_.Value -contains 'ApoPreset1' -or $_.Value -contains 'ApoPreset2') {
                    $nv = @($_.Value | Where-Object { $_ -ne 'ApoPreset1' -and $_ -ne 'ApoPreset2' })
                    if ($nv.Count -eq 0) { Remove-ItemProperty -Path $isKey -Name $_.Name -ErrorAction SilentlyContinue }
                    else { New-ItemProperty -Path $isKey -Name $_.Name -PropertyType MultiString -Value $nv -Force -ErrorAction SilentlyContinue | Out-Null }
                    Write-Ok "  拓扑 $($_.Name) 已移除 ApoPreset 引用"
                }
            }
        }
    }
}
function Uninstall-Dolby {
    Write-Head "---- 卸载杜比 DAX3 ----"
    & schtasks /delete /tn "DolbyDAXAPI AutoStart" /f 2>$null | Out-Null
    $svc = Get-Service DolbyDAXAPI -ErrorAction SilentlyContinue
    if ($svc) {
        Stop-Service DolbyDAXAPI -Force -ErrorAction SilentlyContinue
        sc.exe delete DolbyDAXAPI | Out-Null
        Write-Ok "  已停止并删除服务 DolbyDAXAPI"
    }
    $varMap = @{ '13' = $canonicalDir }
    $subs = Get-APOSubKeys -InfPath $SWC_INF -VarMap $varMap
    $n = 0
    foreach ($sub in $subs) {
        $key = "Registry::HKEY_CLASSES_ROOT\$sub"
        if (Test-Path $key) { Remove-Item $key -Recurse -Force -ErrorAction SilentlyContinue; $n++ }
    }
    Write-Ok "  已移除 APO 注册键 $n 个"
    Remove-Hookup
    Remove-HSADevice
    $dep = Find-Deployment
    if ($Purge -and $dep) {
        Remove-Item $dep -Recurse -Force -ErrorAction SilentlyContinue
        Write-Ok "  已删除部署目录 $dep"
    }
    Write-Ok "[完成] 卸载完成。可重新运行本脚本全新安装。"
}

# ---------- 安装 Dolby Access（商店应用，含 Dolby Atmos 编码器） ----------
# Dolby Access 是微软商店应用（DolbyLaboratories.DolbyAccess），携带 DolbyHrtfEnc.dll 等
# 空间音效编码器；与旧版独立 DolbyAtmos 不同，新版 Access 已内置全部 Atmos 编码器。
# 安装优先用离线 msix（包内 Appx\DolbyLaboratories.DolbyAccess_*.msix），
# 无离线包则给出微软商店链接（合法授权路径）。
function Install-DolbyAccess {
    Write-Head "---- Dolby Access 应用 ----"
    $acc = Get-AppxPackage -Name 'DolbyLaboratories.DolbyAccess' -ErrorAction SilentlyContinue
    if (-not $acc) {
        try { $acc = Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'DolbyLaboratories.DolbyAccess' } | Select-Object -First 1 } catch { }
    }
    # 离线包版本（用于判断是否值得用离线包重装；包内固定 3.0.2204.0）
    $accxDir = Join-Path $proj 'Appx'
    $accx = Get-ChildItem $accxDir -File -Filter 'DolbyLaboratories.DolbyAccess*.msix' -ErrorAction SilentlyContinue | Select-Object -First 1
    $offlineVer = [version]'0.0.0.0'
    if ($accx) {
        $vm = [regex]::Match($accx.BaseName, '_(\d+\.\d+\.\d+\.\d+)_')
        if ($vm.Success) { try { $offlineVer = [version]$vm.Groups[1].Value } catch { } }
    }
    if ($acc) {
        try { $accVer = [version]$acc.Version } catch { $accVer = $null }
        if (-not $accVer -or $accVer -ge $offlineVer) {
            Write-Ok "Dolby Access 已安装 ($($acc.Version))，跳过"
            if ($accVer -and $offlineVer -gt [version]'0.0.0.0' -and $accVer -gt $offlineVer) {
                Write-Warn "        已装版本高于包内离线版，无需降级；如要更新请用 Microsoft Store。"
            }
            return
        }
    }
    if ($accx) {
        Write-Host "部署 Dolby Access（离线 msix: $($accx.Name)）..."
        # 开启旁加载（离线装 UWP 前提）
        try {
            $u = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
            if (-not (Test-Path $u)) { New-Item -Path $u -Force | Out-Null }
            New-ItemProperty -Path $u -Name 'AllowAllTrustedApps' -PropertyType DWord -Value 1 -Force | Out-Null
            Write-Ok "  已开启旁加载 (AllowAllTrustedApps=1)"
        } catch { Write-Warn "  开启旁加载失败（若应用装不上，请手动开：设置→开发者选项→旁加载应用）" }
        Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(WinStore\.App|WindowsStore|StoreApp)' } | Stop-Process -Force -ErrorAction SilentlyContinue
        $ok = $false; $errMsg = ''
        # msix 自带依赖或系统已有；先直接装，失败再带依赖重试
        try { Add-AppxPackage -Path $accx.FullName -ForceApplicationShutdown -ErrorAction Stop; $ok = $true } catch { $errMsg = $_.Exception.Message }
        if (-not $ok) {
            $deps = @()
            foreach ($dn in 'Microsoft.VCLibs.140.00.appx','Microsoft.NET.Native.Framework.2.2.appx','Microsoft.NET.Native.Runtime.2.2.appx') {
                $dp = Join-Path $accxDir $dn
                if (Test-Path $dp) { $deps += $dp }
            }
            try { Add-AppxPackage -Path $accx.FullName -DependencyPath $deps -ForceApplicationShutdown -ErrorAction Stop; $ok = $true } catch { $errMsg = $_.Exception.Message }
        }
        if ($ok) {
            Write-Ok "Dolby Access 已安装（离线 $($accx.Name)）"
            Write-Warn "        提示：离线包版本可能较旧，建议打开 Microsoft Store 检查更新（应用内也会自动更新）。"
        } else {
            Write-Warn "Dolby Access 离线安装失败: $errMsg"
            Write-Warn "        改用商店安装：ms-windows-store://pdp/?ProductId=9N4M3X3XX4VQ"
        }
    } else {
        Write-Warn "包内未找到 Dolby Access 离线 msix（$accxDir），未安装。"
        Write-Warn "        从微软商店安装（需登录微软账户；Dolby Access 付费授权在账户上）:"
        Write-Warn "        ms-windows-store://pdp/?ProductId=9N4M3X3XX4VQ"
        Write-Host  "        或开始菜单搜索 Microsoft Store → 搜索 \"Dolby Access\" → 安装。"
    }
}

# ---------- 安装 ----------
function Install-Dolby {
    Write-Head "---- 安装杜比 DAX3 ----"
    $instances = @(Get-RealtekInstances)
    if ($instances.Count -eq 0) { Write-Fail "[错误] 未找到任何 Realtek (VEN_10EC) 音频设备实例，无法挂接杜比。"; exit 1 }

    # 部署目录：优先复用已存在部署，否则用规范目录
    $installDir = Find-Deployment
    if (-not $installDir) {
        $installDir = $canonicalDir
        New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    }
    Write-Ok "部署目录: $installDir"

    # 1. 部署 DAX3 组件（缺啥补啥，不覆盖已有）
    if (-not $SWC_INF -or -not (Test-Path $SWC_INF)) {
        Write-Warn "[警告] 未找到 DAX3 驱动包（dax3_swc_aposvc.inf）——请在 Drivers\ThirdParty\swc_factory（或 Drivers\swc_factory）下放入 Dolby 驱动包后重试；跳过组件部署与 APO 注册。"
        return $false
    }
    $nCopy = 0
    foreach ($f in (Get-ChildItem $swcDir -File)) {
        if (-not (Test-Path (Join-Path $installDir $f.Name))) { Copy-Item $f.FullName (Join-Path $installDir $f.Name) -Force; $nCopy++ }
    }
    Write-Ok "DAX3 组件就绪（新补 $nCopy 个）-> $installDir"

    # 2. APO 注册
    $varMap = @{ '13' = $installDir }
    $apoLog = Join-Path $env:TEMP 'setup-dolby-addreg.log'
    $r = Invoke-INFAddReg -InfPath $SWC_INF -VarMap $varMap -LogPath $apoLog
    Write-Ok "已重放 APO 注册 $($r.Applied) 条，失败 $($r.Failed) 条"
    if ($r.Failed -gt 0) { Write-Warn "失败明细见日志: $apoLog" }
    else { Write-Ok "APO 注册日志: $apoLog" }

    # 3. 服务
    $svc = Get-Service DolbyDAXAPI -ErrorAction SilentlyContinue
    if (-not $svc) {
        New-Service -Name DolbyDAXAPI -BinaryPathName "`"$installDir\DAX3API.exe`"" -DisplayName 'Dolby DAX API Service' -Description 'Dolby DAX API Service is used by Dolby DAX applications to control Dolby Atmos components in the system.' -StartupType Automatic | Out-Null
        Write-Ok "已创建服务 DolbyDAXAPI"
    } else {
        $bin = (Get-ServiceInfo).Binary
        $okBin = ($bin -and (Test-Path ($bin -replace '"','')))
        if (-not $okBin) { sc.exe config DolbyDAXAPI binPath= "`"$installDir\DAX3API.exe`"" | Out-Null; Write-Ok "服务二进制路径已修正 -> $installDir\DAX3API.exe" }
        sc.exe config DolbyDAXAPI start= auto | Out-Null
        Write-Ok "服务 DolbyDAXAPI 已设为自动启动"
    }
    # 自启兜底：直接写注册表 Start=2（AUTO_START），防 sc.exe 失败
    try { Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\DolbyDAXAPI' -Name Start -Value 2 -Type DWord -ErrorAction Stop; Write-Ok "服务注册表 Start=2 (开机自启) 已确认" } catch { Write-Warn "服务注册表 Start 写入失败: $($_.Exception.Message)" }
    # 自启兜底2：安全软件(火绒等)会拦截服务配置修改——改用“开机计划任务”在系统启动时拉起服务
    $startVal = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\DolbyDAXAPI' -ErrorAction SilentlyContinue).Start
    if ($startVal -ne 2) {
        $tn = 'DolbyDAXAPI AutoStart'
        & schtasks /create /tn $tn /tr "sc.exe start DolbyDAXAPI" /sc onstart /ru SYSTEM /rl highest /f 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Ok "安全软件拦截了服务自启，已改用『开机计划任务』兜底：$tn" }
        else { Write-Warn "服务自启被拦截且计划任务兜底失败：请在安全软件（火绒等）里放行服务配置修改，或手动将 DolbyDAXAPI 设为自动启动" }
    }
    Start-Service DolbyDAXAPI -ErrorAction SilentlyContinue
    $svcNow = Get-Service DolbyDAXAPI -ErrorAction SilentlyContinue
    Write-Ok "服务当前状态: $($svcNow.Status)"

    # 4. 端点挂接（所有 Realtek 实例，通用拓扑映射）
    $isKeyCreated = $false
    foreach ($k in $instances) {
        $d = $k.PSPath
        $isKey = Join-Path $d 'InterfaceSetting'
        if (-not (Test-Path $isKey)) { New-Item -Path $isKey -Force | Out-Null }
        # 4a. 给已有的“渲染拓扑”值追加 ApoPreset（不硬编码名字）
        $props = (Get-ItemProperty $isKey -ErrorAction SilentlyContinue).PSObject.Properties | Where-Object {
            $_.Name -notmatch '^PS' -and $_.Name -match 'Topo' -and $_.Value -is [array] -and ($_.Value -join ' ') -match 'SysFx' }
        foreach ($pr in $props) {
            $preset = if ($pr.Name -match '(SST3|HAP3|Secondary|Headphone|FrontPanel)') { 'ApoPreset2' } else { 'ApoPreset1' }
            if ($pr.Value -notcontains $preset) {
                New-ItemProperty -Path $isKey -Name $pr.Name -PropertyType MultiString -Value (@($pr.Value)+@($preset)) -Force | Out-Null
                Write-Ok "  拓扑 $($pr.Name) 追加 $preset (实例 $($k.PSChildName))"
            }
        }
        # 4b. ApoPreset EP 指示器 + DaxExtFolder
        foreach ($pre in 'ApoPreset1','ApoPreset2') {
            $epKey = Join-Path $isKey "$pre\EP\0"
            New-Item -ItemType Directory -Path $epKey -Force | Out-Null
            New-ItemProperty -Path $epKey -Name $DP_INDICATOR -PropertyType String -Value $DP_IND_VER -Force | Out-Null
        }
        New-ItemProperty -Path $d -Name 'DaxExtFolder' -PropertyType String -Value $installDir -Force | Out-Null
        Write-Ok "  端点挂接完成 (实例 $($k.PSChildName)) DaxExtFolder=$installDir"
        $isKeyCreated = $true
    }
    if (-not $isKeyCreated) { Write-Warn "  未找到可挂接的拓扑值（可能是非 Realtek APO 驱动）；已写 ApoPreset 指示器 + DaxExtFolder" }

    # 5. 部署调音（本包调音 + 耳机调音）
    $nTun = 0
    if (Test-Path $extDir) {
        Get-ChildItem $extDir -File -Filter '*.xml' | ForEach-Object { if (-not (Test-Path (Join-Path $installDir $_.Name))) { Copy-Item $_.FullName (Join-Path $installDir $_.Name) -Force }; $nTun++ }
    }
    $hdZip = Join-Path $hdTun 'Dolby_DolbyAtmos_zip'
    if (Test-Path $hdZip) {
        $tmp = Join-Path $env:TEMP 'dolby_atmos_hd'
        if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($hdZip, $tmp)
        Get-ChildItem $tmp -File -Filter '*.xml' | ForEach-Object { if (-not (Test-Path (Join-Path $installDir $_.Name))) { Copy-Item $_.FullName (Join-Path $installDir $_.Name) -Force }; $nTun++ }
    }
    Write-Ok "调音就绪（$nTun 个）-> $installDir"

    # 6. 应用（离线部署，已装同版即跳过；-Appx 表示“确保/修复”）
    $appxDir = Join-Path $proj 'Appx'
    $appx = Get-ChildItem $appxDir -File -Filter 'DolbyAtmos*.appx' -ErrorAction SilentlyContinue | Select-Object -First 1
    $app  = Get-AppxPackage -Name 'DolbyLaboratories.DolbyAtmos' -ErrorAction SilentlyContinue
    if (-not $app) {
        # 提权会话可能枚举不到用户级包，补查 -AllUsers
        try { $app = Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'DolbyLaboratories.DolbyAtmos' } | Select-Object -First 1 } catch { }
    }
    if ($app -and -not $Appx) {
        Write-Ok "DolbyAtmos 应用已安装 ($($app.Version))，跳过"
    } elseif ($appx) {
        Write-Host "部署 DolbyAtmos 应用（离线）..."
        # 开启旁加载（离线装 UWP 前提；等同设置里的“旁加载应用”）
        try {
            $u = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
            if (-not (Test-Path $u)) { New-Item -Path $u -Force | Out-Null }
            New-ItemProperty -Path $u -Name 'AllowAllTrustedApps' -PropertyType DWord -Value 1 -Force | Out-Null
            Write-Ok "  已开启旁加载 (AllowAllTrustedApps=1)"
        } catch { Write-Warn "  开启旁加载失败（若应用装不上，请手动开：设置→开发者选项→旁加载应用）" }
        # 关闭商店进程，避免 0x80073D02（要装的包与运行中的 Store 冲突）
        Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(WinStore\.App|WindowsStore|StoreApp)' } | Stop-Process -Force -ErrorAction SilentlyContinue
        $deps = @()
        foreach ($dn in 'Microsoft.VCLibs.140.00.appx','Microsoft.NET.Native.Framework.2.2.appx','Microsoft.NET.Native.Runtime.2.2.appx') {
            $dp = Join-Path $appxDir $dn
            if (Test-Path $dp) { $deps += $dp }
        }
        $ok = $false; $errMsg = ''
        # 先不带依赖装（系统可能已有 VCLibs/.NET Native）
        try { Add-AppxPackage -Path $appx.FullName -ForceApplicationShutdown -ErrorAction Stop; $ok = $true } catch { $errMsg = $_.Exception.Message }
        if (-not $ok -and $deps.Count -gt 0) {
            try { Add-AppxPackage -Path $appx.FullName -DependencyPath $deps -ForceApplicationShutdown -ErrorAction Stop; $ok = $true } catch { $errMsg = $_.Exception.Message }
        }
        if (-not $ok) {
            try { Add-AppxPackage -Path $appx.FullName -DependencyPath $deps -ErrorAction Stop; $ok = $true } catch { $errMsg = $_.Exception.Message }
        }
        if ($ok) { Write-Ok "DolbyAtmos 应用已安装（离线）" }
        else { Write-Warn "应用安装失败: $errMsg （可先关闭 Microsoft Store 再重试；或开启“开发人员模式/旁加载”）" }
    } else { Write-Warn "未找到离线 Appx（$appxDir），跳过应用安装；可从商店安装或使用音效安装器的应用" }

    # 6b. Dolby Access（商店应用，含 Dolby Atmos 空间音效编码器）——完整流程的一部分
    Write-Host ""
    Install-DolbyAccess

    # 7. Dolby SWC 软件设备（HSA 硬件支持声明 + 应用 pfn 关联）
    Write-Host ""
    Write-Head "---- 补建 Dolby SWC 软件设备 ----"
    Add-HSADevice | Out-Null

    # 8. 启动服务
    Start-Service DolbyDAXAPI -ErrorAction SilentlyContinue
    $svc = Get-Service DolbyDAXAPI -ErrorAction SilentlyContinue
    Write-Host "DolbyDAXAPI 状态: $($svc.Status)"

    Write-Host ""
    Write-Ok  "[完成] 杜比 DAX3 已激活（免签名方案）。"
    Write-Warn "下一步：1) 重启电脑让 audiodg/端点生效；2) 打开 Dolby Atmos 应用确认；3) 切换调音用 TuningSwitcher.ps1 -List"
}

# ---------- 诊断 ----------
function Diagnose {
    Write-Head "==== Setup-Dolby 通用诊断 ===="
    $instances = @(Get-RealtekInstances)
    Write-Host "Realtek 设备实例: $($instances.Count) 个"
    foreach ($k in $instances) {
        $p = Get-ItemProperty $k.PSPath
        Write-Host "  实例 $($k.PSChildName): $($p.MatchingDeviceId)"
        Write-Host "    DaxExtFolder: $(if($p.DaxExtFolder){$p.DaxExtFolder}else{'(未设置)'})"
        $isKey = Join-Path $k.PSPath 'InterfaceSetting'
        if (Test-Path $isKey) {
            $topos = (Get-ItemProperty $isKey).PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' -and $_.Name -match 'Topo' }
            Write-Host "    拓扑值: $(if($topos){($topos.Name -join ', ')}else{'(无)'})"
            $pres = Get-ChildItem $isKey -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^ApoPreset' }
            Write-Host "    ApoPreset 子键: $(if($pres){($pres.PSChildName -join ', ')}else{'(无)'})"
        } else { Write-Host "    InterfaceSetting: (无)" }
    }
    $dep = Find-Deployment
    Write-Host "杜比部署目录: $(if($dep){$dep + ' (' + ((Get-ChildItem $dep -File -Recurse).Count) + ' 文件)'}else{'(未找到)'})"
    $svc = Get-ServiceInfo
    Write-Host "服务: $(if($svc){"$($svc.Name) 状态=$($svc.Status) 启动=$($svc.Start) 路径=$($svc.Binary)"}else{'(不存在)'})"
    $clsid0 = 'Registry::HKEY_CLASSES_ROOT\CLSID\{0EBD8505-17BB-4AE7-AD76-E86F99A425E9}'
    Write-Host "APO 注册: $(if(Test-Path $clsid0){'已注册'}else{'未注册'})"
    $swc = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match 'SWC_VEN_DOLBY|VEN_DOLBY' }
    Write-Host "Dolby SWC 软件设备: $(if($swc){($swc.InstanceId -join '; ')}else{'(无)'})"
    $app = Get-AppxPackage -Name 'DolbyLaboratories.DolbyAtmos' -ErrorAction SilentlyContinue
    Write-Host "DolbyAtmos 应用: $(if($app){"已安装 $($app.Version)"}else{'未安装'})"
    $acc = Get-AppxPackage -Name 'DolbyLaboratories.DolbyAccess' -ErrorAction SilentlyContinue
    Write-Host "Dolby Access 应用: $(if($acc){"已安装 $($acc.Version)"}else{'未安装（用 -Access 装）'})"
    Write-Host ""
    Write-Host "若需安装：Setup-Dolby.ps1 （已装则自动卸载重装）；-Uninstall 卸载；-Appx 补 DolbyAtmos；-Access 补 Dolby Access。"
}

# ---------- 入口 ----------
if ($Diagnose) { Diagnose; exit 0 }
if (-not $isAdmin) {
    Write-Warn "需要管理员权限，正在请求提升..."
    Start-Process powershell -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"",
        $(if($Uninstall){'-Uninstall'}else{''}), $(if($Reinstall){'-Reinstall'}else{''}), $(if($Purge){'-Purge'}else{''}), $(if($Appx){'-Appx'}else{''}), $(if($SWC){'-SWC'}else{''}), $(if($Access){'-Access'}else{''}))
    exit 0
}
if ($SWC) { Write-Head "==== 补建 Dolby SWC 软件设备 ===="; Add-HSADevice | Out-Null; exit 0 }
if ($Access) { Install-DolbyAccess; exit 0 }
if ($Uninstall) { Uninstall-Dolby; exit 0 }

# 默认 / -Reinstall：若检测到已有安装（服务或 APO 注册存在），先卸载再重装
$hasExisting = (Get-Service DolbyDAXAPI -ErrorAction SilentlyContinue) -or (Test-Path 'Registry::HKEY_CLASSES_ROOT\CLSID\{0EBD8505-17BB-4AE7-AD76-E86F99A425E9}')
if ($Reinstall -or $hasExisting) {
    if ($hasExisting) { Write-Warn "检测到已有杜比安装，先卸载清理（避免重复），再全新安装。" }
    Uninstall-Dolby
}
Install-Dolby
