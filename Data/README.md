# Data — 数据文件目录 / Data files (deletable — auto-regenerated)

本目录全部文件都可删除；工具会自动重建。All files here are deletable; the tool regenerates them.

| 文件 / File | 内容 / Content | 重建方式 / Regenerate via |
|---|---|---|
| `TuningNames.txt` | 型号映射：每行 `SUBSYS<TAB>型号名` / model map: `SUBSYS<TAB>name` per line | 设置 → 重建数据文件（有 model_map.json 时）/ Settings > Rebuild Data (with model_map.json) |
| `model_map.json` | 型号知识库（可选，删除后型号显示"待查型号"）/ knowledge base (optional; unknown if deleted) | 手写补充 / manual |
| `model_report.txt` | 型号对照说明（纯文档）/ documentation | 重建数据文件 / Rebuild Data |
| `TuningCache.txt` | 调音快扫缓存：每行 `文件名<TAB>[空key]/[绑定]` / fast-scan cache: `file<TAB>[keyless]/[bound]` | 每次进「切换调音」页自动增量重建 / auto-incremental on Tuning tab |

## 格式说明 / Formats

```
# TuningNames.txt（每行一条，SUBSYS 大写，TAB 分隔）
17AA3869<TAB>Yoga 7 14IAL7
17AA3857<TAB>Yoga 7 14ARB7

# TuningCache.txt（文件名与状态，TAB 分隔）
DEV_0257_SUBSYS_17AA3869_PCI_SUBSYS_382017AA.xml<TAB>[空key]
DEV_0287_SUBSYS_17AA3801_PCI_SUBSYS_381C17AA.xml<TAB>[绑定]
```

想补充/修正型号，直接编辑 `TuningNames.txt`，重启 exe 生效。
To add/fix a model, edit `TuningNames.txt` directly; restart the exe.
