# ext — 调音包目录 / Tuning package directory

把 Dolby 调音包（从 OEM 驱动包解出）放进**本目录下任意子文件夹**，工具自动识别。
Place the Dolby tuning package (extracted from an OEM driver pack) **in any sub-folder here** — auto-detected.

## 需要放什么 / Required files

| 文件 / File | 说明 / Purpose |
|---|---|
| `DEV_*.xml` | 调音文件，每个机型一个 / tuning files, one per machine **(必需 / required)** |
| `dax3_ext_rtk.inf` + `.cat` | 扩展 INF 与签名（完整安装用）/ extension INF + catalog (full install) *(可选 / optional)* |
| `operator_settings*.xml/json` | 运营配置（可选）/ operator settings *(optional)* |

## 文件名格式 / Filename format

```
DEV_<声卡ID 4位>_SUBSYS_<子系统 8位十六进制>_PCI_SUBSYS_<xxxx16AA>.xml
DEV_<codec 4-hex>_SUBSYS_<subsystem 8-hex>_PCI_SUBSYS_<xxxx16AA>.xml
```

示例 / Example: `DEV_0257_SUBSYS_17AA3869_PCI_SUBSYS_382017AA.xml`

> 每个调音内 `security-key` 为空 `value=""` 表示「空key」，任意机器可切换；有 key 表示绑定特定机型。
> An empty `security-key value=""` means "key-less" (switchable on any PC); a key binds it to a specific model.

## 放置后效果 / After placing

- 「切换调音」页自动列出全部调音（自动重建缓存）/ Tuning tab lists all tunings (cache auto-rebuilds)
- 「安装杜比」自动部署调音到 `C:\Windows\System32\dolbyaposvc` / Install Dolby deploys them there
- 「自定义调音」以包内调音为模板兜底 / Custom Tuning falls back to package tunings as templates
