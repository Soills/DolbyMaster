# Appx — DolbyAtmos 应用目录（可选）/ DolbyAtmos app packages (optional)

把 DolbyAtmos 应用及其依赖放进本目录，即可离线安装控制应用。
Place the DolbyAtmos app and its dependencies here for offline installation of the control app.

## 需要放什么 / Required files

| 文件 / File | 说明 / Purpose |
|---|---|
| `DolbyAtmos.appx` | Dolby Atmos UWP 控制应用 **(核心 / core)** |
| `Microsoft.VCLibs.140.00.appx` | 依赖（系统没有时）/ dependency (if missing) |
| `Microsoft.NET.Native.Framework.2.2.appx` | 依赖 / dependency |
| `Microsoft.NET.Native.Runtime.2.2.appx` | 依赖 / dependency |

## 放置后效果 / After placing

- 「安装页 → 补装 DolbyAtmos 应用」离线安装
- **不放也不影响 APO 音效**，仅缺少 Dolby Atmos 控制应用（可选）/ skipping this does NOT affect APO sound; only the control app is missing
