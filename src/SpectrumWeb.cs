// SpectrumWeb.cs — WebView2 集成原版 3D-Spectrogram（Three.js）+ ODAS 风格人头方向
// WebView2 hosting the original 3D-Spectrogram (Three.js) + ODAS-style head/direction dial
// C# 端：WASAPI 环回捕获 → FFT → 推频谱(0-255) 与 声像 pan 进页面
// C# side: WASAPI loopback capture -> FFT -> push spectrum (0-255) and pan into the page
using System;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;

namespace DolbyMaster
{
    // ================= 3D 频谱 Web 控件（顶栏 + WebView2）/ 3D spectrum web control =================
    public class SpectrumWebControl : UserControl
    {
        // 共享 WebView2 环境：只创建一次并持有，避免关闭浮动窗后重建环境时 CO_E_NOTINITIALIZED
        // shared WebView2 environment: created once and retained to avoid CO_E_NOTINITIALIZED on rebuild
        static CoreWebView2Environment _sharedEnv;
        static object _envLock = new object();

        public Microsoft.Web.WebView2.WinForms.WebView2 Web;
        Button btnPin, btnClose;
        Label lblTitle;
        bool _pinned = true;
        volatile bool _ready;
        string _webDir;
        public event Action ClosedByUser;

        public SpectrumWebControl()
        {
            BackColor = Color.FromArgb(6, 8, 16);
            _webDir = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Web", "3D-Spectrogram-main");
            // 顶栏 / top bar（双语 / bilingual）
            var top = new Panel { Dock = DockStyle.Top, Height = 34, BackColor = Color.FromArgb(28, 32, 46) };
            lblTitle = new Label {
                Text = Program.T("3D 频谱 · 杜比管家", "3D Spectrogram · DolbyMaster"),
                AutoSize = false, Dock = DockStyle.Fill,
                ForeColor = Color.White, TextAlign = ContentAlignment.MiddleLeft,
                Padding = new Padding(8, 0, 0, 0)
            };
            btnPin = new Button {
                Text = Program.T("固定前台", "Pin Top"), Width = 92, Height = 26, FlatStyle = FlatStyle.Flat,
                BackColor = Color.FromArgb(0, 120, 215), ForeColor = Color.White
            };
            btnClose = new Button {
                Text = Program.T("关闭", "Close"), Width = 64, Height = 26, FlatStyle = FlatStyle.Flat,
                BackColor = Color.FromArgb(180, 40, 40), ForeColor = Color.White
            };
            btnPin.Location = new Point(Width - 176, 4);
            btnClose.Location = new Point(Width - 84, 4);
            btnPin.Anchor = AnchorStyles.Top | AnchorStyles.Right;
            btnClose.Anchor = AnchorStyles.Top | AnchorStyles.Right;
            btnPin.Click += (s, e) => TogglePin();
            btnClose.Click += (s, e) => RequestClose();
            top.Controls.Add(btnClose);
            top.Controls.Add(btnPin);
            top.Controls.Add(lblTitle);
            Web = new Microsoft.Web.WebView2.WinForms.WebView2 { Dock = DockStyle.Fill };
            Controls.Add(Web);
            Controls.Add(top);
            UpdatePinLabel();
            InitWeb();
        }

