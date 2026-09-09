// DolbyMaster.cs — 杜比管家（通用版）GUI / DolbyMaster (generic) GUI
// 8 页签：首页 / 安装 / 添加设备 / 切换调音 / 自定义调音 / 自动切档 / 设置 / 卸载
// 8 tabs: Home / Install / Devices / Tuning / Custom Tuning / Auto Profile / Settings / Uninstall
// 驱动 Scripts\Setup-Dolby.ps1、APOHook.ps1、TuningSwitcher.ps1 等
// Driver scripts: Scripts\Setup-Dolby.ps1, APOHook.ps1, TuningSwitcher.ps1, etc.
// 界面语言：中文/English 可在「设置」页切换（HKCU 持久化）。UI text is bilingual (zh/en, switchable in Settings).
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;
using System.Xml;
using Microsoft.Win32;

namespace DolbyMaster
{
    static class Program
    {
        [STAThread]
        static void Main(string[] args)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            // 全局异常兜底：任何未处理异常写 error.log，绝不弹 JIT 对话框
            // Global exception guard: write error.log, never show JIT dialogs.
            Application.ThreadException += (s, e) => LogError("全局UI异常/Global UI", e.Exception);
            AppDomain.CurrentDomain.UnhandledException += (s, e) => LogError("全局未处理异常/Unhandled", e.ExceptionObject as Exception);
            LoadSettings();
            LoadLang();
            if (!EnsureConsent()) return;
            var mf = new MainForm();
            // /spectrum 参数：启动后自动切到频谱页并打开浮动窗（快捷方式直达；也用于自动化验证）
            // /spectrum arg: auto-switch to the spectrum tab and open the floating window on startup
            if (args != null && args.Length > 0 && Array.IndexOf(args, "/spectrum") >= 0)
            {
                mf.Shown += (s, e) => mf.AutoOpenSpectrum();
            }
            Application.Run(mf);
        }

        // ---------- 内嵌脚本读取（内存执行，不落盘） / embedded scripts: read-only, executed in memory ----------
        // 6 个原创 .ps1 编译为嵌入资源（DolbyMaster.Scripts.*）。运行时从资源读取脚本体，
        // 通过 -EncodedCommand 在子进程内联执行，磁盘上不生成任何脚本文件。
        // The 6 original .ps1 are embedded as resources; the body is read and executed inline
        // via -EncodedCommand, so no script file is ever written to disk.
        internal static string ReadEmbeddedScript(string file)
        {
            try
            {
                string res = "DolbyMaster.Scripts." + file;
                using (var s = Assembly.GetExecutingAssembly().GetManifestResourceStream(res))
                {
                    if (s == null) return null;
                    using (var r = new StreamReader(s, Encoding.UTF8, true)) return r.ReadToEnd();   // 自动识别/剥离 BOM
                }
            }
            catch { return null; }
        }

        // ---------- 界面语言 / UI language ----------
        internal static string CurrentLang = "zh";   // "zh" | "en"

