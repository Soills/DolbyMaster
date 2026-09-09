<!--
DolbyMaster · 杜比管家 — 双语 README（页内 zh/en 切换，默认中文）
DolbyMaster bilingual README — page-level zh/en toggle. Switch by clicking the links above.
-->
<p align="center"><b>杜比管家 / DolbyMaster</b><br><i>Dolby DAX3 通用安装 / 设备挂接 / 调音切换 / 卸载 · 作者 soil</i></p>

[English](#dolbymaster) | [中文](#杜比管家)

# 杜比管家

> Dolby DAX3 通用管理工具：一键完成 安装 / 设备挂接 / 调音切换 / 卸载，完全独立，离线运行，不上传任何数据。

## 是什么

杜比管家是一个面向 Windows 的 Dolby DAX3 音频管理工具。它把原来分散在驱动包、注册表、APO 和服务里的操作集中到一个图形界面里，可以：

- **安装 / 卸载** Dolby DAX3 组件（含 DolbyAtmos 应用、HSA 软件设备、APO 注册与服务）
- 把 APO **挂接到声卡、USB DAC、蓝牙耳机、HDMI** 等端点
- 在数百个机型调音之间**切换**，或**自定义调音**（图形 EQ、智能 EQ、低音、环绕、对白、PEQ 等）
- 查看**状态仪表盘**：声卡识别 / DAX3 组件 / APO / 服务 / 端点 / 调音 / 空间音效
- 内置 **3D 音频频谱 + 声像方向盘**（WASAPI 环回实时可视化）
- 与 ProfileSwitch 配合，可让不同应用（前台 / 后台）自动切换调音

> 本项目是一个独立、离线、本地工具。所有脚本内嵌于 exe，磁盘不落脚本；配置保存在程序目录 `Settings\settings.txt`。

## 为什么做

Dolby DAX3 通常由 OEM 驱动预装。很多 DIY 用户希望保留杜比，但不想被厂商绑死的调音限制住——例如在游戏里想要更柔和的调音，或在不同设备上使用不同的空间音频设置。本项目把这些能力做成可视化、可备份、可恢复的界面。

## 运行

- 双击 `DolbyMaster.exe`，在 UAC 弹窗点「是」（程序需要管理员权限读写系统音频配置）。
- 首页仪表盘会自动刷新状态；红色 / 黄色项按行内提示去对应页处理。
- **所有修改都会自动备份**，可在「切换调音」/「卸载」页恢复。

> 若无声或异常：先重启 Windows Audio 服务或电脑；再用「恢复/卸载」回滚。

## 功能一览

### 首页
状态仪表盘：声卡识别 / DAX3 组件 / APO 注册 / APO 包装器 / 服务（自启）/ HSA 软件设备 / Dolby 应用 / 端点挂接 / 主输出调音 / 空间音效。绿色=正常，黄色=注意，红色=问题。

### 安装
本机状态检查、安装杜比 / 强制重装、补装 DolbyAtmos 应用、修复 HSA 软件设备；安装时自动把 DolbyDAXAPI 服务设为开机自启。

### 添加设备
自动扫描已插入设备（优先排序并标绿）；给选中的 USB / 蓝牙 / HDMI / 声卡端点加杜比、移除或恢复；提供全局调音目录兜底 / 撤销。

### 切换调音
扫描并列出机型调音（`DEV_xxxx_SUBSYS_xxxxxxxx`），显示子系统与型号名；`[空key]` 可自由切换，`[绑定]` 会自动转空 key 通用调音；随时恢复原调音。型号名可在 `Data\TuningNames.txt` 中补充，重启生效。

### 自定义调音
以已安装调音为模板，叠加参数后生成「空 key」自定义调音（任意机器可切换）：图形 EQ 20 段、智能 EQ、低音、均衡、对白、环绕、解码/虚拟化、角度、喇叭 PEQ、保护、低音提取等；可「生成并保存」或「保存并立即应用」（重启后生效）。

### 自动切档（AutoProfile）
结合 Dolby 的 AutoProfile 与 [ProfileSwitch](ProfileSwitch/)，可按应用 / 前台后台自动切换调音；支持开机自启动与单实例。

### 3D 频谱
WASAPI 环回实时 3D 频谱（Three.js WebView2），附**声像方向盘**：多声道端点可用环绕声道计算含前后的方位，立体声端点仅左右能量偏向（前后在立体声信号中不可分辨，方向盘会如实标注）。

### 设置 / 卸载
界面语言切换、日志系统、打开/清空日志、重建数据文件、卸载杜比 / 卸载并删除部署目录 / 清理全部端点挂接。

## 目录结构

```
DolbyMaster.exe            主程序（x64，自动请求管理员）
Web\3D-Spectrogram-main\   3D 频谱页面（Three.js，注入桥接）
Data\                      型号映射 / 调音缓存（可删除自动重建）
Drivers\ThirdParty\ext\    机型调音库（完整版含驱动安装包）
Settings\settings.txt      程序设置（自动创建）
docs\                      README 等文档副本
src\                       源码 + 构建脚本（干净版可自重建）
```

## 版本

- 版本号 = 构建日期自动生成（窗口标题可见）
- 当前发布：**1.0.2026.0909**
- 产物目录见 `Release\DolbyMaster_<版本>_{完整版,干净版}`

## 构建

开发构建（输出到 `DolbyMaster\`）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File src\build_exe.ps1
```

生成发布包（完整版 + 干净版）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File src\MakeRelease.ps1 -Edition Both
```

干净版自同步源码与构建（删旧拷新）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File src\SyncClean.ps1
```

干净版一键构建（同步源码 → 删除旧 exe → 重新编译）：双击 `build_clean.cmd`。

> 依赖 .NET Framework 4.0 编译器（`csc.exe`，Windows 自带）与 WebView2 运行库（SDK DLL 已随包携带）。

## 致谢 / 第三方库

本项目使用并感谢以下开源项目：

| 项目 | 用途 | 许可 |
|---|---|---|
| [conwayjw97/3D-Spectrogram](https://conwayjw97.github.io/3D-Spectrogram/) | 3D 音频频谱可视化（Web Audio + GLSL + Three.js），经桥接注入 WASAPI 实时数据 | GPL-3.0（许可全文随包分发于 `Web\3D-Spectrogram-main\LICENSE`） |
| [Three.js](https://threejs.org/) | 3D 渲染引擎（含 OrbitControls） | [MIT](https://github.com/mrdoob/three.js/blob/dev/LICENSE) |
| Microsoft **WebView2** | 内嵌 Web 页面宿主（SDK 程序集随包分发） | Microsoft 条款，见 [WebView2 NuGet](https://www.nuget.org/packages/Microsoft.Web.WebView2) |
| Lenovo / Realtek / Dolby 驱动包 | DAX3 APO、机型调音、Appx（完整版安装负载） | 版权归各自厂商，仅用于本机 DIY 安装与恢复 |

频谱页为 **GPL-3.0** 项目，本项目以其作为运行资产分发；如对衍生分发有疑问，请以该仓库的许可声明为准。内置 `docs\` 保留各子目录原始说明副本。

## 安全与免责

- 本工具会修改 Windows 音频 APO、设备注册表、服务与调音配置；不同电脑 / 声卡 / 驱动版本可能不兼容。
- 安装 / 切换 / 卸载前请备份重要数据；首次使用请阅读并确认「使用须知与免责协议」。
- 安装驱动 / 服务可能被安全软件拦截：仅在确认来源可信时临时放行本程序，完成后请恢复安全软件。
- 离线工具，不主动联网，不上传音频或个人数据。

---

<a name="dolbymaster"></a>

# DolbyMaster

> One-click Windows manager for Dolby DAX3: install, attach devices, switch tunings, uninstall. Fully standalone and offline — no telemetry.

## What it is

DolbyMaster centralizes the Dolby DAX3 setup/device/tuning/service operations that are normally scattered across driver packages, registry entries, APOs and services:

- **Install / uninstall** DAX3 components (including the DolbyAtmos app, HSA software device, APO registration and services)
- **Attach** the Dolby APO to codecs, USB DACs, Bluetooth headsets, HDMI endpoints, etc.
- **Switch** between hundreds of OEM machine tunings, or **create your own** (graphic EQ, smart EQ, bass, surround, dialogue, PEQ, etc.)
- **Status dashboard**: codec / DAX3 components / APO / service / endpoints / tuning / spatial audio
- 内置 **3D audio spectrogram + direction dial** (real-time WASAPI loopback visualizer)
- Optional ProfileSwitch companion for per-app / foreground-background auto tuning

> This is an independent, offline, local tool. Scripts are embedded in the exe (nothing written to disk); settings live in `Settings\settings.txt`.

## Why

Dolby DAX3 usually ships with an OEM driver. Many DIY users want Dolby without being locked to the vendor tuning — e.g. a softer gaming profile, or different spatial settings per device. This tool turns those abilities into a visual, backed-up, restorable workflow.

## Run

- Double-click `DolbyMaster.exe` and accept the UAC prompt (admin is required to read/write system audio config).
- The dashboard refreshes automatically; handle red/yellow rows in their tab.
- **Every modification is backed up** and can be restored from the Tuning / Uninstall tabs.

> If audio breaks: restart the Windows Audio service or the PC first, then use Restore/Uninstall to roll back.

## Features

### Home
Status dashboard: codec / DAX3 components / APO registration / APO wrapper / service (autostart) / HSA software device / Dolby app / endpoint attachment / main-output tuning / spatial audio. Green = OK, yellow = attention, red = problem.

### Install
Machine-state check, install / force-reinstall Dolby, re-install the DolbyAtmos app, repair the HSA software device. The DolbyDAXAPI service is set to auto-start during installation.

### Add Device
Scans plugged-in devices (plugged ones first and marked green); attach / remove / restore the Dolby APO on USB / Bluetooth / HDMI / codec endpoints; global tuning-directory fallback and undo.

### Switch Tuning
Scans machine tunings (`DEV_xxxx_SUBSYS_xxxxxxxx`) with subsystem + model names; `[empty-key]` files switch freely, `[bound]` files are converted to empty-key generic tunings automatically; restore the original anytime. Add model names in `Data\TuningNames.txt` and restart.

### Custom Tuning
Use an installed tuning as a template and generate a key-less custom tuning (switchable on any PC): graphic EQ (20 bands), smart EQ, bass, leveler, dialogue, surround, decoder/virtualizer, angles, speaker PEQ, regulator, bass extract, etc. Save only, or save + apply immediately (reboot to take effect).

### Auto Profile
Combine Dolby AutoProfile with [ProfileSwitch](ProfileSwitch/) to switch tunings per app / foreground-background; autostart and single-instance support.

### 3D Spectrum
Real-time WASAPI loopback 3D spectrum (Three.js in WebView2) plus a **direction dial**: multichannel endpoints use surround channels for true front/rear azimuth; stereo endpoints show only L/R energy bias (front/back cannot be recovered from a stereo signal — the dial says so).

### Settings / Uninstall
UI language, logging, open/clear log folder, rebuild data files; uninstall Dolby / uninstall + delete deployment dir / clean all endpoint attachments.

## Layout

```
DolbyMaster.exe            Main exe (x64, auto-elevates)
Web\3D-Spectrogram-main\   3D spectrum page (Three.js, injected bridge)
Data\                      model map / tuning cache (deletable, auto-rebuilt)
Drivers\ThirdParty\ext\    machine tuning library (Full edition bundles drivers)
Settings\settings.txt      app settings (auto-created)
docs\                      extra README copies
src\                       source + build scripts (Clean edition is rebuildable)
```

## Versions

- Version = build date, auto-generated (visible in the window title)
- Current release: **1.0.2026.0909**
- Outputs: `Release\DolbyMaster_<version>_{完整版,干净版}`

## Build

Dev build (outputs to `DolbyMaster\`):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File src\build_exe.ps1
```

Make both release editions:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File src\MakeRelease.ps1 -Edition Both
```

Sync the latest source/build code into the Clean edition (delete old, copy new):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File src\SyncClean.ps1
```

One-click Clean build (sync source → delete old exe → recompile): double-click `build_clean.cmd`.

> Requires the .NET Framework 4.0 compiler (`csc.exe`, ships with Windows) and the WebView2 runtime (SDK DLLs are bundled).

## Credits / Third-party libraries

| Project | Used for | License |
|---|---|---|
| [conwayjw97/3D-Spectrogram](https://conwayjw97.github.io/3D-Spectrogram/) | 3D spectrum visualizer (Web Audio + GLSL + Three.js), bridged to real-time WASAPI data | GPL-3.0 (full text ships with the asset at `Web\3D-Spectrogram-main\LICENSE`) |
| [Three.js](https://threejs.org/) | 3D rendering (incl. OrbitControls) | [MIT](https://github.com/mrdoob/three.js/blob/dev/LICENSE) |
| Microsoft **WebView2** | Embedded web host (SDK assemblies bundled) | Microsoft terms, see [WebView2 NuGet](https://www.nuget.org/packages/Microsoft.Web.WebView2) |
| Lenovo / Realtek / Dolby driver kits | DAX3 APO, machine tunings, Appx (Full-edition install payload) | Copyright belongs to their vendors; used for local DIY install & restore only |

The spectrum page is a **GPL-3.0** project and ships here as runtime asset; for derivative-distribution questions refer to that repository's license. The `docs\` folder preserves each subfolder's original README.

## Safety & disclaimer

- This tool modifies Windows audio APO, device registry, services and tuning config; results vary by PC / codec / driver.
- Back up important data before install / switch / uninstall; read the in-app notice & disclaimer on first launch.
- Security software may block driver/service operations: allow this program temporarily only if you trust the source, then re-enable it.
- Offline tool: no phone-home, no upload of audio or personal data.