        async void InitWeb()
        {
            // WebView2 必须从创建它的 STA UI 线程访问 / WebView2 must run on its creating STA UI thread
            if (InvokeRequired) { BeginInvoke(new Action(InitWeb)); return; }
            try
            {
                CoreWebView2Environment env = null;
                if (_sharedEnv != null) env = _sharedEnv;
                else
                {
                    lock (_envLock)
                    {
                        if (_sharedEnv == null)
                        {
                            string ud = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "WebView2Data");
                            // 同步创建一次环境（UI 线程）；CreateAsync 在错误线程会 CO_E_NOTINITIALIZED
                            // create the environment once synchronously on the UI thread
                            _sharedEnv = CoreWebView2Environment.CreateAsync(null, ud).Result;
                        }
                        env = _sharedEnv;
                    }
                }
                if (env == null) return;
                await Web.EnsureCoreWebView2Async(env);
                var core = Web.CoreWebView2;
                if (core == null) return;
                core.SetVirtualHostNameToFolderMapping("spectrum.local", _webDir,
                    Microsoft.Web.WebView2.Core.CoreWebView2HostResourceAccessKind.Allow);
                Web.Source = new Uri("https://spectrum.local/index.html");
                _ready = true;
                PushLang(Program.CurrentLang);   // 页面随主程序语言 / page follows app language
            }
            catch (Exception ex)
            {
                try
                {
                    File.AppendAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "spectrum.log"),
                        "[" + DateTime.Now.ToString("HH:mm:ss.fff") + "] WebView2 初始化失败: " + ex.Message + "\r\n");
                }
                catch { }
            }
        }

        void RequestClose()
        {
            try
            {
                Form f = FindForm();
                if (f != null) f.Close();
            }
            catch { }
            if (ClosedByUser != null) ClosedByUser();
        }

        public void TogglePin()
        {
            _pinned = !_pinned;
            Form f = FindForm();
            if (f != null) f.TopMost = _pinned;
            UpdatePinLabel();
        }

        void UpdatePinLabel()
        {
            if (btnPin == null) return;
            btnPin.Text = _pinned ? Program.T("固定前台 ✓", "Pin Top ✓") : Program.T("固定前台", "Pin Top");
            btnPin.BackColor = _pinned ? Color.FromArgb(0, 120, 215) : Color.FromArgb(80, 90, 110);
        }

        // 推界面语言到页面 / push UI language into the page (zh|en)
        public void PushLang(string lang)
        {
            if (InvokeRequired) { try { BeginInvoke((Action)(() => PushLang(lang))); } catch { } return; }
            if (!_ready || Web == null || Web.CoreWebView2 == null) return;
            try
            {
                Web.CoreWebView2.PostWebMessageAsJson(
                    "{\"type\":\"lang\",\"value\":\"" + (lang == "en" ? "en" : "zh") + "\"}");
            }
            catch { }
        }

        // 推频谱帧（0-255，1024 bins）到页面 / push spectrum frame (0-255, 1024 bins) into page
        public void PushSpectrum(byte[] bins)
        {
            // CoreWebView2 必须 UI 线程访问 / CoreWebView2 must be accessed on the UI thread
            if (InvokeRequired) { try { BeginInvoke((Action)(() => PushSpectrum(bins))); } catch { } return; }
            if (!_ready || Web == null || Web.CoreWebView2 == null) return;
            try
            {
                var sb = new StringBuilder(bins.Length * 4 + 32);
                sb.Append("{\"type\":\"spectrum\",\"data\":[");
                for (int i = 0; i < bins.Length; i++)
                {
                    if (i > 0) sb.Append(',');
                    sb.Append(bins[i]);
                }
                sb.Append("]}");
                Web.CoreWebView2.PostWebMessageAsJson(sb.ToString());
            }
            catch { }
        }

        // 推方向角（度，0=前/±180=后）+ 是否多声道 / push azimuth (degrees, 0=front, ±180=rear) + multichannel flag
        public void PushPan(float angle, bool multi)
        {
            if (InvokeRequired) { try { BeginInvoke((Action)(() => PushPan(angle, multi))); } catch { } return; }
            if (!_ready || Web == null || Web.CoreWebView2 == null) return;
            try
            {
                string a = angle.ToString("R", CultureInfo.InvariantCulture);
                Web.CoreWebView2.PostWebMessageAsJson(
                    "{\"type\":\"pan\",\"angle\":" + a + ",\"multi\":" + (multi ? "true" : "false") + "}");
            }
            catch { }
        }

        public void PushStop()
        {
            if (InvokeRequired) { try { BeginInvoke((Action)(PushStop)); } catch { } return; }
            if (!_ready || Web == null || Web.CoreWebView2 == null) return;
            try { Web.CoreWebView2.PostWebMessageAsJson("{\"type\":\"stop\"}"); }
            catch { }
        }
    }

    // ================= 频谱浮动窗 / floating spectrum window =================
    public class SpectrumForm : Form
    {
        public SpectrumWebControl Host;
        public event Action ClosedByUser;

        public SpectrumForm()
        {
            Text = "DolbyMaster 3D Spectrum";
            FormBorderStyle = FormBorderStyle.SizableToolWindow;
            TopMost = true;                       // 默认置顶 / pinned by default
            StartPosition = FormStartPosition.CenterScreen;
            ClientSize = new Size(800, 520);
            BackColor = Color.FromArgb(6, 8, 16);
            Host = new SpectrumWebControl { Dock = DockStyle.Fill };
            Host.ClosedByUser += () => { if (ClosedByUser != null) ClosedByUser(); };
            Controls.Add(Host);
            FormClosing += (s, e) =>
            {
                if (ClosedByUser != null) ClosedByUser();
            };
        }

        public void PushSpectrum(byte[] bins) { if (Host != null) Host.PushSpectrum(bins); }
        public void PushPan(float angle, bool multi) { if (Host != null) Host.PushPan(angle, multi); }
    }
}
