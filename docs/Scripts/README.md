# Scripts — 原创脚本（全部内嵌于 exe）/ Original scripts (all embedded in DolbyMaster.exe)

本目录不再存放 .ps1：**7 个原创脚本已编译进 DolbyMaster.exe**，运行时从内存执行
（GZip + `[scriptblock]::Create`，不落盘）；包根经进程环境变量 `DM_BASE` 传入。
安装/卸载 杜比.cmd 也自包含（内嵌 GZip 脚本 + `set DM_BASE`）。
No .ps1 lives here anymore: **all 7 original scripts are embedded in DolbyMaster.exe** and
executed in memory (GZip + scriptblock, never written to disk); the package root travels via
the `DM_BASE` process environment variable. The .cmd launchers are self-contained too.

| 内嵌脚本 / Embedded | 作用 / Purpose |
|---|---|
| `Setup-Dolby.ps1` | 安装 / 强制重装 / 诊断 / 补应用 / 修复 SWC / 卸载 主脚本（exe「安装」「卸载」页 + 两个 .cmd）<br/>Install / force-reinstall / diagnose / app / fix-SWC / uninstall (Install & Uninstall tabs + both .cmd) |
| `APOHook.ps1` | 给指定设备挂接/移除/恢复杜比 APO（「添加设备」页）<br/>attach/remove/restore Dolby APO per device (Devices tab) |
| `TuningSwitcher.ps1` | 切换/恢复/列出调音（「切换调音」页；绑定调音自动转空key）<br/>switch/restore/list tunings (Tuning tab; bound tunings auto-converted to key-less) |
| `CustomTuning.ps1` | 生成自定义调音 XML v2（「自定义调音」页；PEQ/解码/虚拟角度/保护全参数 + Profile 作用域）<br/>generate custom tuning XML v2 (Custom Tuning tab; full params + profile scope) |
| `AutoProfile.ps1` | 按应用自动切档配置（「自动切档」页；编辑 operator_settings.xml + 重启 DolbyDAXAPI）<br/>per-app auto-profile configurator (Auto Profile tab; edits operator_settings.xml + restarts DolbyDAXAPI) |
| `RebuildData.ps1` | 重建 Data 数据文件（「设置」页）<br/>rebuild Data files (Settings tab) |
| `Status.ps1` | 首页状态总览（exe 首页渲染）<br/>home status overview (rendered by Home tab) |

> 源码保留在 src\（本脚本目录）与 src\Scripts\，供开发/自维护使用。
> Sources are kept under src\ for development / self-maintenance.
