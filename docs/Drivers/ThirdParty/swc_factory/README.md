# swc_factory — DAX3 驱动组件目录 / DAX3 driver components

把 Dolby DAX3 软件组件包（从 OEM 驱动包解出）放进**本目录下任意子文件夹**（保持内部结构），工具按文件名自动查找。
Place the Dolby DAX3 SWC package (extracted from an OEM driver pack) in **any sub-folder here** (keep inner structure) — auto-found by filename.

## 需要放什么 / Required files

| 文件 / File | 说明 / Purpose |
|---|---|
| `swc_aposvc_*\dax3_swc_aposvc.inf` | APO 注册 INF，同目录需含全部 DLL/exe / APO registration INF + all DLLs/exes **(必需 / required)** |
| `swc_hsa_*\dax3_swc_hsa.inf` | HSA 软件设备 INF（优先 Media 类）/ HSA software-device INF (Media class preferred) **(必需 / required)** |

典型组件 / Typical components (from the aposvc folder):
```
DolbyDax3Apo.dll    DAX3 主 APO / main APO
DolbyAPOv2100.dll · DolbyAPOv251.dll · DolbyAPONs.dll   各代际 APO / generation APOs
DolbyAPOvlldp.dll (+v120~v150)   低延迟 APO / low-latency APOs
DAX3API.exe · Dax3DapControl.dll · DAXSSID.dll · Dax3Ref.dll · CaptureStreamMonitor.dll
dax3_swc_aposvc.inf / .cat
```

## 放置后效果 / After placing

- 「安装杜比」自动找到 `dax3_swc_aposvc.inf` 并部署 + 重放全部 APO 注册（约 315 条）
- 「修复 SWC 软件设备」自动找到 `dax3_swc_hsa.inf` 创建 Dolby Atmos / Dolby Audio 设备
- 任意版本（3.30201 / 3.30400 …）均可，无需改配置 / any version works, no config change