        // ---------- 设置持久化：Settings\settings.txt（key=value，目录自动创建，干净版可用）----------
        // Settings persistence: Settings\settings.txt (key=value; dir auto-created, works in the clean edition)
        internal static string SettingsFile
        {
            get { return Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Settings", "settings.txt"); }
        }
        internal static void LoadSettings()
        {
            try
            {
                if (!File.Exists(SettingsFile)) return;
                foreach (string line in File.ReadAllLines(SettingsFile))
                {
                    int i = line.IndexOf('=');
                    if (i > 0) _settings[line.Substring(0, i).Trim()] = line.Substring(i + 1).Trim();
                }
            }
            catch { }
        }
        internal static void SaveSettings()
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(SettingsFile));
                var sb = new System.Text.StringBuilder();
                foreach (var kv in _settings) sb.Append(kv.Key).Append('=').Append(kv.Value).Append("\r\n");
                File.WriteAllText(SettingsFile, sb.ToString(), new System.Text.UTF8Encoding(true));
            }
            catch { }
        }
        static Dictionary<string, string> _settings = new Dictionary<string, string>();
        internal static string GetSetting(string key, string def)
        {
            string v;
            return _settings.TryGetValue(key, out v) ? v : def;
        }
        internal static void SetSetting(string key, string value)
        {
            _settings[key] = value;
            SaveSettings();
        }

        static void LoadLang()
        {
            string v = GetSetting("Lang", "");
            if (v != "en" && v != "zh")
            {
                // 兼容旧版注册表 / backward-compat with the old registry key
                try { using (var k = Registry.CurrentUser.OpenSubKey(@"Software\DolbyMaster")) if (k != null) { v = k.GetValue("Lang") as string; if (v != "en" && v != "zh") v = ""; } } catch { v = ""; }
            }
            if (v == "en" || v == "zh") CurrentLang = v;
        }
        internal static void SetLang(string l)
        {
            CurrentLang = (l == "en") ? "en" : "zh";
            SetSetting("Lang", CurrentLang);
            try { using (var k = Registry.CurrentUser.CreateSubKey(@"Software\DolbyMaster")) if (k != null) k.SetValue("Lang", CurrentLang, RegistryValueKind.String); } catch { }
        }
        // 双语文本：按当前语言返回。Bilingual text helper.
        internal static string T(string zh, string en) { return CurrentLang == "en" ? en : zh; }

        static bool EnsureConsent()
        {
            // 已接受或已拒绝过 → 都不再弹、不拦截（拒绝≠退出，只是记一次）；设置文件优先，兼容旧注册表
            if (GetSetting("DisclaimerAccepted", "") == "1") return true;
            if (GetSetting("DisclaimerDeclined", "") == "1") return true;
            const string keyPath = @"Software\DolbyMaster";
            try
            {
                using (RegistryKey k = Registry.CurrentUser.CreateSubKey(keyPath))
                {
                    if (k != null)
                    {
                        object a = k.GetValue("DisclaimerAccepted");
                        if (a != null && Convert.ToInt32(a) == 1) return true;
                        object d = k.GetValue("DisclaimerDeclined");
                        if (d != null && Convert.ToInt32(d) == 1) return true;
                    }
                }
            }
            catch { }
            string text = T(
                "使用前须知\r\n\r\n" +
                "1. 本软件为离线工具，不主动联网、不上传音频或个人数据。\r\n" +
                "2. 本软件会修改 Windows 音频 APO、设备注册表、服务和调音配置；不同电脑、声卡、驱动版本可能不兼容。\r\n" +
                "3. 安装、切换或卸载前请备份重要数据；若无声或异常，请使用“恢复/卸载”并重启 Windows Audio 或电脑。\r\n" +
                "4. 安装驱动/服务可能被安全软件拦截；仅在确认来源可信时，临时暂停拦截或为本程序放行，完成后请立即恢复安全软件。\r\n\r\n" +
                "免责协议：你理解并自愿承担使用本工具造成的兼容性、音频异常、系统配置变化或数据损失风险。作者不对任何直接或间接损失负责。\r\n\r\n" +
                "点击“是”表示已阅读并同意以上须知与免责协议；点击“否”将继续使用（不再提示）。",
                "Before you continue\r\n\r\n" +
                "1. This is an offline tool; it never phones home, uploads audio or personal data.\r\n" +
                "2. It modifies Windows audio APO, device registry, services and tuning config; results may vary by PC / codec / driver.\r\n" +
                "3. Back up important data before install/switch/uninstall; if sound breaks, use Restore/Uninstall and restart Windows Audio or the PC.\r\n" +
                "4. Security software may block driver/service operations; temporarily allow this program only if you trust the source, then re-enable it.\r\n\r\n" +
                "Disclaimer: you understand and voluntarily accept all risk of compatibility, audio failure, system changes or data loss from using this tool. The author is not liable for any direct or indirect loss.\r\n\r\n" +
                "Click Yes to accept and continue; No keeps using the app (won't ask again).");
            DialogResult r = MessageBox.Show(text, T("杜比管家 · 使用须知与免责协议", "DolbyMaster · Notice & Disclaimer"), MessageBoxButtons.YesNo, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2);
            SetSetting(r == DialogResult.Yes ? "DisclaimerAccepted" : "DisclaimerDeclined", "1");
            try
            {
                using (RegistryKey k = Registry.CurrentUser.CreateSubKey(keyPath))
                {
                    if (k != null)
                        k.SetValue(r == DialogResult.Yes ? "DisclaimerAccepted" : "DisclaimerDeclined", 1, RegistryValueKind.DWord);
                }
            }
            catch { }
            return true;   // 无论接受还是拒绝，都不退出程序（拒绝只记一次，下次不再弹）
        }

        internal static void LogError(string where, Exception ex)
        {
            try
            {
                string log = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "error.log");
                File.AppendAllText(log, "[" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "] " + where + "\r\n"
                    + (ex == null ? "(null)" : ex.ToString()) + "\r\n\r\n");
            }
            catch { }
        }

        internal static void SpectrumLog(string line)
        {
            try
            {
                string log = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "spectrum.log");
                File.AppendAllText(log, "[" + DateTime.Now.ToString("HH:mm:ss.fff") + "] " + line + "\r\n");
            }
            catch { }
        }

        // ---------- 日志系统（默认关闭，设置页可开；设置存 Settings\settings.txt，兼容旧注册表）----------
        internal static bool LogEnabled()
        {
            string v = GetSetting("Logging", "");
            if (v == "1") return true;
            if (v == "0") return false;
            try { using (var k = Registry.CurrentUser.OpenSubKey(@"Software\DolbyMaster")) return k != null && Convert.ToInt32(k.GetValue("Logging", 0)) == 1; } catch { return false; }
        }
        internal static void SetLogging(bool on)
        {
            SetSetting("Logging", on ? "1" : "0");
            try { using (var k = Registry.CurrentUser.CreateSubKey(@"Software\DolbyMaster")) if (k != null) k.SetValue("Logging", on ? 1 : 0, RegistryValueKind.DWord); } catch { }
        }
        internal static string LogDir { get { return Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "logs"); } }
        internal static void AppLog(string line)
        {
            if (!LogEnabled()) return;
            try
            {
                string dir = LogDir;
                Directory.CreateDirectory(dir);
                File.AppendAllText(Path.Combine(dir, "DolbyMaster_" + DateTime.Now.ToString("yyyyMMdd") + ".log"),
                    "[" + DateTime.Now.ToString("HH:mm:ss") + "] " + line + "\r\n");
            }
            catch { }
        }
    }

    class MainForm : Form
    {
        const string FX_SET   = "{D04E05A6-594B-4FB6-A80D-01AF5EED7D1D},5";
        const string DOLBY    = "{0EBD8505-17BB-4AE7-AD76-E86F99A425E9}";
        const string RENDER   = @"SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render";
        const string NAMEKEY  = "{a45c254e-df1c-4efd-8020-67d146a850e0},2";   // 友好名
        const string HWKEY    = "{b3f8fa53-0004-438e-9003-51a46e139bfc},6";   // 硬件名 (MBQUART/Realtek/NVIDIA...)
        const string IFKEY    = "{a45c254e-df1c-4efd-8020-67d146a850e0},24";  // 接口 (USB/HDAUDIO/BTHENUM...)
        const string FFKEY    = "{1da5d803-d492-4edd-8c23-e0c0ffee7f0e},0";   // 外形 (扬声器/耳机/HDMI...)
        const string MEDIA    = @"SYSTEM\CurrentControlSet\Control\Class\{4d36e96c-e325-11ce-bfc1-08002be10318}";
        const string TUNING   = @"C:\Windows\System32\dolbyaposvc";

        string Base;
        Dictionary<string, string> TuningNames = new Dictionary<string, string>();
        RichTextBox boxInstall, boxDevice, boxTuning, boxUninstall, boxCustom, boxSettings;
        TabControl tabs;
        Label bottomTip;
        Panel homePanel;
        TableLayoutPanel homeTbl;
        bool homeLoaded = false;
        ListView devList;
        ListView tuneList;
        ComboBox cmbTuningDevice;           // 切换调音页：目标设备筛选 / tuning tab device filter
        List<string[]> tuningRows = new List<string[]>();   // {设备, 文件, 详情, R/U} 原始行 / raw rows
        // ---- 频谱页 / Spectrum tab ----
        SpectrumWebControl specWeb;
        WasapiLoopback specCapture;
        SpectrumForm specForm;
        Label specStatus;                 // 频谱状态文字（当前设备/杜比模块）
        RichTextBox boxSpectrum;
        System.Windows.Forms.Timer specDolbyTimer;
        ComboBox cmbSpecDevice;           // 监视设备选择 / device picker
        List<KeyValuePair<string, string>> specDevices = new List<KeyValuePair<string, string>>();  // 显示名 -> GUID
        // ---- 自定义调音页控件 ----
        TextBox txtCustomName;
        CheckBox chkGeq, chkIeq, chkBass, chkLeveler, chkDialog, chkSurround;
        NumericUpDown[] nudGeq = new NumericUpDown[20];
        ComboBox cmbGeqPreset, cmbIeqPreset, cmbInstalledTuning;
        NumericUpDown nudIeqAmount, nudBassBoost, nudBassCutoff, nudLevelerAmount, nudDialogAmount, nudSurroundBoost;
        // v2：喇叭EQ / 空间与保护（CustomTuning.ps1 v2 全参数）
        CheckBox chkPeq;
        CheckBox[] chkPeqOn = new CheckBox[5];
        NumericUpDown[] nudPeqF0 = new NumericUpDown[5], nudPeqGain = new NumericUpDown[5], nudPeqQ = new NumericUpDown[5];
        ComboBox[] cmbPeqType = new ComboBox[5];
        CheckBox chkSurDec, chkSurVirt, chkHeightVirt, chkMiVirt, chkRegulator, chkMbComp, chkBassExtract;
        NumericUpDown nudVirtFront, nudVirtSurround, nudVirtRear, nudVirtRearH, nudVirtHeight;
        NumericUpDown nudRegRelax, nudBassExtractCutoff;
        ToolTip tipCustom;   // 自定义调音页悬停说明 / hover hints on Custom tab
        ComboBox cmbInstDevFilter;                 // 自定义页：模板设备筛选 / custom tab template device filter
        List<string[]> installedTuningRows = new List<string[]>();   // {显示, 路径, R/U} 全部模板行
        List<string[]> visibleInstalledRows = new List<string[]>();  // 当前筛选后可见行 / currently visible rows
        // ---- 自动切档页控件 / Auto Profile tab ----
        CheckBox chkAutoProf;
        ComboBox cmbAutoDefault, cmbAutoMapProf;
        TextBox txtAutoExe;
        ListView lstAutoApps;
        RichTextBox boxAuto;
        Label lblCustomTpl;                       // 当前模板显示 / current template label
        string customTemplatePath = "";           // 载入的模板（默认=本机生效调音）/ loaded template (default = machine-active)
        readonly int[][] GEQ_PRESETS = {
            new int[]{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0},                     // 平坦
            new int[]{60,50,40,30,20,10,0,0,0,0,0,0,0,0,0,0,0,0,0,0},                 // 低音增强
            new int[]{0,0,0,0,0,0,0,0,0,0,0,0,0,10,20,30,40,50,60,70},                // 高音清晰
            new int[]{0,0,0,0,10,20,30,40,50,60,60,50,40,30,20,10,0,0,0,0},           // 人声突出
            new int[]{50,40,30,20,10,0,-10,-20,-10,0,0,-10,-20,-10,0,10,20,30,40,50}, // 摇滚
            new int[]{30,20,10,0,-10,-20,-30,-20,-10,0,0,-10,-20,-30,-20,-10,0,10,20,30} // 古典
        };
        readonly string[] GEQ_FREQS = { "47", "141", "234", "328", "469", "656", "844", "1k", "1.3k", "1.7k",
                                        "2.3k", "3k", "3.8k", "4.7k", "5.8k", "7.1k", "9k", "11k", "14k", "20k" };

        static string CodecName(string dev)
        {
            switch (dev)
            {
                case "0230": return "ALC230";
                case "0235": return "ALC235";
                case "0256": return "ALC256";
                case "0257": return "ALC257";
                case "0274": return "ALC274";
                case "0287": return "ALC287";
                default: return "DEV_" + dev;
            }
        }

        public MainForm()
        {
            Base = AppDomain.CurrentDomain.BaseDirectory;
            EnsureAppDirs();
            LoadTuningNames();
            Font = new Font("Microsoft YaHei UI", 9.5f);
            ClientSize = new Size(980, 660);
            MinimumSize = new Size(860, 560);
            BuildUI();
            CreateBottomTip();
        }

        // 自动创建应用自管目录（干净版/只拷 exe 也能自愈）：
        // Data=缓存/型号映射，Settings=设置文件，Tunings=本地自定义调音存储（无包内调音库时）
        // Auto-create app-managed dirs (self-healing in the clean edition):
        // Data=caches/model map, Settings=settings file, Tunings=local custom-tuning storage.
        void EnsureAppDirs()
        {
            try
            {
                foreach (string d in new[] {
                    Path.Combine(Base, "Data"),
                    Path.Combine(Base, "Settings"),
                    Path.Combine(Base, "Tunings") })
                    Directory.CreateDirectory(d);
            }
            catch (Exception ex) { Program.LogError("EnsureAppDirs", ex); }
        }

        // 双语短名（内部统一走 Program.T）。Bilingual shorthand.
        string s(string zh, string en) { return Program.T(zh, en); }

        void CreateBottomTip()
        {
            string ver = Assembly.GetExecutingAssembly().GetName().Version.ToString();
            Text = s("杜比管家（通用版）", "DolbyMaster (Generic)") + " v" + ver + "  " + s("作者: soil", "by soil");
            if (bottomTip != null) { Controls.Remove(bottomTip); bottomTip.Dispose(); }
            bottomTip = new Label {
                Dock = DockStyle.Bottom, Height = 22, TextAlign = ContentAlignment.MiddleLeft,
                ForeColor = Color.Gray,
                Text = s("作者: soil   |   版本: v", "by soil  |  v") + ver + s("   |   杜比 DAX3 通用安装/设备/调音管理   |   所有操作自动备份，可恢复",
                    "  |  Dolby DAX3 install / device / tuning manager  |  every action is backed up & restorable")
            };
            Controls.Add(bottomTip);
        }

        // 语言切换后重建全部页签。Rebuild all tabs after language switch.
        void ReloadUI()
        {
            if (IsDisposed || Disposing) return;
            if (InvokeRequired) { try { BeginInvoke((Action)ReloadUI); } catch { } return; }
            try
            {
                if (tabs != null) { Controls.Remove(tabs); tabs.Dispose(); tabs = null; }
                homeLoaded = false;
                BuildUI();
                CreateBottomTip();
            }
            catch (Exception ex) { Program.LogError("ReloadUI", ex); }
        }

        void BuildUI()
        {
            tabs = new TabControl { Dock = DockStyle.Fill };
            tabs.TabPages.Add(BuildHomeTab());      // 0 首页 / Home
            tabs.TabPages.Add(BuildInstallTab());   // 1 安装 / Install
            tabs.TabPages.Add(BuildDeviceTab());    // 2 添加设备 / Devices
            tabs.TabPages.Add(BuildTuningTab());    // 3 切换调音 / Tuning
            tabs.TabPages.Add(BuildSpectrumTab());  // 4 频谱可视化 / Spectrum
            tabs.TabPages.Add(BuildCustomTab());    // 5 自定义调音 / Custom
            tabs.TabPages.Add(BuildAutoTab());      // 6 自动切档 / Auto Profile
            tabs.TabPages.Add(BuildSettingsTab());  // 7 设置 / Settings
            tabs.TabPages.Add(BuildUninstallTab()); // 8 卸载 / Uninstall
            Controls.Add(tabs);
            // 切到对应页签时自动刷新（首页/调音每次进入都刷新；设备首次）。
            // Auto-refresh on tab switch (home/tuning every time; devices once).
            // 事件在全部页签建好后挂接，避免构建期误触发；内部 try/catch 防止任何意外崩溃。
            tabs.SelectedIndexChanged += (s, e) => {
                try
                {
                    if (tabs.SelectedIndex == 0 && !homeLoaded) RefreshHome();
                    if (tabs.SelectedIndex == 2 && devList != null && devList.Items.Count == 0) RefreshDevices();
                    if (tabs.SelectedIndex == 3 && tuneList != null) RefreshTunings();
                }
                catch (Exception ex) { Program.LogError("切页自动刷新/TabRefresh", ex); }
            };
        }

        protected override void OnShown(EventArgs e)
        {
            base.OnShown(e);
            if (!homeLoaded) RefreshHome();   // 打开 exe 首页自动获取状态
        }

        // ---------- Tab 0 首页（状态仪表盘：应用 + 配置） / Home (status dashboard) ----------
        TabPage BuildHomeTab()
        {
            var page = new TabPage(s("首页", "Home"));
            var flow = new FlowLayoutPanel { Dock = DockStyle.Top, AutoSize = true, Padding = new Padding(6) };
            flow.Controls.Add(MkBtn(s("刷新状态", "Refresh"), () => RefreshHome()));
            var tip = new Label {
                Dock = DockStyle.Top, AutoSize = true, Padding = new Padding(6, 4, 6, 2),
                ForeColor = Color.Gray,
                Text = s("状态总览：声卡 / DAX3 组件 / APO / 服务自启 / HSA 设备 / Dolby 应用 / 端点挂接 / 主输出 / 空间音效。红=问题、黄=注意、绿=正常。",
                          "Overview: codec / DAX3 components / APO / service autostart / HSA devices / Dolby app / endpoint hookups / main output / spatial audio. Red=issue, yellow=attention, green=ok.")
            };
            homePanel = new Panel { Dock = DockStyle.Fill, AutoScroll = true, BackColor = Color.White };
            homeTbl = new TableLayoutPanel {
                Dock = DockStyle.Top, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink,
                ColumnCount = 1, BackColor = Color.White, Padding = new Padding(6), Margin = new Padding(0)
            };
            homePanel.Controls.Add(homeTbl);
            page.Controls.Add(homePanel);
            page.Controls.Add(tip);
            page.Controls.Add(flow);
            return page;
        }

        // ---------- 首页：取状态并渲染仪表盘 / Fetch status & render dashboard ----------
        void RefreshHome()
        {
            // 强制在 UI 线程执行（按钮在后台线程调用时转回 UI 线程），避免与切页自动刷新并发
            if (InvokeRequired) { try { BeginInvoke((Action)RefreshHome); } catch { } return; }
            homeLoaded = true;
            string text = RunCapture("Status.ps1", "-Lang " + (Program.CurrentLang == "en" ? "en" : "zh"));
            RenderHome(text);
        }

        void RenderHome(string text)
        {
            if (homeTbl == null || homeTbl.IsDisposed) return;
            if (InvokeRequired) { try { BeginInvoke((Action)(() => RenderHome(text))); } catch { } return; }
            homeTbl.SuspendLayout();
            homeTbl.Controls.Clear();
            homeTbl.RowCount = 0;
            int nOk = 0, nWarn = 0, nErr = 0;
            var rows = new List<string[]>();
            string title = "", meta = "";
            var tips = new List<string>();
            foreach (string line in text.Split('\n'))
            {
                string t = line.Trim();
                if (t.StartsWith("@@ROW@@"))
                {
                    var parts = t.Substring(7).Split('|');
                    if (parts.Length >= 3)
                    {
                        rows.Add(new string[] { parts[0].Trim(), parts[1].Trim(), parts[2].Trim() });
                        if (parts[0].Trim() == "OK") nOk++;
                        else if (parts[0].Trim() == "WARN") nWarn++;
                        else if (parts[0].Trim() == "ERR") nErr++;
                    }
                }
                else if (t.StartsWith("@@TITLE@@")) title = t.Substring(9).Trim();
                else if (t.StartsWith("@@META@@")) meta = t.Substring(8).Trim();
                else if (t.StartsWith("@@TIP@@")) tips.Add(t.Substring(7).Trim());
            }
            int w = Math.Max(320, homePanel.ClientSize.Width - 60);
            // 标题
            if (title.Length > 0) AddHomeCell(new Label { Text = title, AutoSize = true, Font = new Font(Font.FontFamily, 14f, FontStyle.Bold), ForeColor = Color.FromArgb(20, 20, 60) });
            if (meta.Length > 0) AddHomeCell(new Label { Text = meta, AutoSize = true, ForeColor = Color.Gray, Padding = new Padding(0, 0, 0, 6) });
            // 汇总横幅 / summary banner
            string banner; Color bc, fc;
            if (nErr > 0) { banner = s("⚠ 发现 " + nErr + " 个问题 · " + nWarn + " 个注意 — 按各行提示去对应页处理",
                                       "⚠ " + nErr + " issue(s) · " + nWarn + " attention(s) — fix per row hints"); bc = Color.FromArgb(253, 235, 233); fc = Color.FromArgb(179, 38, 30); }
            else if (nWarn > 0) { banner = s("◐ 基本就绪 · " + nWarn + " 个注意项（建议按提示处理）",
                                             "◐ Mostly ready · " + nWarn + " attention(s) — recommended to fix"); bc = Color.FromArgb(254, 247, 224); fc = Color.FromArgb(153, 101, 0); }
            else { banner = s("✔ 全部就绪 · 杜比正常工作", "✔ All ready · Dolby working"); bc = Color.FromArgb(230, 244, 234); fc = Color.FromArgb(30, 110, 60); }
            AddHomeCell(new Label { Text = banner, AutoSize = true, Padding = new Padding(10, 6, 10, 6), BackColor = bc, ForeColor = fc, Font = new Font(Font.FontFamily, 10.5f, FontStyle.Bold), Margin = new Padding(0, 0, 0, 8) });
            // 状态行
            foreach (var r in rows)
            {
                Color c = r[0] == "OK" ? Color.FromArgb(30, 142, 62) : r[0] == "WARN" ? Color.FromArgb(232, 113, 10) : r[0] == "ERR" ? Color.FromArgb(197, 34, 31) : Color.FromArgb(95, 99, 104);
                var row = new TableLayoutPanel { Dock = DockStyle.Top, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, ColumnCount = 3, BackColor = Color.White, Margin = new Padding(0, 0, 0, 4), Padding = new Padding(8, 4, 8, 4) };
                row.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 26));
                row.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 132));
                row.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
                row.Controls.Add(new Label { Text = "●", ForeColor = c, AutoSize = true, Font = new Font(Font.FontFamily, 13f), TextAlign = ContentAlignment.MiddleLeft }, 0, 0);
                row.Controls.Add(new Label { Text = r[1], AutoSize = true, Font = new Font(Font.FontFamily, 10.5f, FontStyle.Bold), ForeColor = Color.FromArgb(30, 30, 30), TextAlign = ContentAlignment.MiddleLeft }, 1, 0);
                // 空间音效行 = 直接入口：点击打开 Windows 声音设置（扬声器属性 → 空间音效）
                // Spatial-audio row = direct entry: click opens Windows Sound settings (device props → Spatial audio).
                Label detail = new Label { Text = r[2], AutoSize = true, ForeColor = Color.FromArgb(70, 70, 70), MaximumSize = new Size(w - 200, 0), TextAlign = ContentAlignment.MiddleLeft };
                if (r[1] == s("空间音效", "Spatial audio"))
                {
                    detail.Text += "   →  " + s("点击打开声音设置", "click to open Sound settings");
                    detail.ForeColor = Color.FromArgb(0, 102, 204);
                    detail.Font = new Font(Font.FontFamily, 10.5f, FontStyle.Underline);
                    detail.Cursor = Cursors.Hand;
                    detail.Click += (ss, ee) => { try { Process.Start("ms-settings:sound"); } catch { } };
                }
                row.Controls.Add(detail, 2, 0);
                homeTbl.Controls.Add(row);
            }
            // 提示
            foreach (string t in tips)
                AddHomeCell(new Label { Text = "💡 " + t, AutoSize = true, ForeColor = Color.FromArgb(120, 120, 120), Padding = new Padding(0, 6, 0, 0) });
            homeTbl.ResumeLayout();
            homeTbl.PerformLayout();
        }

        void AddHomeCell(Label l)
        {
            l.Margin = new Padding(0);
            homeTbl.Controls.Add(l);
        }

        // ---------- Tab 1 安装 / Install ----------
        TabPage BuildInstallTab()
        {
            var page = new TabPage(s("安装", "Install"));
            var tip = new Label {
                Dock = DockStyle.Top, Height = 30, TextAlign = ContentAlignment.MiddleLeft,
                ForeColor = Color.FromArgb(200, 90, 0),
                Font = new Font(Font.FontFamily, 9f, FontStyle.Bold),
                Text = s("⚠ 安装前提示：若安装/驱动绑定被安全软件（火绒、360 等）拦截，请先暂停或退出安全软件再操作。",
                          "⚠ Before install: if security software blocks driver binding, pause/exit it first, then re-enable after.")
            };
            var flow = new FlowLayoutPanel { Dock = DockStyle.Top, AutoSize = true, Padding = new Padding(6) };
            flow.Controls.Add(MkBtn(s("本机状态检查", "Diagnose"), () => Run(boxInstall, ScriptPath("Setup-Dolby.ps1"), "-Diagnose")));
            flow.Controls.Add(MkBtn(s("安装杜比", "Install Dolby"), () => Run(boxInstall, ScriptPath("Setup-Dolby.ps1"), ""), true));
            flow.Controls.Add(MkBtn(s("强制重装（先卸再装）", "Force Reinstall"), () => Run(boxInstall, ScriptPath("Setup-Dolby.ps1"), "-Reinstall"), true));
            flow.Controls.Add(MkBtn(s("补装 DolbyAtmos 应用", "Install DolbyAtmos App"), () => Run(boxInstall, ScriptPath("Setup-Dolby.ps1"), "-Appx")));
            flow.Controls.Add(MkBtn(s("补装 Dolby Access 应用", "Install Dolby Access App"), () => Run(boxInstall, ScriptPath("Setup-Dolby.ps1"), "-Access")));
            flow.Controls.Add(MkBtn(s("修复 SWC 软件设备", "Fix SWC Devices"), () => Run(boxInstall, ScriptPath("Setup-Dolby.ps1"), "-SWC"), true));
            boxInstall = MkBox();
            page.Controls.Add(boxInstall);
            page.Controls.Add(flow);
            page.Controls.Add(tip);
            return page;
        }

        // ---------- Tab 2 添加设备 / Devices ----------
        TabPage BuildDeviceTab()
        {
            var page = new TabPage(s("添加设备", "Devices"));
            devList = new ListView {
                Dock = DockStyle.Top, Height = 320, FullRowSelect = true, View = View.Details, MultiSelect = false
            };
            devList.Columns.Add(s("设备", "Device"), 180);
            devList.Columns.Add(s("硬件", "Hardware"), 190);
            devList.Columns.Add(s("类型", "Type"), 120);
            devList.Columns.Add(s("状态", "State"), 70);
            devList.Columns.Add(s("杜比", "Dolby"), 60);
            devList.Columns.Add("GUID", 120);

            var flow = new FlowLayoutPanel { Dock = DockStyle.Top, AutoSize = true, Padding = new Padding(6) };
            flow.Controls.Add(MkBtn(s("刷新设备列表", "Refresh Devices"), () => RefreshDevices()));
            flow.Controls.Add(MkBtn(s("给选中设备加杜比", "Add Dolby to Selected"), () => DeviceAction("-Add")));
            flow.Controls.Add(MkBtn(s("移除选中设备杜比", "Remove Dolby"), () => DeviceAction("-Remove")));
            flow.Controls.Add(MkBtn(s("恢复选中设备", "Restore Selected"), () => DeviceAction("-Restore")));
            flow.Controls.Add(MkBtn(s("全局调音目录兜底", "Global Tuning Fallback"), () => Run(boxDevice, "APOHook.ps1", "-TuningAll")));
            flow.Controls.Add(MkBtn(s("撤销全局调音目录", "Undo Global Tuning"), () => Run(boxDevice, "APOHook.ps1", "-TuningRemoveAll")));
            boxDevice = MkBox();
            page.Controls.Add(boxDevice);
            page.Controls.Add(flow);
            page.Controls.Add(devList);
            return page;
        }

        // ---------- Tab 3 切换调音 / Tuning ----------
        TabPage BuildTuningTab()
        {
            var page = new TabPage(s("切换调音", "Tuning"));
            // 顶部：目标设备选择（前面可先选设备，再选调音）/ device filter at top
            var devFlow = new FlowLayoutPanel { Dock = DockStyle.Top, AutoSize = true, Padding = new Padding(6) };
            devFlow.Controls.Add(new Label { Text = s("目标设备:", "Device:"), AutoSize = true, Margin = new Padding(4, 9, 2, 0) });
            cmbTuningDevice = new ComboBox { Width = 240, DropDownStyle = ComboBoxStyle.DropDownList, Margin = new Padding(4) };
            cmbTuningDevice.Items.Add(s("全部（Realtek + USB/蓝牙）", "All (Realtek + USB/BT)"));
            cmbTuningDevice.Items.Add("Realtek");
            cmbTuningDevice.Items.Add(s("USB/蓝牙", "USB/BT"));
            cmbTuningDevice.SelectedIndex = 0;
            cmbTuningDevice.SelectedIndexChanged += (ss2, ee2) => { try { ApplyTuningFilter(); } catch { } };
            devFlow.Controls.Add(cmbTuningDevice);
            devFlow.Controls.Add(MkBtn(s("刷新调音列表", "Refresh Tuning List"), () => RefreshTunings()));
            devFlow.Controls.Add(MkBtn(s("切换选中调音", "Switch Selected"), () => TuningAction("-Switch")));
            devFlow.Controls.Add(MkBtn(s("恢复原调音", "Restore Original"), () => Run(boxTuning, "TuningSwitcher.ps1", "-Restore")));
            devFlow.Controls.Add(MkBtn(s("详情（当前状态）", "Details (Status)"), () => Run(boxTuning, "TuningSwitcher.ps1", "-List")));
            devFlow.Controls.Add(MkBtn(s("USB 调音状态", "USB Tuning Status"), () => Run(boxTuning, "TuningSwitcher.ps1", "-ListUsb")));
            // 列表用 ListView 列裁剪，长文件名不再横向溢出 / columns clip; no horizontal overflow
            tuneList = new ListView { Dock = DockStyle.Top, Height = 320, FullRowSelect = true, View = View.Details, MultiSelect = false, HideSelection = false };
            tuneList.Columns.Add(s("设备", "Device"), 130);
            tuneList.Columns.Add(s("调音文件", "Tuning file"), 320);
            tuneList.Columns.Add(s("型号 / 状态", "Model / state"), 300);
            boxTuning = MkBox();
            page.Controls.Add(boxTuning);
            page.Controls.Add(tuneList);
            page.Controls.Add(devFlow);
            return page;
        }

        // ---------- Tab 4 频谱可视化 / Spectrum ----------
        TabPage BuildSpectrumTab()
        {
            var page = new TabPage(s("频谱可视化", "Spectrum"));
            var tip = WrapTip(s("实时监视当前默认播放设备输出的声音（含 Dolby APO 处理后的混音）。" +
                          "打开「浮动窗」可置顶显示；杜比状态行显示 audiodg 加载的 Dolby 模块，可观察杜比处理是否随播放正常挂载。",
                          "Watch the current default render device output in real time (post-Dolby APO mix). " +
                          "Open the floating window for a pinnable view; the Dolby row shows which Dolby modules audiodg loaded — see if Dolby processing holds up."));
            var flow = new FlowLayoutPanel { Dock = DockStyle.Top, AutoSize = true, Padding = new Padding(6) };
            flow.Controls.Add(new Label { Text = s("监视设备:", "Device:"), AutoSize = true, Margin = new Padding(4, 9, 2, 0) });
            cmbSpecDevice = new ComboBox { Width = 300, DropDownStyle = ComboBoxStyle.DropDownList, Margin = new Padding(4) };
            cmbSpecDevice.SelectedIndexChanged += (ss3, ee3) => { try { OnSpecDeviceChanged(); } catch (Exception ex) { Program.LogError("设备切换/SpecDevice", ex); } };
            flow.Controls.Add(cmbSpecDevice);
            flow.Controls.Add(MkBtn(s("刷新设备", "Refresh Devices"), () => RefreshSpecDevices()));
            flow.Controls.Add(MkBtn(s("开始监视", "Start Monitor"), () => StartSpectrum(true)));
            flow.Controls.Add(MkBtn(s("停止监视", "Stop Monitor"), () => StopSpectrum()));
            flow.Controls.Add(MkBtn(s("打开浮动窗", "Open Floating"), () => OpenSpectrumForm(), true));
            flow.Controls.Add(MkBtn(s("刷新杜比模块", "Refresh Dolby"), () => RefreshDolbyStatus()));
            chkSpecInvert = new CheckBox { Text = s("反转左右", "Invert L/R"), AutoSize = true, Margin = new Padding(12, 9, 0, 0), Checked = Program.GetSetting("SpecInvert", "1") != "0" };
            specInvert = chkSpecInvert.Checked;   // 初始值同步（CheckedChanged 此时尚未挂上）/ sync initial value (handler not wired yet)
            chkSpecInvert.CheckedChanged += (ss3, ee3) => { try { specInvert = chkSpecInvert.Checked; Program.SetSetting("SpecInvert", specInvert ? "1" : "0"); } catch { } };
            flow.Controls.Add(chkSpecInvert);
            specStatus = new Label {
                Dock = DockStyle.Top, AutoSize = false, Height = 26, Padding = new Padding(6, 5, 6, 0),
                ForeColor = Color.FromArgb(220, 220, 235), BackColor = Color.FromArgb(28, 32, 46),
                Text = s("未监视。点「开始监视」查看当前设备频谱。", "Not monitoring. Click Start Monitor.")
            };
            specWeb = new SpectrumWebControl { Dock = DockStyle.Fill };
            boxSpectrum = MkBox();
            boxSpectrum.Height = 120;
            boxSpectrum.Dock = DockStyle.Bottom;
            page.Controls.Add(boxSpectrum);
            page.Controls.Add(specWeb);
            page.Controls.Add(specStatus);
            page.Controls.Add(tip);
            page.Controls.Add(flow);
            // 定时刷新杜比模块状态（每 3 秒，仅本页可见时） / periodic Dolby status (3s, while visible)
            specDolbyTimer = new System.Windows.Forms.Timer { Interval = 3000 };
            specDolbyTimer.Tick += (ss2, ee2) => { try { if (tabs != null && tabs.SelectedIndex == 4) { RefreshDolbyStatus(); SpecAutoHeal(); } } catch { } };
            specDolbyTimer.Start();
            RefreshSpecDevices();   // 初始填充设备下拉 / initial device list
            return page;
        }

        void RefreshSpecDevices()
        {
            // 列出激活渲染端点（GUID + 注册表友好名），填入设备下拉；首项=默认设备。
            // List active render endpoints (GUID + friendly name) into the picker; first = default.
            try
            {
                if (cmbSpecDevice == null || cmbSpecDevice.IsDisposed) return;
                string prev = (cmbSpecDevice.SelectedIndex >= 0 && cmbSpecDevice.SelectedIndex < specDevices.Count)
                    ? specDevices[cmbSpecDevice.SelectedIndex].Value : "";
                cmbSpecDevice.Items.Clear();
                specDevices.Clear();
                // 默认设备 / default device
                specDevices.Add(new KeyValuePair<string, string>(s("（默认设备）", "(default device)"), ""));
                // 激活端点：COM 枚举拿完整 MMDevice ID（{0.0.0.00000000}.{GUID}，GetDevice 必需），
                // 注册表 MMDevices 只存裸 {GUID}，直接传会 E_INVALIDARG。
                // Active endpoints: COM enumeration gives the full MMDevice ID (required by GetDevice);
                // the MMDevices registry key stores only the bare {GUID} which fails with E_INVALIDARG.
                try
                {
                    foreach (string id in WasapiLoopback.EnumRenderDevices())
                    {
                        string disp = id;
                        var mg = Regex.Match(id, @"\{[0-9A-Fa-f-]+\}$");
                        if (mg.Success)
                        {
                            string guid = mg.Value;
                            using (var kp = Registry.LocalMachine.OpenSubKey(RENDER + "\\" + guid + "\\Properties"))
                            {
                                if (kp != null)
                                {
                                    string name = kp.GetValue(NAMEKEY) as string ?? "";
                                    string hw = kp.GetValue(HWKEY) as string ?? "";
                                    string itf = kp.GetValue(IFKEY) as string ?? "";
                                    if (name.Length == 0) name = guid;
                                    disp = name + (hw.Length > 0 ? "  [" + hw + "]" : "");
                                    if (itf.Length > 0) disp += "  (" + itf + ")";
                                }
                            }
                        }
                        specDevices.Add(new KeyValuePair<string, string>(disp, id));
                    }
                }
                catch { }
                foreach (var d in specDevices) cmbSpecDevice.Items.Add(d.Key);
                // 恢复之前的选中 / restore previous selection
                int sel = 0;
                if (prev.Length > 0)
                    for (int i = 0; i < specDevices.Count; i++)
                        if (specDevices[i].Value == prev) { sel = i; break; }
                if (cmbSpecDevice.Items.Count > 0) cmbSpecDevice.SelectedIndex = sel;
                Append(boxSpectrum, s("[设备] 找到 ", "[Devices] found ") + specDevices.Count + s(" 个可选监视端点。", " selectable endpoints."));
            }
            catch (Exception ex) { Program.LogError("RefreshSpecDevices", ex); }
        }

        void OnSpecDeviceChanged()
        {
            // 切换监视设备：若正在监视则按新设备重启捕获
            // Device switch: if monitoring, restart capture on the newly picked device.
            try
            {
                string guid = (cmbSpecDevice.SelectedIndex >= 0 && cmbSpecDevice.SelectedIndex < specDevices.Count)
                    ? specDevices[cmbSpecDevice.SelectedIndex].Value : "";
                if (specCapture != null)
                {
                    bool wasOn = specCapture.GotData;
                    specCapture.Stop();
                    specCapture = null;
                    if (wasOn || true)
                    {
                        specCapture = new WasapiLoopback { TargetDeviceId = guid };
                        specCapture.DataReady += OnSpecData;
                        specCapture.Start();
                        Append(boxSpectrum, s("[设备] 已切换监视到: ", "[Device] now monitoring: ") +
                            (cmbSpecDevice.SelectedItem != null ? cmbSpecDevice.SelectedItem.ToString() : guid));
                        UpdateSpecStatus();
                    }
                }
                else
                {
                    // 未在监视：仅记录选择，开始监视时生效 / not monitoring: record choice
                    Append(boxSpectrum, s("[设备] 已选择: ", "[Device] selected: ") +
                        (cmbSpecDevice.SelectedItem != null ? cmbSpecDevice.SelectedItem.ToString() : guid) +
                        s("（点「开始监视」生效）", " (click Start Monitor)"));
                }
            }
            catch (Exception ex) { Program.LogError("OnSpecDeviceChanged", ex); }
        }

        string SelectedSpecGuid()
        {
            // 设备下拉选中的 GUID（空=默认设备）/ GUID from the device picker (empty = default)
            try
            {
                if (cmbSpecDevice != null && cmbSpecDevice.SelectedIndex >= 0 && cmbSpecDevice.SelectedIndex < specDevices.Count)
                    return specDevices[cmbSpecDevice.SelectedIndex].Value;
            }
            catch { }
            return "";
        }

        void StartSpectrum(bool log)
        {
            try
            {
                string guid = SelectedSpecGuid();
                if (specCapture == null)
                {
                    specCapture = new WasapiLoopback { TargetDeviceId = guid };
                    specCapture.DataReady += OnSpecData;
                }
                if (specCapture != null && !specCapture.GotData)
                {
                    specCapture.TargetDeviceId = guid;
                    specCapture.Start();
                    if (log) Append(boxSpectrum, s("[频谱] 开始捕获 ", "[Spectrum] capturing ") +
                        (guid.Length > 0 && cmbSpecDevice.SelectedItem != null ? cmbSpecDevice.SelectedItem.ToString() : s("默认播放设备", "default render device")) + "...");
                }
                else if (specCapture != null)
                {
                    specCapture.Stop();
                    specCapture = null;
                    specCapture = new WasapiLoopback { TargetDeviceId = guid };
                    specCapture.DataReady += OnSpecData;
                    specCapture.Start();
                    if (log) Append(boxSpectrum, s("[频谱] 重新开始捕获...", "[Spectrum] restarted capture..."));
                }
                UpdateSpecStatus();
            }
            catch (Exception ex) { Program.LogError("StartSpectrum", ex); Append(boxSpectrum, s("[错误] ", "[Error] ") + ex.Message); }
        }

        void StopSpectrum()
        {
            try
            {
                if (specCapture != null) { specCapture.Stop(); }
                specStatus.Text = s("已停止。", "Stopped.");
                if (specWeb != null && !specWeb.IsDisposed) specWeb.PushStop();
                if (specForm != null && !specForm.IsDisposed) specForm.Host.PushStop();
                Append(boxSpectrum, s("[频谱] 已停止监视。", "[Spectrum] monitoring stopped."));
            }
            catch (Exception ex) { Program.LogError("StopSpectrum", ex); }
        }

        void OnSpecData(float[] samples)
        {
            try
            {
                // FFT → 1024 bins(0-255 绝对dB) → 推给 WebView2 原版 3D-Spectrogram（后台线程，PostWebMessageAsJson 线程安全）
                // FFT -> 1024 bins (0-255, absolute dB) -> push into the original WebView2 3D-Spectrogram
                int rate = specCapture != null ? specCapture.SampleRate : 48000;
                byte[] bins = SpecBins(samples, rate);
                if (specWeb != null && !specWeb.IsDisposed) specWeb.PushSpectrum(bins);
                if (specForm != null && !specForm.IsDisposed) specForm.PushSpectrum(bins);
                // 声像方向：L/R RMS → pan(-1..1)，低通平滑 + 去恒定偏置。
                // Dolby HRTF/空间化会给 L/R 一个固定增益差（本机实测 L 恒比 R 高约 10%），
                // 若不扣除，指针会一直偏向一侧（"什么音频都一个方向"）。
                // 用慢速平均吸收该偏置：指针居中于常态声像，只响应内容的相对左右偏移。
                // Stereo pan from L/R RMS, low-pass smoothed, constant-bias removed.
                // Dolby HRTF gives L/R a fixed gain offset (measured ~10% L>R here); without
                // subtracting it the needle pins to one side. A slow average absorbs that bias
                // so the needle centres on the常态 image and only reacts to relative shifts.
                if (specCapture != null)
                {
                    // 方位角：多声道（≥6ch，5.1/7.1 有独立环绕声道）→ 算真方位（0°前/±180°后），
                    // 立体声（只有 L/R）→ 仅 ±90° 前弧（前后信息在信号里不存在）。
                    // azimuth: multichannel uses surround channels (incl. rear) -> true 360°;
                    // stereo has only L/R -> front ±90° arc (front/back simply not in the signal).
                    float angle;
                    bool multi = specCapture.Channels >= 6 && specCapture.ChanRms != null && specCapture.ChanRms.Length >= 6;
                    if (multi)
                    {
                        float[] cr = specCapture.ChanRms;   // 声道序：FL FR FC LFE BL BR SL SR
                        float fl = cr[0], fr = cr[1], fc = cr[2], bl = cr[4], br = cr[5];
                        float sl = cr.Length > 6 ? cr[6] : 0f, sr = cr.Length > 6 ? cr[7] : 0f;
                        float front = fl * fl + fr * fr + fc * fc;
                        float back = bl * bl + br * br + sl * sl + sr * sr;
                        float left = fl * fl + bl * bl + sl * sl;
                        float right = fr * fr + br * br + sr * sr;
                        float fb = (front - back) / (front + back + 1e-5f);
                        float lr = (left - right) / (left + right + 1e-5f);
                        float raw = (float)(Math.Atan2(lr, fb) * 180.0 / Math.PI);
                        _specAngle = _specAngle * 0.75f + raw * 0.25f;
                        angle = _specAngle;
                        if (specInvert) angle = -angle;
                    }
                    else
                    {
                        // 立体声：L/R 能量差 + 低通平滑 + 去恒定偏置，映射到 ±90° 前弧。
                        // Dolby HRTF 给 L/R 一个固定增益差（本机实测 L 恒比 R 高约 10%），
                        // 若不扣除指针会一直偏向一侧；慢速平均只在近中心时更新，持续声像不会被吃掉。
                        float l = specCapture.LeftRms, r = specCapture.RightRms;
                        float pan = (l + r) < 1e-5f ? 0f : (l - r) / (l + r);
                        if (pan < -1f) pan = -1f; if (pan > 1f) pan = 1f;
                        if (specInvert) pan = -pan;   // USB 端点环回可能通道对调，默认反转，可勾掉
                        _specPan = _specPan * 0.75f + pan * 0.25f;
                        if (Math.Abs(_specPan) < 0.12f)
                            _specPanAvg = _specPanAvg * 0.995f + _specPan * 0.005f;
                        float centered = _specPan - _specPanAvg;
                        if (centered < -1f) centered = -1f; if (centered > 1f) centered = 1f;
                        // 灵敏度曲线：小偏移放大 / amplify small offsets near center
                        angle = centered >= 0f ? 90f * (float)Math.Sqrt(centered) : -90f * (float)Math.Sqrt(-centered);
                    }
                    if (specWeb != null && !specWeb.IsDisposed) specWeb.PushPan(angle, multi);
                    if (specForm != null && !specForm.IsDisposed) specForm.PushPan(angle, multi);
                }
            }
            catch (Exception ex) { Program.LogError("OnSpecData", ex); }
        }
        float _specPan;      // 平滑后的声像（立体声）/ smoothed pan (stereo)
        float _specPanAvg;   // 慢速平均（吸收恒定偏置）/ slow average (absorbs constant bias)
        float _specAngle;    // 平滑后的方位角（多声道，度）/ smoothed azimuth (multichannel, degrees)
        bool specInvert;     // 反转左右（部分 USB 端点环回通道对调）/ invert L/R (some USB endpoints loop back swapped)
        CheckBox chkSpecInvert;

        // FFT 幅值 → 1024 bins 0-255（绝对 dBFS 映射）。
        // 播放/视频场景：范围 -90..-10 dBFS（原 -100..-30 是录音风格，播放峰值常在 -30 以上会整体饱和，
        // 导致频谱恒顶满、能量恒 1.0，方向盘也看不出内容差异）。
        // FFT magnitudes -> 1024 bins 0-255 (absolute dBFS).
        // Playback/video range: -90..-10 dBFS (the old -100..-30 was recording-style; playback peaks
        // sit above -30 dBFS so everything saturated, flattening both the terrain and the head dial).
        byte[] SpecBins(float[] samples, int rate)
        {
            try
            {
                float[] dbs = Fft.ComputeDb(samples);      // Size=4096 → 2048 bins (absolute dBFS)
                var bins = new byte[1024];
                for (int i = 0; i < 1024; i++)
                {
                    float db = dbs[i * 2];
                    if (i * 2 + 1 < dbs.Length && dbs[i * 2 + 1] > db) db = dbs[i * 2 + 1];
                    if (db < -90f) db = -90f; if (db > -10f) db = -10f;
                    bins[i] = (byte)((db + 90f) / 80f * 255f);    // -90..-10 → 0..255
                }
                return bins;
            }
            catch { return new byte[1024]; }
        }

        void UpdateSpecStatus()
        {
            try
            {
                if (specStatus == null || specStatus.IsDisposed) return;
                string dev = (cmbSpecDevice != null && cmbSpecDevice.SelectedItem != null)
                    ? cmbSpecDevice.SelectedItem.ToString()
                    : ((specCapture != null && specCapture.DeviceName.Length > 0) ? specCapture.DeviceName : s("(读取中)", "(reading)"));
                string err = (specCapture != null && specCapture.LastError.Length > 0) ? "  [" + specCapture.LastError + "]" : "";
                specStatus.Text = s("监视设备: ", "Device: ") + dev + "  ·  " +
                    s("采样率 ", "rate ") + (specCapture != null ? specCapture.SampleRate.ToString() : "?") + "Hz" + err;
            }
            catch { }
        }

        void RefreshDolbyStatus()
        {
            try
            {
                if (specStatus == null || specStatus.IsDisposed) return;
                string dev = (cmbSpecDevice != null && cmbSpecDevice.SelectedItem != null)
                    ? cmbSpecDevice.SelectedItem.ToString()
                    : ((specCapture != null && specCapture.DeviceName.Length > 0) ? specCapture.DeviceName : "?");
                // 查 audiodg 加载的 Dolby 模块（空间音效/APO 是否挂载）/ Dolby modules in audiodg
                var mods = new List<string>();
                bool hasHrtf = false;
                try
                {
                    foreach (Process p in Process.GetProcessesByName("audiodg"))
                    {
                        foreach (ProcessModule m in p.Modules)
                        {
                            string fn = m.ModuleName;
                            if (fn != null && fn.IndexOf("Dolby", StringComparison.OrdinalIgnoreCase) >= 0)
                            {
                                mods.Add(fn);
                                if (fn.IndexOf("HrtfEnc", StringComparison.OrdinalIgnoreCase) >= 0) hasHrtf = true;
                            }
                        }
                    }
                }
                catch { }
                string dolbyTxt = mods.Count > 0 ? string.Join(" / ", mods) : s("(无 Dolby 模块)", "(no Dolby modules)");
                // 实时音频活性：捕获中 && 最近 1.2s 有数据 && 峰值>0.001 → 播放中
                // Live activity: capturing && data within last 1.2s && peak>0.001 -> playing
                bool capturing = (specCapture != null);
                bool live = false;
                if (capturing)
                {
                    long now = DateTime.UtcNow.Ticks;
                    live = (now - specCapture.LastDataTick) < TimeSpan.FromSeconds(1.2).Ticks && specCapture.CurrentPeak > 0.001f;
                }
                // 系统级活性（默认设备是否在响，独立于我们监视哪台设备）
                // system-level activity (default device making sound, independent of which device we monitor)
                float sysPeak = WasapiLoopback.DefaultDevicePeak();
                bool sysLive = sysPeak > 0.001f;
                string state;
                if (!capturing) state = s("未监视", "not monitoring");
                else if (live) state = s("播放中 ✓", "playing ✓");
                else state = s("该设备静音", "device silent");
                specStatus.Text = s("监视设备: ", "Device: ") + dev + "  ·  " + s("状态: ", "state: ") + state +
                    (sysLive ? s("  |  系统默认设备: 有声(峰值 ", "  |  default device: sound(peak ") + sysPeak.ToString("F2") + ")" : s("  |  系统默认设备: 静音", "  |  default device: silent")) +
                    "  |  " + s("杜比模块(audiodg): ", "Dolby modules (audiodg): ") + dolbyTxt +
                    (hasHrtf ? s("  ✓空间音效编码器已加载", "  ✓spatial encoder loaded") : "");
                // 日志：杜比模块列表变化时记录 / log module list changes
                string key = string.Join(",", mods);
                if (key != _lastDolbyMods)
                {
                    _lastDolbyMods = key;
                    Append(boxSpectrum, s("[杜比模块] ", "[Dolby] ") + dolbyTxt);
                }
            }
            catch (Exception ex) { Program.LogError("RefreshDolbyStatus", ex); }
        }
        string _lastDolbyMods = "";
        string _lastSpecErr = "";   // 最近一次捕获错误（变化时记日志）/ last capture error (log on change)
        int _specRetries = 0;       // 自动重试计数 / auto-retry counter

        // 捕获自愈：错误首次出现记日志；未拿到数据且有错误时最多自动重试 5 次（解决设备掉线/独占抢占）
        // capture self-heal: log first error; retry up to 5x when no data + error (device drop / exclusive grab)
        void SpecAutoHeal()
        {
            try
            {
                if (specCapture == null) return;
                string err = specCapture.LastError;
                if (err.Length > 0 && err != _lastSpecErr)
                {
                    _lastSpecErr = err;
                    _specRetries = 0;
                    Append(boxSpectrum, s("[捕获错误] ", "[capture error] ") + err);
                }
                if (specCapture.GotData) { _specRetries = 0; return; }
                if (err.Length > 0 && _specRetries < 5)
                {
                    _specRetries++;
                    Append(boxSpectrum, s("[捕获] 出错，自动重试 (", "[capture] error, retrying (") + _specRetries + "/5)...");
                    specCapture.Stop();
                    specCapture = null;
                    StartSpectrum(false);
                }
            }
            catch (Exception ex) { Program.LogError("SpecAutoHeal", ex); }
        }

        // /spectrum 启动参数：切到频谱页 + 开始监视 + 打开浮动窗 / auto-open spectrum view
        public void AutoOpenSpectrum()
        {
            try
            {
                if (tabs != null) tabs.SelectedIndex = 4;
                if (specCapture == null) StartSpectrum(true);
                else if (!specCapture.GotData) { specCapture.Stop(); specCapture = null; StartSpectrum(true); }
                OpenSpectrumForm();
                Program.SpectrumLog("AutoOpenSpectrum 完成 (T" + System.Threading.Thread.CurrentThread.ManagedThreadId + ")");
            }
            catch (Exception ex) { Program.LogError("AutoOpenSpectrum", ex); }
        }

        void OpenSpectrumForm()
        {
            // 窗体创建与 WebView2 初始化必须在 UI 线程 / form creation & WebView2 init must run on the UI thread
            if (InvokeRequired) { BeginInvoke((Action)(() => OpenSpectrumForm())); return; }
            try
            {
                Program.SpectrumLog("OpenSpectrumForm 进入 (T" + System.Threading.Thread.CurrentThread.ManagedThreadId + ")");
                if (specForm == null || specForm.IsDisposed)
                {
                    specForm = new SpectrumForm();
                    specForm.ClosedByUser += () => { specForm = null; };
                    specForm.Show();
                    Program.SpectrumLog("OpenSpectrumForm: Show() done, Visible=" + specForm.Visible +
                        " IsHandleCreated=" + specForm.IsHandleCreated + " (T" + System.Threading.Thread.CurrentThread.ManagedThreadId + ")");
                }
                else { specForm.Activate(); Program.SpectrumLog("OpenSpectrumForm: Activate existing"); }
                // 确保捕获在跑 / ensure capture running
                if (specCapture == null) { Program.SpectrumLog("OpenSpectrumForm: 调 StartSpectrum(false)"); StartSpectrum(false); }
                else if (!specCapture.GotData) { specCapture.Stop(); specCapture = null; StartSpectrum(false); }
                Append(boxSpectrum, s("[浮动窗] 已打开（固定前台=默认置顶；按钮可切换）。", "[Floating] opened (pinned by default; button toggles)."));
            }
            catch (Exception ex) { Program.LogError("OpenSpectrumForm", ex); }
        }

        // 顶部说明标签：固定高、自动换行（AutoSize+Dock 在部分 DPI/窗口宽度下会横向溢出）
        // wrapping header tip: fixed height, wraps instead of overflowing the window
        Label WrapTip(string text)
        {
            return new Label { Dock = DockStyle.Top, AutoSize = false, Height = 52, Padding = new Padding(6, 4, 6, 2), ForeColor = Color.Gray, Text = text };
        }

        // ---------- Tab 6 自动切档 / Auto Profile ----------
        TabPage BuildAutoTab()
        {
            var page = new TabPage(s("自动切档", "Auto Profile"));
            var tip = WrapTip(s("按前台应用自动切换 Dolby 档位（改 operator_settings.xml 的 AutoProfile 映射）。" +
                          "例如 cs2.exe → personalize_user1（游戏柔和档）：游戏在前台自动切，切走自动回默认档。" +
                          "与独立小应用 ProfileSwitch 二选一使用（它支持更细的前台/后台/运行即切规则）。",
                          "Switch Dolby profile automatically by foreground app (edits AutoProfile in operator_settings.xml). " +
                          "e.g. cs2.exe → personalize_user1 (soft gaming): applies on foreground, reverts on leave. " +
                          "Use either this or the standalone ProfileSwitch app (which adds foreground/background/either rules)."));
            var flow = new FlowLayoutPanel { Dock = DockStyle.Top, AutoSize = true, Padding = new Padding(6) };
            chkAutoProf = new CheckBox { Text = s("启用自动切档", "Enable Auto Profile"), AutoSize = true, Margin = new Padding(4, 9, 12, 0), Checked = false };
            flow.Controls.Add(chkAutoProf);
            flow.Controls.Add(new Label { Text = s("默认档:", "Default:"), AutoSize = true, Margin = new Padding(4, 9, 2, 0) });
            cmbAutoDefault = new ComboBox { Width = 150, Margin = new Padding(4), DropDownStyle = ComboBoxStyle.DropDownList };
            cmbAutoDefault.Items.AddRange(new object[] { "music", "dynamic", "movie", "game", "voice", "off", "personalize_user1", "personalize_user2", "personalize_user3" });
            cmbAutoDefault.SelectedIndex = 0;
            flow.Controls.Add(cmbAutoDefault);
            flow.Controls.Add(MkBtn(s("应用并重启服务", "Apply & Restart"), () => AutoApply(true), true));
            flow.Controls.Add(MkBtn(s("查看当前设置", "Show Current"), () => AutoShow()));
            flow.Controls.Add(MkBtn(s("关闭自动切档", "Disable"), () => AutoApplyDisable()));

            // 映射表
            var mapPanel = new Panel { Dock = DockStyle.Top, Height = 210, Padding = new Padding(8, 4, 8, 4) };
            lstAutoApps = new ListView { Dock = DockStyle.Fill, View = View.Details, FullRowSelect = true, MultiSelect = false };
            lstAutoApps.Columns.Add(s("程序 (exe)", "App (exe)"), 260);
            lstAutoApps.Columns.Add(s("档位", "Profile"), 170);
            lstAutoApps.Columns.Add(s("优先级", "Priority"), 80);
            mapPanel.Controls.Add(lstAutoApps);
            var addBar = new Panel { Dock = DockStyle.Bottom, Height = 40, Padding = new Padding(0, 4, 0, 0) };
            txtAutoExe = new TextBox { Location = new Point(8, 6), Width = 200 };
            cmbAutoMapProf = new ComboBox { Location = new Point(220, 6), Width = 140, DropDownStyle = ComboBoxStyle.DropDownList };
            cmbAutoMapProf.Items.AddRange(new object[] { "personalize_user1", "personalize_user2", "personalize_user3", "dynamic", "movie", "music", "game", "voice", "off" });
            cmbAutoMapProf.SelectedIndex = 0;
            var btnAdd = new Button { Text = s("添加", "Add"), Location = new Point(372, 4), Width = 64, Height = 26 };
            btnAdd.Click += (ss, ee) => AddAutoApp();
            var btnDel = new Button { Text = s("删除选中", "Remove"), Location = new Point(444, 4), Width = 80, Height = 26 };
            btnDel.Click += (ss, ee) => { if (lstAutoApps.SelectedItems.Count > 0) lstAutoApps.SelectedItems[0].Remove(); };
            addBar.Controls.AddRange(new Control[] { txtAutoExe, cmbAutoMapProf, btnAdd, btnDel });
            mapPanel.Controls.Add(addBar);

            boxAuto = MkBox();
            boxAuto.Dock = DockStyle.Top; boxAuto.Height = 160;

            page.Controls.Add(boxAuto);
            page.Controls.Add(mapPanel);
            page.Controls.Add(flow);
            page.Controls.Add(tip);
            return page;
        }

        void AddAutoApp()
        {
            string exe = txtAutoExe.Text.Trim();
            if (exe.Length == 0) { Msg(s("请输入程序 exe 名。", "Enter an exe name.")); return; }
            if (!exe.ToLowerInvariant().EndsWith(".exe")) exe += ".exe";
            foreach (ListViewItem it in lstAutoApps.Items)
                if (string.Equals(it.SubItems[0].Text, exe, StringComparison.OrdinalIgnoreCase)) { Msg(s("已存在该程序。", "Already added.")); return; }
            ListViewItem li = new ListViewItem(exe);
            li.SubItems.Add(cmbAutoMapProf.SelectedItem.ToString());
            li.SubItems.Add("10");
            lstAutoApps.Items.Add(li);
            txtAutoExe.Clear();
        }

        void AutoApply(bool restart)
        {
            var sb = new StringBuilder();
            sb.Append(chkAutoProf.Checked ? "-Enable" : "-Disable");
            sb.Append(" -SetDefault ").Append(cmbAutoDefault.SelectedItem);
            var pairs = new List<string>();
            foreach (ListViewItem it in lstAutoApps.Items)
                pairs.Add(it.SubItems[0].Text + "|" + it.SubItems[1].Text);
            if (pairs.Count > 0) sb.Append(" -AddGame \"").Append(string.Join(";", pairs)).Append("\"");
            if (restart) sb.Append(" -RestartService");
            Run(boxAuto, "AutoProfile.ps1", sb.ToString());
        }

        void AutoShow() { Run(boxAuto, "AutoProfile.ps1", "-Show"); }
        void AutoApplyDisable() { chkAutoProf.Checked = false; AutoApply(true); }

        // ---------- Tab 5 自定义调音 / Custom Tuning ----------
        TabPage BuildCustomTab()
        {
            var page = new TabPage(s("自定义调音", "Custom Tuning"));
            // 顶部说明 / header tip
            var tip = WrapTip(s("以「载入」的调音为模板，叠加你的参数，生成一个「空key」自定义调音（任意机器可切换）。" +
                          "改完点“保存并立即应用”，重启电脑后生效；不满意回「切换调音」页点“恢复原调音”。",
                          "Use the loaded tuning as template, apply your settings, generate a key-less custom tuning (switchable on any PC). " +
                          "Click “Save & Apply” then reboot to take effect; revert anytime via “Restore Original” on the Tuning tab."));
            // 顶部动作条 / action bar
            var flow = new FlowLayoutPanel { Dock = DockStyle.Top, AutoSize = true, Padding = new Padding(6) };
            flow.Controls.Add(new Label { Text = s("调音名称:", "Name:"), AutoSize = true, Margin = new Padding(4, 9, 2, 0) });
            txtCustomName = new TextBox { Text = s("我的调音", "My Tuning"), Width = 150, Margin = new Padding(4), Height = 30 };
            flow.Controls.Add(txtCustomName);
            flow.Controls.Add(MkBtn(s("生成并保存", "Generate & Save"), () => CustomAction(false)));
            flow.Controls.Add(MkBtn(s("保存并立即应用", "Save & Apply Now"), () => CustomAction(true), true));
            flow.Controls.Add(MkBtn(s("套用EQ预设", "Apply EQ Preset"), () => ApplyGeqPreset()));

            // 载入已安装调音条（新增）/ Load installed tuning bar (new) —— 模板名放第二行，不压按钮；
            // 加设备筛选（Realtek DEV_* / USB/蓝牙 通用），不同设备可不同调音
            var loadBar = new Panel { Dock = DockStyle.Top, Height = 58, Padding = new Padding(8, 2, 8, 2), BackColor = Color.FromArgb(245, 247, 252) };
            var lbLoad = new Label { Text = s("载入模板:", "Template:"), AutoSize = true, Location = new Point(10, 10) };
            cmbInstDevFilter = new ComboBox { Location = new Point(92, 7), Width = 118, DropDownStyle = ComboBoxStyle.DropDownList };
            cmbInstDevFilter.Items.Add(s("全部设备", "All devices"));
            cmbInstDevFilter.Items.Add("Realtek");
            cmbInstDevFilter.Items.Add(s("USB/蓝牙", "USB/BT"));
            cmbInstDevFilter.SelectedIndex = 0;
            cmbInstDevFilter.SelectedIndexChanged += (ss3, ee3) => { try { ApplyInstalledFilter(true); } catch { } };
            cmbInstalledTuning = new ComboBox { Location = new Point(222, 7), Width = 330, DropDownStyle = ComboBoxStyle.DropDownList };
            lblCustomTpl = new Label { AutoSize = true, Location = new Point(222, 34), ForeColor = Color.FromArgb(30, 110, 60) };
            loadBar.Controls.Add(lbLoad);
            loadBar.Controls.Add(cmbInstDevFilter);
            loadBar.Controls.Add(cmbInstalledTuning);
            loadBar.Controls.Add(lblCustomTpl);
            var btnLoad = new Button { Text = s("载入", "Load"), Location = new Point(565, 5), Width = 64, Height = 26 };
            btnLoad.Click += (ss, ee) => LoadInstalledTuning();
            loadBar.Controls.Add(btnLoad);
            var btnReload = new Button { Text = s("刷新", "Refresh"), Location = new Point(637, 5), Width = 64, Height = 26 };
            btnReload.Click += (ss, ee) => RefreshInstalledTunings();
            loadBar.Controls.Add(btnReload);

            // 图形EQ卡片 / Graphic EQ card
            var eqCard = new GroupBox {
                Dock = DockStyle.Top, Height = 148, Padding = new Padding(8, 4, 8, 4),
                Text = s("图形EQ（20 段，增益 -192..192）", "Graphic EQ (20 bands, gain -192..192)")
            };
            chkGeq = new CheckBox { Text = s("启用图形EQ", "Enable"), AutoSize = true, Location = new Point(12, 20), Checked = false };
            eqCard.Controls.Add(chkGeq);
            eqCard.Controls.Add(new Label { Text = s("预设:", "Preset:"), AutoSize = true, Location = new Point(128, 23) });
            cmbGeqPreset = new ComboBox { Location = new Point(170, 20), Width = 120, DropDownStyle = ComboBoxStyle.DropDownList };
            cmbGeqPreset.Items.AddRange(new object[] { s("平坦", "Flat"), s("低音增强", "Bass Boost"), s("高音清晰", "Treble"), s("人声突出", "Vocal"), s("摇滚", "Rock"), s("古典", "Classical") });
            cmbGeqPreset.SelectedIndex = 0;
            eqCard.Controls.Add(cmbGeqPreset);
            for (int i = 0; i < 20; i++)
            {
                int r = i / 10, c = i % 10;
                int x = 12 + c * 75, y = 52 + r * 42;
                eqCard.Controls.Add(new Label { Text = GEQ_FREQS[i] + "Hz", AutoSize = true, Location = new Point(x + 14, y) });
                nudGeq[i] = new NumericUpDown {
                    Minimum = -192, Maximum = 192, Increment = 1, Value = 0, Width = 58,
                    Location = new Point(x, y + 18), TextAlign = HorizontalAlignment.Center
                };
                eqCard.Controls.Add(nudGeq[i]);
            }

            // 效果卡片（6 项，两列）/ Effects card (6 rows, 2 columns)
            // 音效卡片（5 行两列，间距充足不重叠；悬停勾选框看说明）/
            // Effects card (5 rows in 2 columns, generous spacing; hover checkbox for hint)
            var fxCard = new GroupBox {
                Dock = DockStyle.Top, Height = 135, Padding = new Padding(8, 4, 8, 4),
                Text = s("音效处理", "Audio Effects")
            };
            tipCustom = new ToolTip();
            int ay1 = 26, ay2 = 60, ay3 = 94;   // 列A三行 / col A rows
            int by1 = 26, by2 = 60;             // 列B两行 / col B rows
            chkIeq = new CheckBox { Text = s("智能EQ", "Smart EQ"), AutoSize = true, Location = new Point(12, ay1), Checked = false };
            nudIeqAmount = MkNud(200, ay1 - 2, 0, 20, 10);
            cmbIeqPreset = new ComboBox { Location = new Point(310, ay1 - 2), Width = 88, DropDownStyle = ComboBoxStyle.DropDownList };
            cmbIeqPreset.Items.AddRange(new object[] { s("均衡", "Balanced"), s("细腻", "Detailed"), s("温暖", "Warm") });
            cmbIeqPreset.SelectedIndex = 0;
            fxCard.Controls.Add(chkIeq);
            fxCard.Controls.Add(new Label { Text = s("强度(0-20):", "Amount(0-20):"), AutoSize = true, Location = new Point(100, ay1 + 1) });
            fxCard.Controls.Add(nudIeqAmount);
            fxCard.Controls.Add(new Label { Text = s("预设:", "Preset:"), AutoSize = true, Location = new Point(268, ay1 + 1) });
            fxCard.Controls.Add(cmbIeqPreset);
            tipCustom.SetToolTip(chkIeq, s("智能EQ按内容自动均衡频响，听感更自然。", "Smart EQ auto-balances frequency response by content."));
            chkBass = new CheckBox { Text = s("低音增强", "Bass Enhancer"), AutoSize = true, Location = new Point(12, ay2), Checked = false };
            nudBassBoost = MkNud(200, ay2 - 2, 0, 20, 5);
            nudBassCutoff = MkNud(320, ay2 - 2, 50, 400, 200);
            fxCard.Controls.Add(chkBass);
            fxCard.Controls.Add(new Label { Text = s("增强量(0-20):", "Boost(0-20):"), AutoSize = true, Location = new Point(100, ay2 + 1) });
            fxCard.Controls.Add(nudBassBoost);
            fxCard.Controls.Add(new Label { Text = s("截止频率:", "Cutoff:"), AutoSize = true, Location = new Point(268, ay2 + 1) });
            fxCard.Controls.Add(nudBassCutoff);
            fxCard.Controls.Add(new Label { Text = "Hz", AutoSize = true, Location = new Point(382, ay2 + 1) });
            tipCustom.SetToolTip(chkBass, s("低频更厚实，适合流行/摇滚。", "Thicker low end; good for pop/rock."));
            chkLeveler = new CheckBox { Text = s("音量均衡", "Volume Leveler"), AutoSize = true, Location = new Point(12, ay3), Checked = true };
            nudLevelerAmount = MkNud(200, ay3 - 2, 0, 20, 5);
            fxCard.Controls.Add(chkLeveler);
            fxCard.Controls.Add(new Label { Text = s("强度(0-20):", "Amount(0-20):"), AutoSize = true, Location = new Point(100, ay3 + 1) });
            fxCard.Controls.Add(nudLevelerAmount);
            tipCustom.SetToolTip(chkLeveler, s("平滑音量起伏，避免忽大忽小。", "Smooths volume swings."));
            chkDialog = new CheckBox { Text = s("对白增强", "Dialog Enhancer"), AutoSize = true, Location = new Point(400, by1), Checked = false };
            nudDialogAmount = MkNud(630, by1 - 2, 0, 20, 5);
            fxCard.Controls.Add(chkDialog);
            fxCard.Controls.Add(new Label { Text = s("增强量(0-20):", "Boost(0-20):"), AutoSize = true, Location = new Point(500, by1 + 1) });
            fxCard.Controls.Add(nudDialogAmount);
            tipCustom.SetToolTip(chkDialog, s("人声更清晰，适合影视/播客。", "Clearer voices for movies/podcasts."));
            chkSurround = new CheckBox { Text = s("虚拟环绕", "Virtual Surround"), AutoSize = true, Location = new Point(400, by2), Checked = false };
            nudSurroundBoost = MkNud(630, by2 - 2, 0, 150, 96);
            fxCard.Controls.Add(chkSurround);
            fxCard.Controls.Add(new Label { Text = s("环绕增益(0-150):", "Surround Boost(0-150):"), AutoSize = true, Location = new Point(500, by2 + 1) });
            fxCard.Controls.Add(nudSurroundBoost);
            tipCustom.SetToolTip(chkSurround, s("扩展声场，耳机听感更开阔。", "Wider soundstage on headphones."));

            // 喇叭EQ卡片（v2，调音核心）/ Speaker PEQ card (v2, the tuning core)
            var peqCard = new GroupBox {
                Dock = DockStyle.Top, Height = 212, Padding = new Padding(8, 4, 8, 4),
                Text = s("喇叭EQ（Speaker PEQ，5 段 × L/R —— 直接写 Dolby 分频前 EQ）", "Speaker PEQ (5 bands × L/R — the tuning core)")
            };
            chkPeq = new CheckBox { Text = s("启用喇叭EQ", "Enable Speaker PEQ"), AutoSize = true, Location = new Point(12, 20), Checked = true };
            peqCard.Controls.Add(chkPeq);
            peqCard.Controls.Add(new Label { Text = s("载入模板自动回填；type 3=架（高音提亮常用）", "Auto-filled from template; type 3=shelf (typical treble lift)"), AutoSize = true, ForeColor = Color.Gray, Location = new Point(170, 22) });
            string[] peqTypeNames = { s("峰值", "Peak"), s("架", "Shelf") };
            int px = 76;
            peqCard.Controls.Add(new Label { Text = s("频率Hz", "Freq Hz"), AutoSize = true, ForeColor = Color.Gray, Location = new Point(px, 44) });
            peqCard.Controls.Add(new Label { Text = s("增益dB", "Gain dB"), AutoSize = true, ForeColor = Color.Gray, Location = new Point(px + 84, 44) });
            peqCard.Controls.Add(new Label { Text = s("Q/S", "Q/S"), AutoSize = true, ForeColor = Color.Gray, Location = new Point(px + 160, 44) });
            peqCard.Controls.Add(new Label { Text = s("类型", "Type"), AutoSize = true, ForeColor = Color.Gray, Location = new Point(px + 232, 44) });
            for (int i = 0; i < 5; i++)
            {
                int ry = 68 + i * 26;
                chkPeqOn[i] = new CheckBox { Text = s("开", "On"), AutoSize = true, Location = new Point(6, ry), Checked = true };
                peqCard.Controls.Add(new Label { Text = (i + 1).ToString(), AutoSize = true, Location = new Point(42, ry + 1) });
                nudPeqF0[i] = new NumericUpDown { Minimum = 20, Maximum = 20000, Increment = 10, Value = 1000, Width = 76, DecimalPlaces = 0, Location = new Point(76, ry), TextAlign = HorizontalAlignment.Center };
                nudPeqGain[i] = new NumericUpDown { Minimum = -30, Maximum = 30, Increment = 1, Value = 0, Width = 66, DecimalPlaces = 1, Location = new Point(160, ry), TextAlign = HorizontalAlignment.Center };
                nudPeqQ[i] = new NumericUpDown { Minimum = 1, Maximum = 100, Increment = 5, Value = 1, Width = 56, DecimalPlaces = 2, Location = new Point(236, ry), TextAlign = HorizontalAlignment.Center };
                cmbPeqType[i] = new ComboBox { Location = new Point(308, ry), Width = 66, DropDownStyle = ComboBoxStyle.DropDownList };
                cmbPeqType[i].Items.AddRange(peqTypeNames);
                cmbPeqType[i].SelectedIndex = 0;
                peqCard.Controls.Add(chkPeqOn[i]);
                peqCard.Controls.Add(nudPeqF0[i]);
                peqCard.Controls.Add(nudPeqGain[i]);
                peqCard.Controls.Add(nudPeqQ[i]);
                peqCard.Controls.Add(cmbPeqType[i]);
            }

            // 空间与保护卡片（v2）/ Spatial & Protection card (v2)
            var spatialCard = new GroupBox {
                Dock = DockStyle.Top, Height = 158, Padding = new Padding(8, 4, 8, 4),
                Text = s("空间与保护（Spatial & Protection）", "Spatial & Protection")
            };
            int sy = 22;
            chkSurDec = new CheckBox { Text = s("环绕解码 5.1→2.0", "Surround Decode"), AutoSize = true, Location = new Point(12, sy), Checked = true };
            chkSurVirt = new CheckBox { Text = s("环绕虚拟化", "Surround Virtual"), AutoSize = true, Location = new Point(220, sy), Checked = true };
            chkHeightVirt = new CheckBox { Text = s("高度虚拟化", "Height Virtual"), AutoSize = true, Location = new Point(390, sy), Checked = true };
            chkMiVirt = new CheckBox { Text = s("Atmos对象定位", "Atmos Steering"), AutoSize = true, Location = new Point(560, sy), Checked = false };
            spatialCard.Controls.AddRange(new Control[] { chkSurDec, chkSurVirt, chkHeightVirt, chkMiVirt });
            sy += 30;
            spatialCard.Controls.Add(new Label { Text = s("虚拟角度:", "Virtual angles:"), AutoSize = true, Location = new Point(12, sy + 3) });
            nudVirtFront = MkNud(100, sy, 0, 90, 5);
            nudVirtSurround = MkNud(180, sy, 0, 90, 5);
            nudVirtRear = MkNud(260, sy, 0, 90, 10);
            nudVirtRearH = MkNud(350, sy, 0, 90, 10);
            nudVirtHeight = MkNud(430, sy, 0, 90, 5);
            spatialCard.Controls.Add(new Label { Text = s("前", "Fr"), AutoSize = true, Location = new Point(84, sy + 3) });
            spatialCard.Controls.Add(nudVirtFront);
            spatialCard.Controls.Add(new Label { Text = s("环", "Sur"), AutoSize = true, Location = new Point(164, sy + 3) });
            spatialCard.Controls.Add(nudVirtSurround);
            spatialCard.Controls.Add(new Label { Text = s("后", "Rr"), AutoSize = true, Location = new Point(244, sy + 3) });
            spatialCard.Controls.Add(nudVirtRear);
            spatialCard.Controls.Add(new Label { Text = s("后高", "RH"), AutoSize = true, Location = new Point(312, sy + 3) });
            spatialCard.Controls.Add(nudVirtRearH);
            spatialCard.Controls.Add(new Label { Text = s("高度", "Ht"), AutoSize = true, Location = new Point(392, sy + 3) });
            spatialCard.Controls.Add(nudVirtHeight);
            sy += 30;
            chkRegulator = new CheckBox { Text = s("限幅保护", "Limiter"), AutoSize = true, Location = new Point(12, sy), Checked = true };
            nudRegRelax = MkNud(140, sy - 2, 0, 100, 96);
            chkMbComp = new CheckBox { Text = s("多段压缩", "MB Compressor"), AutoSize = true, Location = new Point(240, sy), Checked = true };
            chkBassExtract = new CheckBox { Text = s("低音提取", "Bass Extract"), AutoSize = true, Location = new Point(420, sy), Checked = false };
            nudBassExtractCutoff = MkNud(528, sy - 2, 20, 500, 200);
            spatialCard.Controls.Add(chkRegulator);
            spatialCard.Controls.Add(new Label { Text = s("松弛:", "Relax:"), AutoSize = true, Location = new Point(92, sy + 1) });
            spatialCard.Controls.Add(nudRegRelax);
            spatialCard.Controls.Add(chkMbComp);
            spatialCard.Controls.Add(chkBassExtract);
            spatialCard.Controls.Add(new Label { Text = "Hz", AutoSize = true, Location = new Point(592, sy + 1) });
            spatialCard.Controls.Add(nudBassExtractCutoff);
            sy += 30;
            spatialCard.Controls.Add(new Label {
                Text = s("勾选=按你的值写（解码/虚拟/保护），不勾=强制关；角度与数值始终写入。载入不同模板自动回填。",
                         "Checked = force on with your values, unchecked = force off; angles/values always written. Template reload refills all."),
                AutoSize = true, ForeColor = Color.Gray, Location = new Point(12, sy + 2)
            });

            // 中部可滚动：EQ/效果/喇叭EQ/空间 + 日志框 / scrollable middle: cards + log box
            boxCustom = MkBox();
            boxCustom.Dock = DockStyle.Top;
            boxCustom.Height = 240;
            var scroll = new Panel { Dock = DockStyle.Fill, AutoScroll = true };
            scroll.Controls.Add(boxCustom);
            scroll.Controls.Add(spatialCard);
            scroll.Controls.Add(peqCard);
            scroll.Controls.Add(fxCard);
            scroll.Controls.Add(eqCard);
            page.Controls.Add(scroll);
            page.Controls.Add(loadBar);
            page.Controls.Add(tip);
            page.Controls.Add(flow);
            RefreshInstalledTunings();   // 初始填充已安装调音下拉 / initial fill
            return page;
        }

        void RefreshInstalledTunings()
        {
            // 列出已安装调音目录（dolbyaposvc）里全部 DEV_*.xml + USB 通用调音，供“载入模板”选择，
            // 按设备分类（R=Realtek DEV_* / U=USB/蓝牙 通用），可由顶部设备筛选。
            // List all installed tunings (dolbyaposvc) + USB generic for template loading, tagged R/U for the device filter.
            try
            {
                if (cmbInstalledTuning == null || cmbInstalledTuning.IsDisposed) return;
                installedTuningRows.Clear();
                string dir = TUNING;
                if (Directory.Exists(dir))
                {
                    foreach (string f in Directory.GetFiles(dir, "DEV_*.xml"))
                    {
                        if (f.EndsWith("_settings.xml", StringComparison.OrdinalIgnoreCase)) continue;
                        string n = Path.GetFileName(f);
                        var m = Regex.Match(n, @"^DEV_([0-9A-Fa-f]{4})_SUBSYS_([0-9A-Fa-f]{8})");
                        string subsys = m.Success ? m.Groups[2].Value : "";
                        string model = "";
                        if (subsys.Length > 0) TuningNames.TryGetValue(subsys, out model);
                        if (model == null) model = "";
                        string cur = "";
                        if (m.Success && subsys == MachineSubsys()) cur = s("  ✓当前生效", "  ✓active");
                        installedTuningRows.Add(new string[] {
                            n + (model.Length > 0 ? "  [" + model + "]" : "") + cur, f, "R" });
                    }
                    string ug = Path.Combine(dir, "Headphone_Default_Generic_Default_DolbyAtmosSpeakerSystem.xml");
                    if (File.Exists(ug))
                    {
                        string ugModel = UsbGenericModel(FindTuningDir(), ug);
                        installedTuningRows.Add(new string[] {
                            "Headphone_Default_Generic_Default_DolbyAtmosSpeakerSystem.xml  [" + s("USB通用", "USB generic") + (ugModel.Length > 0 ? " · " + ugModel : "") + "]", ug, "U" });
                    }
                }
                installedTuningRows.Sort((a, b) => string.Compare(a[0], b[0], StringComparison.Ordinal));
                // 记住当前载入的模板路径，筛选后尽量保持 / keep the loaded template across filter changes
                string keepPath = customTemplatePath;
                ApplyInstalledFilter(false);
                // 恢复选中：优先仍在列表中的路径，否则选第一项 / restore selection by path or first
                int sel = -1;
                for (int i = 0; i < cmbInstalledTuning.Items.Count; i++)
                    if (keepPath.Length > 0 && cmbInstalledTuning.Items[i].ToString().Length > 0 &&
                        i < visibleInstalledRows.Count && string.Equals(visibleInstalledRows[i][1], keepPath, StringComparison.OrdinalIgnoreCase))
                    { sel = i; break; }
                if (sel >= 0) cmbInstalledTuning.SelectedIndex = sel;
                else if (cmbInstalledTuning.Items.Count > 0) cmbInstalledTuning.SelectedIndex = 0;
                if (visibleInstalledRows.Count > 0) LoadInstalledTuning();   // 默认载入当前选中 / default-load the selection
            }
            catch (Exception ex) { Program.LogError("RefreshInstalledTunings", ex); }
        }

        // 按设备筛选渲染模板下拉 / render the template dropdown by device filter
        void ApplyInstalledFilter(bool reload)
        {
            try
            {
                if (cmbInstalledTuning == null || cmbInstalledTuning.IsDisposed) return;
                int filter = (cmbInstDevFilter != null) ? cmbInstDevFilter.SelectedIndex : 0;
                cmbInstalledTuning.BeginUpdate();
                cmbInstalledTuning.Items.Clear();
                visibleInstalledRows.Clear();
                foreach (string[] row in installedTuningRows)
                {
                    bool isUsb = row[2] == "U";
                    if (filter == 1 && isUsb) continue;      // 只看 Realtek
                    if (filter == 2 && !isUsb) continue;     // 只看 USB/蓝牙
                    cmbInstalledTuning.Items.Add(row[0]);
                    visibleInstalledRows.Add(row);
                }
                if (cmbInstalledTuning.Items.Count == 0)
                    cmbInstalledTuning.Items.Add(s("（该设备无已安装调音）", "(no tunings for this device)"));
                cmbInstalledTuning.EndUpdate();
                if (reload && cmbInstalledTuning.Items.Count > 0)
                {
                    if (cmbInstalledTuning.SelectedIndex < 0) cmbInstalledTuning.SelectedIndex = 0;
                    LoadInstalledTuning();
                }
            }
            catch (Exception ex) { Program.LogError("ApplyInstalledFilter", ex); }
        }

        void LoadInstalledTuning()
        {
            // 把下拉选中的已安装调音载入为模板；未选时回退 ResolveTemplate()。
            // Load the selected installed tuning as template; fallback to ResolveTemplate() when unselected.
            try
            {
                int idx = cmbInstalledTuning == null ? -1 : cmbInstalledTuning.SelectedIndex;
                if (idx >= 0 && idx < visibleInstalledRows.Count)
                {
                    customTemplatePath = visibleInstalledRows[idx][1];
                    if (lblCustomTpl != null)
                        lblCustomTpl.Text = s("已载入: ", "Loaded: ") + Path.GetFileName(customTemplatePath);
                    Append(boxCustom, s("[载入模板] ", "[Template loaded] ") + Path.GetFileName(customTemplatePath));
                    FillCustomFromTemplate(customTemplatePath);   // v2：回填 PEQ/角度/解码/保护
                }
                else
                {
                    customTemplatePath = "";
                    if (lblCustomTpl != null) lblCustomTpl.Text = "";
                }
            }
            catch (Exception ex) { Program.LogError("LoadInstalledTuning", ex); }
        }

        // v2：从模板调音回填自定义页控件（PEQ/角度/解码/保护）。读不到就不动控件。
        // v2: refill the custom-tuning controls from the template (PEQ/angles/decoder/protection).
        void FillCustomFromTemplate(string path)
        {
            try
            {
                if (String.IsNullOrEmpty(path) || !File.Exists(path)) return;
                var d = new XmlDocument();
                d.Load(path);
                var nsm = new XmlNamespaceManager(d.NameTable);
                nsm.AddNamespace("x", d.DocumentElement == null ? "" : d.DocumentElement.NamespaceURI);
                // C#5 兼容：用 Func lambda（旧 csc 不支持局部函数）/ C#5-safe: Func lambdas (legacy csc has no local functions)
                Func<string, string> GetV = name =>
                {
                    var n = d.SelectSingleNode("//*[local-name()='" + name + "']", nsm);
                    return n == null || n.Attributes["value"] == null ? null : n.Attributes["value"].Value;
                };
                Func<string, NumericUpDown, bool> TryV = (name, nud) =>
                {
                    string sv = GetV(name);
                    if (sv == null) return false;
                    int v; if (!int.TryParse(sv, out v)) return false;
                    nud.Value = Math.Max(nud.Minimum, Math.Min(nud.Maximum, v));
                    return true;
                };
                // PEQ：取第一处 speaker-peq-filters，speaker=0 的前 5 段
                if (nudPeqF0[0] != null)
                {
                    var peq = d.SelectSingleNode("//*[local-name()='speaker-peq-filters']", nsm);
                    if (peq != null)
                    {
                        var fl = new List<XmlNode>();
                        foreach (XmlNode f in peq.SelectNodes("*[local-name()='filter']", nsm))
                            if (f.Attributes["speaker"] != null && f.Attributes["speaker"].Value == "0") fl.Add(f);
                        for (int i = 0; i < 5; i++)
                        {
                            if (i < fl.Count)
                            {
                                var f = fl[i];
                                int f0 = 0, type = 1; double gain = 0, q = 1;
                                if (f.Attributes["f0"] != null) int.TryParse(f.Attributes["f0"].Value, out f0);
                                if (f.Attributes["gain"] != null) double.TryParse(f.Attributes["gain"].Value, NumberStyles.Float, CultureInfo.InvariantCulture, out gain);
                                string qattr = f.Attributes["s"] != null ? "s" : "q";
                                if (f.Attributes[qattr] != null) double.TryParse(f.Attributes[qattr].Value, NumberStyles.Float, CultureInfo.InvariantCulture, out q);
                                if (f.Attributes["type"] != null) int.TryParse(f.Attributes["type"].Value, out type);
                                nudPeqF0[i].Value = Math.Max(nudPeqF0[i].Minimum, Math.Min(nudPeqF0[i].Maximum, f0));
                                nudPeqGain[i].Value = Math.Max(nudPeqGain[i].Minimum, Math.Min(nudPeqGain[i].Maximum, (decimal)gain));
                                nudPeqQ[i].Value = Math.Max(nudPeqQ[i].Minimum, Math.Min(nudPeqQ[i].Maximum, (decimal)q));
                                cmbPeqType[i].SelectedIndex = type == 3 ? 1 : 0;
                                chkPeqOn[i].Checked = f.Attributes["enabled"] == null || f.Attributes["enabled"].Value != "0";
                            }
                            else
                            {
                                nudPeqF0[i].Value = nudPeqF0[i].Minimum;
                                nudPeqGain[i].Value = 0;
                                nudPeqQ[i].Value = 1;   // Q=1.00
                                cmbPeqType[i].SelectedIndex = 0;
                                chkPeqOn[i].Checked = false;
                            }
                        }
                        string speq = GetV("speaker-peq-enable");
                        if (speq != null) chkPeq.Checked = speq == "1";
                    }
                }
                // 空间与保护
                string sdec = GetV("surround-decoder-enable");
                if (sdec != null) chkSurDec.Checked = sdec == "1";
                string svirt = GetV("output-mode-partial-surround-virtualizer-enable");
                if (svirt != null) chkSurVirt.Checked = svirt == "1";
                string hvirt = GetV("output-mode-partial-height-virtualizer-enable");
                if (hvirt != null) chkHeightVirt.Checked = hvirt == "1";
                string mist = GetV("mi-virt-steering-enable");
                if (mist != null) chkMiVirt.Checked = mist == "1";
                TryV("virtualizer-front-speaker-angle", nudVirtFront);
                TryV("virtualizer-surround-speaker-angle", nudVirtSurround);
                TryV("virtualizer-rear-speaker-angle", nudVirtRear);
                TryV("virtualizer-rear-height-speaker-angle", nudVirtRearH);
                TryV("virtualizer-height-speaker-angle", nudVirtHeight);
                string reg = GetV("regulator-enable");
                if (reg != null) chkRegulator.Checked = reg == "1";
                TryV("regulator-relaxation-amount", nudRegRelax);
                string mb = GetV("mb-compressor-enable");
                if (mb != null) chkMbComp.Checked = mb == "1";
                string be = GetV("bass-extraction-enable");
                if (be != null) chkBassExtract.Checked = be == "1";
                TryV("bass-extraction-cutoff-frequency", nudBassExtractCutoff);
            }
            catch (Exception ex) { Program.LogError("FillCustomFromTemplate", ex); }
        }

        List<KeyValuePair<string, string>> InstalledTuningPaths()
        {
            // 与下拉同序返回 显示文本->路径；供 LoadInstalledTuning 按索引取路径。
            var entries = new List<KeyValuePair<string, string>>();
            string dir = TUNING;
            if (Directory.Exists(dir))
            {
                foreach (string f in Directory.GetFiles(dir, "DEV_*.xml"))
                {
                    if (f.EndsWith("_settings.xml", StringComparison.OrdinalIgnoreCase)) continue;
                    string n = Path.GetFileName(f);
                    entries.Add(new KeyValuePair<string, string>(n, f));
                }
                string ug = Path.Combine(dir, "Headphone_Default_Generic_Default_DolbyAtmosSpeakerSystem.xml");
                if (File.Exists(ug)) entries.Add(new KeyValuePair<string, string>("Headphone_Default_Generic_Default_DolbyAtmosSpeakerSystem.xml", ug));
            }
            entries.Sort((a, b) => string.Compare(a.Key, b.Key, StringComparison.Ordinal));
            return entries;
        }

        string MachineSubsys()
        {
            try
            {
                using (var rk = Registry.LocalMachine.OpenSubKey(MEDIA))
                {
                    if (rk == null) return "";
                    foreach (string n in rk.GetSubKeyNames())
                    {
                        if (!Regex.IsMatch(n, @"^\d+$")) continue;
                        using (var k = rk.OpenSubKey(n))
                        {
                            if (k == null) continue;
                            var v = k.GetValue("MatchingDeviceId");
                            if (v == null) continue;
                            string mid = v.ToString();
                            if (mid.IndexOf("VEN_10EC", StringComparison.OrdinalIgnoreCase) >= 0)
                            {
                                var ms = Regex.Match(mid, "SUBSYS_([0-9A-Fa-f]{8})");
                                if (ms.Success) return ms.Groups[1].Value.ToUpperInvariant();
                            }
                        }
                    }
                }
            }
            catch { }
            return "";
        }

        NumericUpDown MkNud(int x, int y, int min, int max, int val)
        {
            return new NumericUpDown {
                Minimum = min, Maximum = max, Increment = 1, Value = val, Width = 58,
                Location = new Point(x, y), TextAlign = HorizontalAlignment.Center
            };
        }

        void ApplyGeqPreset()
        {
            try
            {
                int idx = cmbGeqPreset.SelectedIndex;
                if (idx < 0) idx = 0;
                var p = GEQ_PRESETS[idx];
                for (int i = 0; i < 20 && i < nudGeq.Length; i++) nudGeq[i].Value = p[i];
                chkGeq.Checked = true;
                Append(boxCustom, s("[已套用EQ预设] ", "[Applied EQ preset] ") + cmbGeqPreset.Items[idx] + s("（图形EQ已勾选，改完点“生成并保存”或“保存并立即应用”）", " (graphic EQ enabled; then click Generate&Save or Save&Apply)"));
            }
            catch (Exception ex) { Program.LogError("ApplyGeqPreset", ex); }
        }

        string ResolveTemplate()
        {
            // 1) 本机已生效调音（dolbyaposvc，最贴本机）
            try
            {
                if (Directory.Exists(TUNING))
                {
                    string dev = MachineDev();
                    if (dev.Length > 0)
                    {
                        var f = Directory.GetFiles(TUNING, "DEV_" + dev + "*.xml");
                        if (f.Length > 0) return f[0];
                    }
                    var d = Directory.GetFiles(TUNING, "DEV_*.xml");
                    if (d.Length > 0) return d[0];
                }
            }
            catch { }
            // 2) 包内第一个调音兜底（动态扫描调音目录，不依赖固定包名）
            try
            {
                string pkg = FindTuningDir();
                if (pkg.Length > 0)
                {
                    var files = Directory.GetFiles(pkg, "DEV_*.xml");
                    if (files.Length > 0) return files[0];
                }
            }
            catch { }
            return "";
        }

        // 动态定位包内调音目录：Drivers 全树下第一个含 DEV_*.xml 的目录
        // （布局无关：Drivers\ThirdParty\ext 或 Drivers\ext 均可，不硬编码包名/版本目录名）
        string FindTuningDir()
        {
            try
            {
                string drv = Path.Combine(Base, "Drivers");
                if (Directory.Exists(drv))
                {
                    // 深度优先按目录扫描（先 ThirdParty 分支，再全树），命中即返回
                    string base3 = Path.Combine(drv, "ThirdParty");
                    if (Directory.Exists(base3))
                        foreach (string d in Directory.GetDirectories(base3))
                            try { if (Directory.GetFiles(d, "DEV_*.xml").Length > 0) return d; } catch { }
                    foreach (string d in Directory.GetDirectories(drv, "*", SearchOption.AllDirectories))
                        try { if (Directory.GetFiles(d, "DEV_*.xml").Length > 0) return d; } catch { }
                }
            }
            catch { }
            return "";
        }

        void CustomAction(bool apply)
        {
            try
            {
                string name = txtCustomName.Text.Trim();
                if (name.Length == 0) { Msg(s("请先输入调音名称。", "Please enter a tuning name first.")); return; }
                if (name.Length > 40) name = name.Substring(0, 40);
                // 模板：优先用「载入」的已安装调音，否则回退本机生效/包内
                // Template: prefer the loaded installed tuning; fallback to machine-active/package.
                string tpl = (customTemplatePath.Length > 0 && File.Exists(customTemplatePath)) ? customTemplatePath : ResolveTemplate();
                if (tpl.Length == 0) { Append(boxCustom, s("[错误] 找不到模板调音（本机无调音且包内无 DEV_*.xml）。", "[Error] no template tuning found (none on machine and none in package).")); return; }
                string dev = MachineDev();
                string prefix = dev.Length > 0 ? "DEV_" + dev : "DEV_0000_SUBSYS_00000000";
                // 文件名净化（中英文可用，过滤非法字符） / sanitize filename (keep CJK/Latin, drop illegal chars)
                var safe = new StringBuilder();
                foreach (char ch in name)
                    safe.Append(Array.IndexOf(Path.GetInvalidFileNameChars(), ch) >= 0 ? '_' : ch);
                string pkg = FindTuningDir();
                if (pkg.Length == 0)
                {
                    // 干净版无包内调音库：优先本地 Tunings 目录（启动时已自动创建），其次系统调音目录
                    // clean edition without bundled tunings: prefer the local Tunings dir (auto-created at startup), else the system tuning dir
                    string local = Path.Combine(Base, "Tunings");
                    if (Directory.Exists(local)) pkg = local;
                    else if (Directory.Exists(TUNING)) pkg = TUNING;
                }
                if (pkg.Length == 0) { Append(boxCustom, s("[错误] 找不到可保存调音的目录（本地 Tunings 与系统调音目录均不可用）。", "[Error] no directory to save the tuning (local Tunings and the system tuning dir are both unavailable).")); return; }
                string outName = prefix + "_Custom_" + safe.ToString() + ".xml";
                string outPath = Path.Combine(pkg, outName);
                var sb = new StringBuilder();
                sb.Append("-Template ").Append(Quote(tpl));
                sb.Append(" -OutPath ").Append(Quote(outPath));
                sb.Append(" -Name ").Append(Quote(name));
                sb.Append(" -GeqEnable ").Append(chkGeq.Checked ? 1 : 0);
                sb.Append(" -GeqBands \"").Append(string.Join(",", Array.ConvertAll(nudGeq, n => n.Value.ToString()))).Append("\"");
                sb.Append(" -IeqEnable ").Append(chkIeq.Checked ? 1 : 0);
                sb.Append(" -IeqAmount ").Append(nudIeqAmount.Value);
                sb.Append(" -IeqPreset ").Append(cmbIeqPreset.SelectedIndex == 1 ? "ieq_detailed" : cmbIeqPreset.SelectedIndex == 2 ? "ieq_warm" : "ieq_balanced");
                sb.Append(" -BassEnable ").Append(chkBass.Checked ? 1 : 0);
                sb.Append(" -BassBoost ").Append(nudBassBoost.Value);
                sb.Append(" -BassCutoff ").Append(nudBassCutoff.Value);
                sb.Append(" -LevelerEnable ").Append(chkLeveler.Checked ? 1 : 0);
                sb.Append(" -LevelerAmount ").Append(nudLevelerAmount.Value);
                sb.Append(" -DialogEnable ").Append(chkDialog.Checked ? 1 : 0);
                sb.Append(" -DialogAmount ").Append(nudDialogAmount.Value);
                sb.Append(" -SurroundEnable ").Append(chkSurround.Checked ? 1 : 0);
                sb.Append(" -SurroundBoost ").Append(nudSurroundBoost.Value);
                // v2 参数：环绕解码 / 虚拟化 / 角度 / 喇叭EQ / 保护 / 低音提取
                sb.Append(" -SurroundDecoderEnable ").Append(chkSurDec.Checked ? 1 : 0);
                sb.Append(" -SurroundVirtEnable ").Append(chkSurVirt.Checked ? 1 : 0);
                sb.Append(" -HeightVirtEnable ").Append(chkHeightVirt.Checked ? 1 : 0);
                sb.Append(" -MiVirtSteering ").Append(chkMiVirt.Checked ? 1 : 0);
                sb.Append(" -VirtFrontAngle ").Append(nudVirtFront.Value);
                sb.Append(" -VirtSurroundAngle ").Append(nudVirtSurround.Value);
                sb.Append(" -VirtRearAngle ").Append(nudVirtRear.Value);
                sb.Append(" -VirtRearHeightAngle ").Append(nudVirtRearH.Value);
                sb.Append(" -VirtHeightAngle ").Append(nudVirtHeight.Value);
                sb.Append(" -SpeakerPeqEnable ").Append(chkPeq.Checked ? 1 : 0);
                var peqSpecs = new List<string>();
                for (int i = 0; i < 5; i++)
                    if (chkPeqOn[i].Checked)
                        peqSpecs.Add(String.Format(CultureInfo.InvariantCulture, "{0},{1},{2},{3}",
                            nudPeqF0[i].Value,
                            nudPeqGain[i].Value.ToString(CultureInfo.InvariantCulture),
                            nudPeqQ[i].Value.ToString(CultureInfo.InvariantCulture),
                            cmbPeqType[i].SelectedIndex == 1 ? 3 : 1));
                if (peqSpecs.Count > 0)
                    sb.Append(" -SpeakerPeqFilters \"").Append(String.Join(";", peqSpecs)).Append("\"");
                sb.Append(" -RegulatorEnable ").Append(chkRegulator.Checked ? 1 : 0);
                sb.Append(" -RegulatorRelaxation ").Append(nudRegRelax.Value);
                sb.Append(" -MbCompressorEnable ").Append(chkMbComp.Checked ? 1 : 0);
                sb.Append(" -BassExtractEnable ").Append(chkBassExtract.Checked ? 1 : 0);
                sb.Append(" -BassExtractCutoff ").Append(nudBassExtractCutoff.Value);
                Run(boxCustom, "CustomTuning.ps1", sb.ToString());
                if (apply && File.Exists(outPath))
                {
                    Append(boxCustom, "");
                    Append(boxCustom, s("===== 应用：切换到此自定义调音 =====", "===== Apply: switch to this custom tuning ====="));
                    // 传完整路径：无论文件在包内还是系统目录都能被切换器定位
                    Run(boxCustom, "TuningSwitcher.ps1", "-Switch " + Quote(outPath));
                }
            }
            catch (Exception ex) { Program.LogError("CustomAction", ex); Append(boxCustom, s("[错误] ", "[Error] ") + ex.Message); }
        }

        // ---------- Tab 5 设置（语言 + 日志系统 + 数据文件） / Settings (language + logging + data) ----------
        TabPage BuildSettingsTab()
        {
            var page = new TabPage(s("设置", "Settings"));
            var flow = new FlowLayoutPanel { Dock = DockStyle.Top, AutoSize = true, Padding = new Padding(6) };
            // 界面语言 / UI language
            flow.Controls.Add(new Label { Text = s("界面语言:", "Language:"), AutoSize = true, Margin = new Padding(4, 9, 2, 0) });
            var cmbLang = new ComboBox { Width = 100, DropDownStyle = ComboBoxStyle.DropDownList, Margin = new Padding(4) };
            cmbLang.Items.AddRange(new object[] { "中文", "English" });
            cmbLang.SelectedIndex = Program.CurrentLang == "en" ? 1 : 0;
            cmbLang.SelectedIndexChanged += (sl, el) => {
                if (cmbLang.SelectedIndex < 0) return;
                string nl = cmbLang.SelectedIndex == 1 ? "en" : "zh";
                if (nl != Program.CurrentLang)
                {
                    Program.SetLang(nl);
                    // 浮动窗不随 ReloadUI 重建，需显式推语言 / floating window isn't rebuilt by ReloadUI
                    if (specForm != null && !specForm.IsDisposed && specForm.Host != null) specForm.Host.PushLang(nl);
                    ReloadUI();
                }
            };
            flow.Controls.Add(cmbLang);
            flow.Controls.Add(new Label { Text = s("（切换后界面立即更新）", "(UI updates immediately)"), AutoSize = true, Margin = new Padding(2, 9, 6, 0), ForeColor = Color.Gray });
            // 日志系统 / logging
            var chkLog = new CheckBox {
                Text = s("启用运行日志（默认关闭）", "Enable run logging (off by default)"), AutoSize = true, Margin = new Padding(4, 9, 4, 0),
                Checked = Program.LogEnabled()
            };
            chkLog.CheckedChanged += (ss, ee) => { try { Program.SetLogging(chkLog.Checked); } catch (Exception ex) { Program.LogError("设置日志开关/LogToggle", ex); } };
            flow.Controls.Add(chkLog);
            flow.Controls.Add(MkBtn(s("打开日志文件夹", "Open Log Folder"), () => {
                try { Directory.CreateDirectory(Program.LogDir); Process.Start(Program.LogDir); }
                catch (Exception ex) { Msg(s("打开失败: ", "Cannot open: ") + ex.Message); }
            }));
            flow.Controls.Add(MkBtn(s("清空日志", "Clear Logs"), () => ClearLogs()));
            flow.Controls.Add(MkBtn(s("重建数据文件", "Rebuild Data"), () => Run(boxSettings, "RebuildData.ps1", "")));
            var info = new Panel { Dock = DockStyle.Top, Height = 118, Padding = new Padding(8, 4, 8, 4) };
            var lb = new Label {
                AutoSize = true, Location = new Point(8, 6), Font = new Font("Microsoft YaHei UI", 9.5f),
                Text = s(
                    "日志系统：默认关闭；勾选后所有操作输出写入 " + Program.LogDir + "\r\n" +
                    "          （错误日志 error.log 始终记录，不受此开关影响）\r\n" +
                    "数据文件：位于 " + Path.Combine(Base, "Data") + "\r\n" +
                    "          TuningNames/型号映射/TuningCache/对照说明，可整目录删除后点「重建数据文件」自动再生\r\n" +
                    "          （TuningCache 每次打开「切换调音」页也会自动增量重建）",
                    "Logging: off by default; when on, all output is written to " + Program.LogDir + "\r\n" +
                    "          (error.log is always recorded, unaffected by this toggle)\r\n" +
                    "Data files: located in " + Path.Combine(Base, "Data") + "\r\n" +
                    "          TuningNames / model map / TuningCache / report — delete the folder then click Rebuild Data to regenerate\r\n" +
                    "          (TuningCache also rebuilds incrementally every time the Tuning tab is opened)")
            };
            info.Controls.Add(lb);
            boxSettings = MkBox();
            page.Controls.Add(boxSettings);
            page.Controls.Add(info);
            page.Controls.Add(flow);
            return page;
        }

        void ClearLogs()
        {
            try
            {
                string dir = Program.LogDir;
                if (Directory.Exists(dir))
                {
                    int n = 0;
                    foreach (string f in Directory.GetFiles(dir, "*.log")) { File.Delete(f); n++; }
                    Append(boxSettings, s("[已清空] 删除 ", "[Cleared] removed ") + n + s(" 个日志文件: ", " log file(s): ") + dir);
                }
                else Append(boxSettings, s("[提示] 日志目录不存在（尚未产生日志）: ", "[Info] log dir does not exist yet: ") + dir);
            }
            catch (Exception ex) { Program.LogError("ClearLogs", ex); Msg(s("清空失败: ", "Clear failed: ") + ex.Message); }
        }

        // ---------- Tab 6 卸载 / Uninstall ----------
        TabPage BuildUninstallTab()
        {
            var page = new TabPage(s("卸载", "Uninstall"));
            var flow = new FlowLayoutPanel { Dock = DockStyle.Top, AutoSize = true, Padding = new Padding(6) };
            flow.Controls.Add(MkBtn(s("卸载杜比", "Uninstall Dolby"), () => Run(boxUninstall, ScriptPath("Setup-Dolby.ps1"), "-Uninstall")));
            flow.Controls.Add(MkBtn(s("卸载并删除部署目录", "Uninstall & Purge"), () => Run(boxUninstall, ScriptPath("Setup-Dolby.ps1"), "-Uninstall -Purge")));
            flow.Controls.Add(MkBtn(s("清理全部端点挂接", "Clear All Hookups"), () => Run(boxUninstall, "APOHook.ps1", "-TuningRemoveAll")));
            boxUninstall = MkBox();
            page.Controls.Add(boxUninstall);
            page.Controls.Add(flow);
            return page;
        }

        // ---------- 控件工厂 ----------
        Button MkBtn(string text, Action action)
        {
            var b = new Button { Text = text, AutoSize = true, Margin = new Padding(4), Height = 34 };
            b.Click += (s, e) => {
                b.Enabled = false;
                Thread t = new Thread(() => { try { action(); } catch (Exception ex) { Msg(ex.Message); } finally { try { b.Invoke((Action)(() => b.Enabled = true)); } catch { } } });
                t.IsBackground = true;
                t.Start();
            };
            return b;
        }

        // 危险/重点按钮（红字红底提示）
        Button MkBtn(string text, Action action, bool danger)
        {
            var b = MkBtn(text, action);
            if (danger) { b.BackColor = Color.FromArgb(253, 233, 231); b.ForeColor = Color.FromArgb(179, 38, 30); }
            return b;
        }

        RichTextBox MkBox()
        {
            var r = new RichTextBox { Dock = DockStyle.Fill, ReadOnly = true, BackColor = Color.White, Font = new Font("Consolas", 9.5f), WordWrap = false };
            return r;
        }

        void Append(RichTextBox box, string line)
        {
            Program.AppLog(line);   // 日志系统（默认关闭）：所有操作输出落盘
            if (box == null || box.IsDisposed || box.Disposing) return;
            if (box.InvokeRequired) { try { box.BeginInvoke((Action)(() => Append(box, line))); } catch { } return; }
            box.AppendText(line + "\r\n");
        }

        void Msg(string m) { MessageBox.Show(m, s("杜比管家", "DolbyMaster"), MessageBoxButtons.OK, MessageBoxIcon.Information); }

        // ---------- 执行脚本（异步） ----------
        // 脚本内嵌于 exe：从资源读取 → -EncodedCommand 内存执行（不落盘）。
        // Embedded scripts: read from resource → run inline via -EncodedCommand (never written to disk).
        string ScriptPath(string name) { return name; }   // 保留调用接口；实际按资源名读取 / kept for callers; resolved as resource

        // 构造内存执行命令：脚本体 GZip 压缩后 Base64 走命令行（防 32K 命令行超限），
        // 子进程解压 → [scriptblock]::Create 内存执行（不落盘）。
        // 包根通过进程环境变量 DM_BASE 传递（中文路径无损，且不影响 param() 首句位置）。
        // Build inline command: script body is GZip+Base64 (stays under the 32K cmdline limit),
        // the child decompresses and runs it via [scriptblock]::Create (in memory).
        // Script resources remain embedded; materialize one temporary .ps1 for normal PowerShell semantics, then remove it.
        string CreateTempScript(string name, string body)
        {
            string dir = Path.Combine(Path.GetTempPath(), "DolbyMaster");
            Directory.CreateDirectory(dir);
            string safe = Regex.Replace(name ?? "script", "[^A-Za-z0-9_.-]", "_");
            string path = Path.Combine(dir, Guid.NewGuid().ToString("N") + "_" + safe);
            File.WriteAllText(path, body, new UTF8Encoding(true));
            return path;
        }
        // 构造子进程命令：先锁定输出编码为系统 ANSI 代码页（与 C# 端 Encoding.Default 一致），再跑脚本。
        // Build child command: pin stdout/stderr to the system ANSI codepage first (matches C# Encoding.Default).
        string BuildFileCommand(string path, string args)
        {
            return "[Console]::OutputEncoding=[Text.Encoding]::UTF8;[Console]::InputEncoding=[Text.Encoding]::UTF8;$OutputEncoding=[Text.Encoding]::UTF8; & '" + path.Replace("'", "''") + "' " + (args ?? "");
        }
        void DeleteTempScript(string path) { try { if (!String.IsNullOrEmpty(path) && File.Exists(path)) File.Delete(path); } catch { } }
        void Run(RichTextBox box, string script, string args)
        {
            Append(box, ""); Append(box, "===== " + script + " " + args + " =====");
            string body = Program.ReadEmbeddedScript(script);
            if (body == null) { Append(box, s("[错误] 找不到内嵌脚本: ", "[Error] embedded script not found: ") + script); return; }
            string temp = null;
            using (Process p = new Process())
            {
                try
                {
                    temp = CreateTempScript(script, body);
                    p.StartInfo.FileName = "powershell.exe";
                    p.StartInfo.Arguments = "-NoProfile -ExecutionPolicy Bypass -Command \"" + BuildFileCommand(temp, args) + "\"";
                    p.StartInfo.UseShellExecute = false; p.StartInfo.CreateNoWindow = true;
                    p.StartInfo.RedirectStandardOutput = true; p.StartInfo.RedirectStandardError = true;
                    // 编码匹配：PowerShell 5.1 子进程管道输出走系统代码页（中文系统=GBK 936），
                    // 用 Encoding.Default（=系统 ANSI 代码页）解码；若强行按 UTF-8 会中文乱码。
                    // Encoding match: PS 5.1 pipes bytes in the system code page (GBK 936 on zh-CN);
                    // decode with Encoding.Default (system ANSI codepage). Decoding as UTF-8 garbles CJK.
                    p.StartInfo.StandardOutputEncoding = new UTF8Encoding(false); p.StartInfo.StandardErrorEncoding = new UTF8Encoding(false);
                    p.StartInfo.EnvironmentVariables["DM_BASE"] = Base;
                    p.OutputDataReceived += (ss, ee) => { if (ee.Data != null) Append(box, ee.Data); };
                    p.ErrorDataReceived += (ss, ee) => { if (ee.Data != null) Append(box, "[err] " + ee.Data); };
                    p.Start(); p.BeginOutputReadLine(); p.BeginErrorReadLine(); p.WaitForExit();
                    Append(box, s("[完成] 退出码 ", "[Done] exit code ") + p.ExitCode);
                }
                catch (Exception ex) { Append(box, s("[错误] ", "[Error] ") + ex.Message); }
                finally { DeleteTempScript(temp); }
            }
        }
        string RunCapture(string script, string args)
        {
            var sb = new StringBuilder();
            string body = Program.ReadEmbeddedScript(script);
            if (body == null) return "@@TITLE@@ Error | embedded script not found: " + script;


            string temp = null;
            using (Process p = new Process())
            {
                try
                {
                    temp = CreateTempScript(script, body);
                    p.StartInfo.FileName = "powershell.exe";
                    p.StartInfo.Arguments = "-NoProfile -ExecutionPolicy Bypass -Command \"" + BuildFileCommand(temp, args) + "\"";
                    p.StartInfo.UseShellExecute = false; p.StartInfo.CreateNoWindow = true;
                    p.StartInfo.RedirectStandardOutput = true; p.StartInfo.RedirectStandardError = true;
                    // 编码匹配：PowerShell 5.1 子进程管道输出走系统代码页（中文系统=GBK 936），
                    // 用 Encoding.Default（=系统 ANSI 代码页）解码；若强行按 UTF-8 会中文乱码。
                    // Encoding match: PS 5.1 pipes bytes in the system code page (GBK 936 on zh-CN);
                    // decode with Encoding.Default (system ANSI codepage). Decoding as UTF-8 garbles CJK.
                    p.StartInfo.StandardOutputEncoding = new UTF8Encoding(false); p.StartInfo.StandardErrorEncoding = new UTF8Encoding(false);
                    p.StartInfo.EnvironmentVariables["DM_BASE"] = Base;
                    p.OutputDataReceived += (ss, ee) => { if (ee.Data != null) lock (sb) sb.AppendLine(ee.Data); };
                    p.ErrorDataReceived += (ss, ee) => { if (ee.Data != null) lock (sb) sb.AppendLine("[err] " + ee.Data); };
                    p.Start(); p.BeginOutputReadLine(); p.BeginErrorReadLine(); p.WaitForExit();
                }
                catch (Exception ex) { return "@@TITLE@@ Error | Run: " + ex.Message; }


                finally { DeleteTempScript(temp); }
            }
            return sb.ToString();
        }

        // ---------- Tab2 设备 ----------
        class DevRow { public string Guid = "", Name = "", Hw = "", Itf = "", Fx = ""; public long FF = -1; public int State = 0; }

        void RefreshDevices()
        {
            // 强制在 UI 线程执行，避免与切页自动刷新并发操作 devList
            if (InvokeRequired) { try { BeginInvoke((Action)RefreshDevices); } catch { } return; }
            Append(boxDevice, "");
            Append(boxDevice, s("===== 刷新设备列表（已插入排最前） =====", "===== Refresh devices (active first) ====="));
            devList.Items.Clear();
            try
            {
                var rows = new List<DevRow>();
                using (var rk = Registry.LocalMachine.OpenSubKey(RENDER))
                {
                    if (rk == null) { Append(boxDevice, s("[错误] 无法读取渲染端点注册表。", "[Error] cannot read render endpoint registry.")); return; }
                    foreach (string g in rk.GetSubKeyNames())
                    {
                        var r = new DevRow { Guid = g };
                        using (var k = rk.OpenSubKey(g + "\\Properties"))
                        {
                            if (k != null)
                            {
                                object v;
                                v = k.GetValue(NAMEKEY); if (v != null) r.Name = v.ToString();
                                v = k.GetValue(HWKEY);   if (v != null) r.Hw = v.ToString();
                                v = k.GetValue(IFKEY);   if (v != null) r.Itf = v.ToString();
                                v = k.GetValue(FFKEY);   if (v != null) { try { r.FF = Convert.ToInt64(v); } catch { } }
                            }
                        }
                        using (var k = rk.OpenSubKey(g))
                            if (k != null) { var v = k.GetValue("DeviceState"); if (v != null) r.State = (int)v; }
                        using (var k = rk.OpenSubKey(g + "\\FxProperties"))
                            if (k != null) { var v = k.GetValue(FX_SET); if (v != null) r.Fx = v is string[] ? string.Join("; ", (string[])v) : v.ToString(); }
                        rows.Add(r);
                    }
                }
                rows.Sort((a, b) => {
                    int ra = StateRank(a.State), rb = StateRank(b.State);
                    if (ra != rb) return ra.CompareTo(rb);
                    int c = string.Compare(a.Hw, b.Hw, StringComparison.CurrentCultureIgnoreCase);
                    if (c != 0) return c;
                    return string.Compare(a.Name, b.Name, StringComparison.CurrentCultureIgnoreCase);
                });
                foreach (var r in rows)
                {
                    string name = r.Name.Length > 0 ? r.Name : s("(未命名)", "(unnamed)");
                    string hw = r.Hw.Length > 0 ? r.Hw : "-";
                    var li = new ListViewItem(name);
                    li.SubItems.Add(hw);
                    li.SubItems.Add(TypeText(r.FF, r.Itf));
                    li.SubItems.Add(StateText(r.State));
                    li.SubItems.Add(r.Fx.IndexOf(DOLBY, StringComparison.OrdinalIgnoreCase) >= 0 ? s("杜比", "Dolby") : s("无", "No"));
                    li.SubItems.Add(ShortGuid(r.Guid));
                    li.Tag = r.Guid;
                    li.ToolTipText = r.Guid + (r.Itf.Length > 0 ? "  [" + r.Itf + "]" : "");
                    if (r.State == 1) li.ForeColor = Color.DarkGreen;
                    else if ((r.State & 4) != 0 || (r.State & 8) != 0) li.ForeColor = Color.Gray;
                    devList.Items.Add(li);
                }
                Append(boxDevice, s("[完成] 共 ", "[Done] ") + devList.Items.Count + s(" 个渲染端点（已插入排最前）。绿色=当前已插入。选一个点“加杜比”。", " render endpoint(s), active first. Green = plugged in. Select one and click Add Dolby."));
            }
            catch (Exception ex) { Append(boxDevice, s("[错误] ", "[Error] ") + ex.Message); }
        }

        string StateText(int s)
        {
            if (s == 1) return T1("已插入", "Active");
            if ((s & 8) != 0) return T1("未插", "Unplugged");
            if ((s & 4) != 0) return T1("不存在", "Not present");
            if ((s & 2) != 0) return T1("禁用", "Disabled");
            return "0x" + s.ToString("X8");
        }

        int StateRank(int s) { if (s == 1) return 0; if ((s & 8) != 0) return 1; if ((s & 2) != 0) return 2; if ((s & 4) != 0) return 3; return 4; }

        string TypeText(long ff, string itf)
        {
            string f = ff == 1 ? T1("扬声器", "Speaker") : ff == 2 ? T1("线路", "Line") : ff == 3 ? T1("耳机", "Headphone") : ff == 4 ? T1("麦克风", "Mic") : ff == 5 ? T1("耳麦", "Headset") : ff == 7 ? T1("数字直通", "Digital") : ff == 8 ? "SPDIF" : ff == 9 ? "HDMI/DP" : T1("扬声器?", "Speaker?");
            string i = itf.StartsWith("BTHHFENUM") ? T1("蓝牙免提", "BT HF") : itf.StartsWith("BTHENUM") ? T1("蓝牙", "BT") : itf.StartsWith("USB") ? "USB" : itf.StartsWith("HDAUDIO") ? T1("高清音频", "HDAudio") : itf.StartsWith("ROOT") ? T1("系统", "System") : itf.Length > 0 ? itf : "?";
            return f + "·" + i;
        }

        // 状态/类型短文本双语的别名（避免与控件方法名冲突） / short bilingual alias for state/type texts
        string T1(string zh, string en) { return Program.T(zh, en); }

        string ShortGuid(string g) { if (g.Length < 36) return g; return g.Substring(0, 8) + "…" + g.Substring(g.Length - 4); }

        void DeviceAction(string action)
        {
            if (devList.SelectedItems.Count == 0) { Msg(s("请先在列表里选一个设备。", "Please select a device in the list first.")); return; }
            string g = (string)devList.SelectedItems[0].Tag;
            Run(boxDevice, "APOHook.ps1", action + " " + Quote(g));
        }

        // ---------- Tab3 调音 ----------
        void RefreshTunings()
        {
            // 强制在 UI 线程执行（按钮在后台线程调用时转回 UI 线程），避免与切页自动刷新并发操作 ListBox.Items
            if (IsDisposed || Disposing || tuneList == null || tuneList.IsDisposed || tuneList.Disposing) return;
            if (InvokeRequired) { try { BeginInvoke((Action)RefreshTunings); } catch { } return; }
            try
            {
                Append(boxTuning, "");
                Append(boxTuning, s("===== 刷新调音列表 =====", "===== Refresh tuning list ====="));
                tuningRows.Clear();
                string pkg = FindTuningDir();
                string inst = TUNING;
                if (pkg.Length == 0) { Append(boxTuning, s("[错误] 包内调音目录不存在（Drivers 下无含调音的目录）。", "[Error] tuning directory not found (no tuning dir under Drivers).")); return; }
                string dev = MachineDev();
                Append(boxTuning, s("本机: ", "Machine: ") + (dev.Length > 0 ? dev : s("(未识别)", "(unknown)")) + s("  已安装调音目录: ", "  installed tuning dir: ") + (Directory.Exists(inst) ? inst : s("(无)", "(none)")));
                // 快扫缓存：keyState 持久化到 TuningCache.txt，后续扫描只对缓存缺失(新文件)读 XML；
                // 型号名每次从 TuningNames 内存字典查（即时反映新合并的型号，未匹配的标"待查型号"）。
                string cachePath = Path.Combine(Base, "Data", "TuningCache.txt");
                var cache = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                if (File.Exists(cachePath))
                {
                    try
                    {
                        foreach (string line in File.ReadAllLines(cachePath))
                        {
                            int i = line.IndexOf('\t');
                            if (i > 0) cache[line.Substring(0, i)] = line.Substring(i + 1);
                        }
                    }
                    catch { }
                }
                int empty = 0, bound = 0, newRead = 0;
                var save = new List<string>();
                // 绑定了调音文件的设备名（标记前移显示）：
                //   Realtek 主匹配 → DEV_<dev> 文件；USB 通用调音文件 → Headphone_Default_Generic_Default_*
                string rtkDevName = ActiveDeviceName("Realtek", false);   // 激活的 Realtek 端点名（如 扬声器）
                string usbDevName = ActiveDeviceName("USB", true);        // 激活的 USB/蓝牙端点名（如 MBQUART）
                foreach (string f in Directory.GetFiles(pkg, "DEV_*.xml"))
                {
                    string name = Path.GetFileName(f);
                    string ks;
                    if (cache.TryGetValue(name, out ks)) { }
                    else
                    {
                        bool? ke = KeyEmpty(f);
                        ks = ke == true ? "[空key]" : ke == false ? "[绑定]" : "[无key]";
                        newRead++;
                    }
                    if (ks == "[空key]") empty++; else if (ks == "[绑定]") bound++;
                    save.Add(name + "\t" + ks);
                    string pretty = "";
                    var m = Regex.Match(name, @"^DEV_([0-9A-Fa-f]{4})_SUBSYS_([0-9A-Fa-f]{8})");
                    if (m.Success)
                    {
                        string subsys = m.Groups[2].Value;
                        string model = "";
                        string baseInfo = CodecName(m.Groups[1].Value.ToUpperInvariant()) + " · " + subsys;
                        if (TuningNames.TryGetValue(subsys, out model) && !string.IsNullOrEmpty(model))
                            pretty = baseInfo + " · " + model;
                        else
                            pretty = baseInfo + " ·" + s("(待查型号)", "(model unknown)");
                    }
                    // 绑定标记前移：文件名前显示 [设备名]；Realtek 主匹配（且非自定义）也标
                    string bindPrefix = "";
                    if (rtkDevName.Length > 0 && name.StartsWith("DEV_" + dev) && name.IndexOf("_Custom_", StringComparison.OrdinalIgnoreCase) < 0)
                        bindPrefix = "[" + rtkDevName + "] ";
                    else if (usbDevName.Length > 0 && name.StartsWith("DEV_") && NormHash(f) == UsbGenericHash(inst) && name.IndexOf("_Custom_", StringComparison.OrdinalIgnoreCase) < 0)
                        bindPrefix = "[" + usbDevName + "] ";
                    // 设备列：绑定的活动设备名，未绑定标 Realtek（DEV_* 属 Realtek 编解码器）
                    string devCol = bindPrefix.Length > 0 ? bindPrefix.TrimEnd(' ') : s("Realtek", "Realtek");
                    tuningRows.Add(new string[] { devCol, name, pretty + "  " + ks, "R" });
                }
                // USB 通用调音文件独立行（DAX3 对 USB/蓝牙设备回退加载）
                string ug = Path.Combine(inst, "Headphone_Default_Generic_Default_DolbyAtmosSpeakerSystem.xml");
                if (File.Exists(ug))
                {
                    string ugName = Path.GetFileName(ug);
                    string ugModel = UsbGenericModel(pkg, ug);
                    tuningRows.Add(new string[] {
                        usbDevName.Length > 0 ? "[" + usbDevName + "]" : s("USB/蓝牙", "USB/BT"),
                        ugName,
                        s("USB/蓝牙 通用调音", "USB/BT generic") + (ugModel.Length > 0 ? " · " + ugModel : "") + "  " +
                        s("(当前内容)", "(current)"),
                        "U" });
                }
                try { Directory.CreateDirectory(Path.GetDirectoryName(cachePath)); File.WriteAllLines(cachePath, save); } catch { }
                ApplyTuningFilter();
                Append(boxTuning, s("包内共 ", "Package has ") + tuningRows.Count + s(" 个调音（格式: 文件名 + 声卡·子系统·型号）。", " tuning(s) (format: filename + codec·subsys·model).") +
                    s("空key ", " key-less ") + empty + s(" 个可自由切换 / 绑定 ", " switchable / bound ") + bound + s(" 个可能被拒。", " may be rejected.") +
                    (newRead > 0 ? s("  本次新读 ", "  read ") + newRead + s(" 个，其余走快扫缓存。", " fresh, rest from cache.") : s("  全部走快扫缓存。", "  all from cache.")));
                // USB/蓝牙 等非 Realtek 设备的通用调音状态（DAX3 回退加载 Headphone_Default_Generic_Default_*）
                string usbInfo = UsbGenericStatus(pkg, inst);
                if (usbInfo.Length > 0) Append(boxTuning, usbInfo);
            }
            catch (Exception ex) { Program.LogError("RefreshTunings内部", ex); }
        }

        // 按目标设备筛选渲染列表 / render list filtered by target device
        void ApplyTuningFilter()
        {
            if (tuneList == null || tuneList.IsDisposed) return;
            try
            {
                int sel = (cmbTuningDevice != null) ? cmbTuningDevice.SelectedIndex : 0;
                tuneList.BeginUpdate();
                tuneList.Items.Clear();
                foreach (string[] row in tuningRows)
                {
                    bool isUsb = row.Length > 3 && row[3] == "U";
                    if (sel == 1 && isUsb) continue;     // 只看 Realtek
                    if (sel == 2 && !isUsb) continue;    // 只看 USB/蓝牙
                    ListViewItem it = new ListViewItem(row[0]);
                    it.SubItems.Add(row[1]);
                    it.SubItems.Add(row[2]);
                    tuneList.Items.Add(it);
                }
                tuneList.EndUpdate();
            }
            catch (Exception ex) { Program.LogError("ApplyTuningFilter", ex); }
        }

        string UsbGenericStatus(string pkg, string inst)
        {
            // USB 设备不匹配 DEV_*_SUBSYS_*.xml，DAX3 回退加载通用调音文件。这里显示它当前是哪个机型调音。
            try
            {
                string g = Path.Combine(inst, "Headphone_Default_Generic_Default_DolbyAtmosSpeakerSystem.xml");
                if (!File.Exists(g)) return "";
                string norm = NormHash(g);
                string match = "", model = "";
                if (Directory.Exists(pkg))
                    foreach (string f in Directory.GetFiles(pkg, "DEV_*.xml"))
                        if (NormHash(f) == norm) { match = Path.GetFileName(f); break; }
                if (match.Length > 0)
                {
                    var m = Regex.Match(match, @"^DEV_([0-9A-Fa-f]{4})_SUBSYS_([0-9A-Fa-f]{8})");
                    if (m.Success && TuningNames.TryGetValue(m.Groups[2].Value, out model) && model.Length == 0) model = "";
                }
                return s("USB/蓝牙 通用调音（MBQUART 等设备实际加载）: ", "USB/Bluetooth generic tuning (loaded by MBQUART etc.): ") +
                       (match.Length > 0
                           ? match + (model.Length > 0 ? " · " + model : "")
                           : s("（出厂通用内容，未匹配机型调音）", "(factory generic, no model match)")) +
                       s("   ← 在「切换调音」页选中任意机型调音后点“切换选中调音”（自动识别 USB 目标）", "   <- on the Tuning tab select any tuning then click Switch (auto-detects USB target)");
            }
            catch { return ""; }
        }

        string NormHash(string path)
        {
            try
            {
                string c = File.ReadAllText(path, Encoding.UTF8);
                c = Regex.Replace(c, "<security-key value=\"[^\"]*\"", "<security-key value=\"\"");
                using (var sha = System.Security.Cryptography.SHA256.Create())
                {
                    var b = sha.ComputeHash(Encoding.UTF8.GetBytes(c));
                    return BitConverter.ToString(b).Replace("-", "").Substring(0, 16);
                }
            }
            catch { return ""; }
        }

        string UsbGenericHash(string inst)
        {
            string g = Path.Combine(inst, "Headphone_Default_Generic_Default_DolbyAtmosSpeakerSystem.xml");
            return File.Exists(g) ? NormHash(g) : "";
        }

        string UsbGenericModel(string pkg, string ugPath)
        {
            try
            {
                string norm = NormHash(ugPath);
                if (Directory.Exists(pkg))
                    foreach (string f in Directory.GetFiles(pkg, "DEV_*.xml"))
                        if (NormHash(f) == norm)
                        {
                            var m = Regex.Match(Path.GetFileName(f), @"^DEV_([0-9A-Fa-f]{4})_SUBSYS_([0-9A-Fa-f]{8})");
                            string model = "";
                            if (m.Success && TuningNames.TryGetValue(m.Groups[2].Value, out model) && !string.IsNullOrEmpty(model))
                                return model;
                        }
            }
            catch { }
            return "";
        }

        string ActiveDeviceName(string kind, bool usb)
        {
            // 返回激活端点的设备名：kind=Realtek→第一个激活的 Realtek 端点名；kind=USB→激活的 USB/蓝牙端点名。
            // 仅用于调音列表"绑定"标记显示。
            try
            {
                using (var rk = Registry.LocalMachine.OpenSubKey(RENDER))
                {
                    if (rk == null) return "";
                    foreach (string g in rk.GetSubKeyNames())
                    {
                        int st = 0;
                        using (var k0 = rk.OpenSubKey(g)) { if (k0 != null) { var sv = k0.GetValue("DeviceState"); if (sv != null) st = Convert.ToInt32(sv); } }
                        if (st != 1) continue;   // 仅激活端点
                        using (var kp = rk.OpenSubKey(g + "\\Properties"))
                        {
                            if (kp == null) continue;
                            string hw = kp.GetValue(HWKEY) as string ?? "";
                            string ifc = kp.GetValue(IFKEY) as string ?? "";
                            string name = kp.GetValue(NAMEKEY) as string ?? "";
                            bool isUsb = ifc.StartsWith("USB", StringComparison.OrdinalIgnoreCase) ||
                                         ifc.StartsWith("BTH", StringComparison.OrdinalIgnoreCase) ||
                                         hw.IndexOf("USB", StringComparison.OrdinalIgnoreCase) >= 0 ||
                                         hw.IndexOf("Bluetooth", StringComparison.OrdinalIgnoreCase) >= 0;
                            if (usb && isUsb && name.Length > 0) return name;
                            if (!usb && !isUsb && hw.IndexOf("Realtek", StringComparison.OrdinalIgnoreCase) >= 0 && name.Length > 0) return name;
                        }
                    }
                }
            }
            catch { }
            return "";
        }

        void LoadTuningNames()
        {
            // 型号映射文件：每行 "17AAXXXX<TAB>型号名"。运行时读取，新增型号无需重编译。位于 Data 目录。
            string p = Path.Combine(Base, "Data", "TuningNames.txt");
            if (!File.Exists(p)) return;
            try
            {
                foreach (string line in File.ReadAllLines(p))
                {
                    int i = line.IndexOf('\t');
                    if (i > 0 && i < line.Length - 1) TuningNames[line.Substring(0, i).Trim().ToUpperInvariant()] = line.Substring(i + 1).Trim();
                }
            }
            catch { }
        }

        void TuningAction(string action)
        {
            if (tuneList.SelectedItems.Count == 0) { Msg(s("请先在列表里选一个调音。", "Please select a tuning in the list first.")); return; }
            // 调音文件列（SubItems[1]）为文件名；取文件名（DEV_*.xml 或 Headphone_Default_Generic_*.xml）
            string disp = tuneList.SelectedItems[0].SubItems[1].Text;
            var mm = Regex.Match(disp, @"(?:DEV_[A-Za-z0-9_]+\.xml|Headphone_Default_Generic_[A-Za-z0-9_]+\.xml)");
            string name = mm.Success ? mm.Value : disp.Split(' ')[0];
            Run(boxTuning, "TuningSwitcher.ps1", action + " " + Quote(name));
        }

        bool? KeyEmpty(string file)
        {
            try
            {
                string c = File.ReadAllText(file, Encoding.UTF8);
                var m = Regex.Match(c, "<security-key value=\"([^\"]*)\"");
                if (!m.Success) return null;
                return m.Groups[1].Value.Length == 0;
            }
            catch { return null; }
        }

        string MachineDev()
        {
            try
            {
                using (var rk = Registry.LocalMachine.OpenSubKey(MEDIA))
                {
                    if (rk == null) return "";
                    foreach (string n in rk.GetSubKeyNames())
                    {
                        if (!Regex.IsMatch(n, @"^\d+$")) continue;
                        using (var k = rk.OpenSubKey(n))
                        {
                            if (k == null) continue;
                            var v = k.GetValue("MatchingDeviceId");
                            if (v == null) continue;
                            string mid = v.ToString();
                            if (mid.IndexOf("VEN_10EC", StringComparison.OrdinalIgnoreCase) >= 0)
                            {
                                var md = Regex.Match(mid, "DEV_([0-9A-Fa-f]{4})");
                                var ms = Regex.Match(mid, "SUBSYS_([0-9A-Fa-f]{8})");
                                if (md.Success && ms.Success) return md.Groups[1].Value.ToUpperInvariant() + "_SUBSYS_" + ms.Groups[1].Value.ToUpperInvariant();
                            }
                        }
                    }
                }
                // PnP 兜底：MatchingDeviceId 通常没有 SUBSYS，从 Enum\HDAUDIO|INTELAUDIO 实例路径补（纯注册表）
                foreach (string bus in new[] { "HDAUDIO", "INTELAUDIO" })
                {
                    using (var rk = Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Enum\" + bus))
                    {
                        if (rk == null) continue;
                        foreach (string id in rk.GetSubKeyNames())
                        {
                            if (id.IndexOf("VEN_10EC", StringComparison.OrdinalIgnoreCase) < 0) continue;
                            var md = Regex.Match(id, "DEV_([0-9A-Fa-f]{4})");
                            var ms = Regex.Match(id, "SUBSYS_([0-9A-Fa-f]{8})");
                            if (md.Success && ms.Success) return md.Groups[1].Value.ToUpperInvariant() + "_SUBSYS_" + ms.Groups[1].Value.ToUpperInvariant();
                        }
                    }
                }
            }
            catch { }
            return "";
        }

        string Quote(string s) { return "'" + s.Replace("'", "''") + "'"; }
    }
}

