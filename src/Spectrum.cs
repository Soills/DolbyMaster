// Spectrum.cs — 声音可视化：WASAPI 环回捕获 + FFT 频谱 + 彩色频谱控件 + 浮动窗
// Sound visualization: WASAPI loopback capture + FFT spectrum + colored spectrum control + floating window
// 编译要求：C# 5 兼容（csc v4.0.30319），无外部依赖，纯 P/Invoke COM + GDI+。
// C# 5 compatible (csc v4.0.30319), no external deps, pure P/Invoke COM + GDI+.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

namespace DolbyMaster
{
    // ================= WASAPI 环回捕获 / WASAPI loopback capture =================
    // 用 COM 接口（非托管委托）安全调用：IMMDeviceEnumerator → GetDefaultAudioEndpoint(eRender,eConsole)
    // → Activate(IAudioClient) → Initialize(LOOPBACK) → GetService(IAudioCaptureClient) → 后台线程 GetBuffer。
    // 捕获当前默认播放设备正在输出的混音（含 Dolby APO 处理后的声音）。
    public class WasapiLoopback
    {
        // ---- COM GUIDs ----
        static readonly Guid CLSID_MMDeviceEnumerator = new Guid("BCDE0395-E52F-467C-8E3D-C4579291692E");
        static readonly Guid IID_IMMDeviceEnumerator  = new Guid("A95664D2-9614-4F35-A746-DE8DB63617E6");
        static readonly Guid IID_IAudioClient         = new Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2");
        static readonly Guid IID_IAudioCaptureClient  = new Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317");
        static readonly Guid IID_IAudioMeterInformation = new Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064");

        const int CLSCTX_ALL = 23;
        const int AUDCLNT_SHAREMODE_SHARED = 0;
        const int AUDCLNT_STREAMFLAGS_LOOPBACK = 0x20000;

        // ---- COM 接口定义（ComImport + vtable 顺序必须精确）----
        [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IMMDeviceEnumerator
        {
            [PreserveSig] int EnumAudioEndpoints(int dataFlow, int dwStateMask, out IntPtr ppDevices);
            [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IntPtr ppDevice);
            [PreserveSig] int GetDevice(string pwstrId, out IntPtr ppDevice);
            [PreserveSig] int RegisterEndpointNotificationCallback(IntPtr pClient);
            [PreserveSig] int UnregisterEndpointNotificationCallback(IntPtr pClient);
        }

        [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IMMDevice
        {
            [PreserveSig] int Activate(ref Guid iid, int dwClsCtx, IntPtr pActivationParams, out IntPtr ppInterface);
            [PreserveSig] int OpenPropertyStore(int stgmAccess, out IntPtr ppProperties);
            [PreserveSig] int GetId(out IntPtr ppstrId);
            [PreserveSig] int GetState(out int pdwState);
        }

        [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IMMDeviceCollection
        {
            [PreserveSig] int GetCount(out int pcDevices);
            [PreserveSig] int Item(int nDevice, out IntPtr ppDevice);
        }

        [ComImport, Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IAudioMeterInformation
        {
            [PreserveSig] int GetPeakValue(out float pfPeak);
            [PreserveSig] int GetMeteringChannelCount(out int pcChannels);
            [PreserveSig] int GetChannelsPeakValues(int u32ChannelCount, [In, Out] float[] afPeakValues);
            [PreserveSig] int QueryHardwareSupport(out int pdwHardwareSupportMask);
        }

        [ComImport, Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IAudioClient
        {
            [PreserveSig] int Initialize(int ShareMode, int StreamFlags, long hnsBufferDuration, long hnsPeriodicity, IntPtr pFormat, ref Guid AudioSessionGuid);
            [PreserveSig] int GetBufferSize(out int pNumBufferFrames);
            [PreserveSig] int GetStreamLatency(out long phnsLatency);
            [PreserveSig] int GetCurrentPadding(out int pNumPaddingFrames);
            [PreserveSig] int IsFormatSupported(int ShareMode, IntPtr pFormat, out IntPtr ppClosestMatch);
            [PreserveSig] int GetMixFormat(out IntPtr ppDeviceFormat);
            [PreserveSig] int GetDevicePeriod(out long phnsDefaultDevicePeriod, out long phnsMinimumDevicePeriod);
            [PreserveSig] int Start();
            [PreserveSig] int Stop();
            [PreserveSig] int Reset();
            [PreserveSig] int SetEventHandle(IntPtr eventHandle);
            [PreserveSig] int GetService(ref Guid iid, out IntPtr ppv);
        }

        [ComImport, Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IAudioCaptureClient
        {
            [PreserveSig] int GetBuffer(out IntPtr ppData, out int pNumFramesToRead, out int pdwFlags, out long pu64DevicePosition, out long pu64QPCPosition);
            [PreserveSig] int ReleaseBuffer(int nFramesRead);
            [PreserveSig] int GetNextPacketSize(out int pNumFramesInNextPacket);
        }

        // ---- 非托管导入 / native imports ----
        [DllImport("ole32.dll")]
        static extern int CoCreateInstance(ref Guid rclsid, IntPtr pUnkOuter, int dwClsContext, ref Guid riid, out IntPtr ppv);
        [DllImport("ole32.dll")]
        static extern int CoInitializeEx(IntPtr pvReserved, int dwCoInit);
        [DllImport("ole32.dll")]
        static extern void CoUninitialize();

        [StructLayout(LayoutKind.Sequential, Pack = 1)]
        struct WAVEFORMATEX
        {
            public ushort wFormatTag;
            public ushort nChannels;
            public uint nSamplesPerSec;
            public uint nAvgBytesPerSec;
            public ushort nBlockAlign;
            public ushort wBitsPerSample;
            public ushort cbSize;
        }

        const ushort WAVE_FORMAT_EXTENSIBLE = 0xFFFE;
        const ushort WAVE_FORMAT_IEEE_FLOAT  = 0x0003;
        const ushort WAVE_FORMAT_PCM         = 0x0001;

        bool _running;
        Thread _thread;
        public int SampleRate = 48000;
        public int Channels = 2;
        public volatile float[] LatestSamples;   // 最近一次捕获块（float，交错或按声道取均值后）latest captured block (floats, mono-ized)
        public string DeviceName = "";
        public string DeviceId = "";             // 当前实际捕获的设备 GUID / device GUID actually captured
        public string LastError = "";
        public volatile bool GotData;
        public string TargetDeviceId = "";       // 空=默认设备；非空=按 GUID 捕获 / empty=default; set GUID to capture that device
        public long LastDataTick;                // 最近收到数据的 tick / tick of last received data (plain field: volatile doesn't support long)
        public volatile float CurrentPeak;       // 最近一帧最大幅值 / max amplitude of last frame
        public volatile float LeftRms, RightRms; // 最近一帧左右声道 RMS（声像定位用）/ L/R channel RMS (for pan/DOA estimation)
        public volatile float[] ChanRms;          // 最近一帧每声道 RMS（≥6ch 时算真方位含前后）/ per-channel RMS (true azimuth incl. rear when >=6ch)
        public string DebugInfo = "";             // 诊断：混音格式细节 / diagnostics: mix format details
        public volatile int Blocks;               // 诊断：已处理数据块数 / diagnostics: processed blocks

        // 捕获到的样本交给外部（每次回调一批）on each capture block
        public event Action<float[]> DataReady;

        public void Start()
        {
            if (_running) return;
            _running = true;
            _thread = new Thread(CaptureLoop);
            _thread.IsBackground = true;
            _thread.Name = "WasapiLoopback";
            _thread.Start();
        }

        public void Stop()
        {
            _running = false;
            try { if (_thread != null && _thread.IsAlive) _thread.Join(800); } catch { }
            _thread = null;
        }

        static float ReadFloat(IntPtr p, int off)
        {
            return BitConverter.ToSingle(BitConverter.GetBytes(Marshal.ReadInt32(p, off)), 0);
        }

        static float ReadInt24(IntPtr p, int off)
        {
            int v = Marshal.ReadByte(p, off) | (Marshal.ReadByte(p, off + 1) << 8) | (Marshal.ReadByte(p, off + 2) << 16);
            if ((v & 0x800000) != 0) v |= unchecked((int)0xFF000000);   // sign-extend 24->32
            return v / 8388608f;
        }

        // 枚举激活的渲染端点，返回设备 GUID 列表（供手动选择监视设备）。
        // Enumerate active render endpoints; returns device GUIDs (for manual device picking).
        public static List<string> EnumRenderDevices()
        {
            var ids = new List<string>();
            IntPtr pEnum = IntPtr.Zero, pColl = IntPtr.Zero;
            int co = CoInitializeEx(IntPtr.Zero, 8);   // COINIT_MULTITHREADED
            try
            {
                CoInitializeEx(IntPtr.Zero, 0);
                Guid clsidEnum = CLSID_MMDeviceEnumerator;
                Guid iidEnum = IID_IMMDeviceEnumerator;
                int hr = CoCreateInstance(ref clsidEnum, IntPtr.Zero, CLSCTX_ALL, ref iidEnum, out pEnum);
                if (hr != 0) return ids;
                var enumerator = (IMMDeviceEnumerator)Marshal.GetObjectForIUnknown(pEnum);
                hr = enumerator.EnumAudioEndpoints(0, 1, out pColl);   // eRender=0, DEVICE_STATE_ACTIVE=1
                if (hr != 0) return ids;
                var coll = (IMMDeviceCollection)Marshal.GetObjectForIUnknown(pColl);
                int count = 0;
                if (coll.GetCount(out count) != 0) return ids;
                for (int i = 0; i < count; i++)
                {
                    IntPtr pDev;
                    if (coll.Item(i, out pDev) != 0) continue;
                    var dev = (IMMDevice)Marshal.GetObjectForIUnknown(pDev);
                    IntPtr pid;
                    if (dev.GetId(out pid) == 0)
                    {
                        string id = Marshal.PtrToStringUni(pid);
                        if (!string.IsNullOrEmpty(id)) ids.Add(id);
                        Marshal.FreeCoTaskMem(pid);
                    }
                    Marshal.Release(pDev);
                }
            }
            catch { }
            finally
            {
                if (pColl != IntPtr.Zero) Marshal.Release(pColl);
                if (pEnum != IntPtr.Zero) Marshal.Release(pEnum);
                if (co == 0) CoUninitialize();   // 只有本线程新初始化才拆，避免拆掉 UI 线程已有 COM / only uninit if WE initialized
            }
            return ids;
        }

        // 读系统默认播放设备的实时峰值（IAudioMeterInformation）——独立于我们的环回捕获，
        // 用于判断"系统当前是否有声音"。返回 -1 表示读取失败。
        // Read the default render device's live peak (IAudioMeterInformation) — independent of our loopback
        // capture; used to tell whether the system is currently making sound. -1 on failure.
        public static float DefaultDevicePeak()
        {
            IntPtr pEnum = IntPtr.Zero, pDev = IntPtr.Zero, pMeter = IntPtr.Zero;
            int co = CoInitializeEx(IntPtr.Zero, 8);   // COINIT_MULTITHREADED
            try
            {
                CoInitializeEx(IntPtr.Zero, 0);
                Guid clsidEnum = CLSID_MMDeviceEnumerator;
                Guid iidEnum = IID_IMMDeviceEnumerator;
                int hr = CoCreateInstance(ref clsidEnum, IntPtr.Zero, CLSCTX_ALL, ref iidEnum, out pEnum);
                if (hr != 0) return -1f;
                var enumerator = (IMMDeviceEnumerator)Marshal.GetObjectForIUnknown(pEnum);
                hr = enumerator.GetDefaultAudioEndpoint(0, 0, out pDev);
                if (hr != 0) return -1f;
                var dev = (IMMDevice)Marshal.GetObjectForIUnknown(pDev);
                Guid iidMeter = IID_IAudioMeterInformation;
                hr = dev.Activate(ref iidMeter, CLSCTX_ALL, IntPtr.Zero, out pMeter);
                if (hr != 0) return -1f;
                var meter = (IAudioMeterInformation)Marshal.GetObjectForIUnknown(pMeter);
                float peak;
                if (meter.GetPeakValue(out peak) != 0) return -1f;
                return peak;
            }
            catch { return -1f; }
            finally
            {
                if (pMeter != IntPtr.Zero) Marshal.Release(pMeter);
                if (pDev != IntPtr.Zero) Marshal.Release(pDev);
                if (pEnum != IntPtr.Zero) Marshal.Release(pEnum);
                if (co == 0) CoUninitialize();
            }
        }

        void CaptureLoop()
        {
            IntPtr pEnum = IntPtr.Zero, pDev = IntPtr.Zero, pClient = IntPtr.Zero, pCapture = IntPtr.Zero;
            IntPtr pFormat = IntPtr.Zero;
            int co = CoInitializeEx(IntPtr.Zero, 8);   // COINIT_MULTITHREADED
            try
            {
                CoInitializeEx(IntPtr.Zero, 0);
                Guid clsidEnum = CLSID_MMDeviceEnumerator;      // 静态只读不能 ref，先拷贝 / copy (readonly can't be ref)
                Guid iidEnum = IID_IMMDeviceEnumerator;
                int hr = CoCreateInstance(ref clsidEnum, IntPtr.Zero, CLSCTX_ALL, ref iidEnum, out pEnum);
                if (hr != 0) { LastError = "MMDeviceEnumerator 0x" + hr.ToString("X8"); return; }
                var enumerator = (IMMDeviceEnumerator)Marshal.GetObjectForIUnknown(pEnum);
                if (TargetDeviceId.Length > 0)
                {
                    hr = enumerator.GetDevice(TargetDeviceId, out pDev);   // 按 GUID 指定设备 / capture a specific device
                    if (hr != 0) { LastError = "GetDevice 0x" + hr.ToString("X8"); return; }
                }
                else
                {
                    hr = enumerator.GetDefaultAudioEndpoint(0, 0, out pDev);   // eRender=0, eConsole=0
                    if (hr != 0) { LastError = "GetDefaultAudioEndpoint 0x" + hr.ToString("X8"); return; }
                }
                var device = (IMMDevice)Marshal.GetObjectForIUnknown(pDev);
                // 设备名 / device display name
                try
                {
                    IntPtr pid;
                    if (device.GetId(out pid) == 0) { DeviceId = Marshal.PtrToStringUni(pid); DeviceName = DeviceId; Marshal.FreeCoTaskMem(pid); }
                }
                catch { }
                Guid iidClient = IID_IAudioClient;
                hr = device.Activate(ref iidClient, CLSCTX_ALL, IntPtr.Zero, out pClient);
                if (hr != 0) { LastError = "Activate IAudioClient 0x" + hr.ToString("X8"); return; }
                var client = (IAudioClient)Marshal.GetObjectForIUnknown(pClient);
                // 混音格式 / mix format
                hr = client.GetMixFormat(out pFormat);
                if (hr != 0) { LastError = "GetMixFormat 0x" + hr.ToString("X8"); return; }
                WAVEFORMATEX fmt = (WAVEFORMATEX)Marshal.PtrToStructure(pFormat, typeof(WAVEFORMATEX));
                // 记录采样率/声道 / record rate & channels
                SampleRate = (int)fmt.nSamplesPerSec;
                Channels = fmt.nChannels;
                DebugInfo = "tag=" + fmt.wFormatTag + " bps=" + fmt.wBitsPerSample + " ch=" + fmt.nChannels +
                            " block=" + fmt.nBlockAlign + " cb=" + fmt.cbSize;
                // WAVEFORMATEXTENSIBLE: 读 SubFormat GUID 判断 float/PCM
                // SubFormat GUID 位于 18(WAVEFORMATEX) + 2(wValidBits) + 4(dwChannelMask) = 偏移 24
                // SubFormat GUID data1 at offset 24 (18 + 2 validbits + 4 channelmask)
                bool isFloat = false;
                bool isPcm = false;
                if (fmt.wFormatTag == WAVE_FORMAT_EXTENSIBLE && fmt.cbSize >= 22)
                {
                    int sub = Marshal.ReadInt32(pFormat, 24);
                    isFloat = (sub == WAVE_FORMAT_IEEE_FLOAT);
                    isPcm = (sub == WAVE_FORMAT_PCM);
                }
                else
                {
                    isFloat = (fmt.wFormatTag == WAVE_FORMAT_IEEE_FLOAT);
                    isPcm = (fmt.wFormatTag == WAVE_FORMAT_PCM);
                }
                long hnsDefault = 0, hnsMin = 0;
                client.GetDevicePeriod(out hnsDefault, out hnsMin);
                long bufferHns = hnsDefault * 4; if (bufferHns < 100000) bufferHns = 100000;
                Guid session = Guid.Empty;
                hr = client.Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK, bufferHns, 0, pFormat, ref session);
                if (hr != 0) { LastError = "Initialize LOOPBACK 0x" + hr.ToString("X8"); return; }
                Guid iidCapture = IID_IAudioCaptureClient;
                hr = client.GetService(ref iidCapture, out pCapture);
                if (hr != 0) { LastError = "GetService IAudioCaptureClient 0x" + hr.ToString("X8"); return; }
                var capture = (IAudioCaptureClient)Marshal.GetObjectForIUnknown(pCapture);
                hr = client.Start();
                if (hr != 0) { LastError = "Start 0x" + hr.ToString("X8"); return; }
                // 读取循环 / read loop
                int bytesPerFrame = fmt.nBlockAlign;
                var buf = new List<float>();
                while (_running)
                {
                    int next = 0;
                    if (capture.GetNextPacketSize(out next) != 0) { Thread.Sleep(5); continue; }
                    if (next == 0) { Thread.Sleep(5); continue; }
                    IntPtr pData; int frames; int flags; long devPos, qpc;
                    int hrr = capture.GetBuffer(out pData, out frames, out flags, out devPos, out qpc);
                    if (hrr != 0) { Thread.Sleep(5); continue; }
                    if (frames > 0 && pData != IntPtr.Zero)
                    {
                        // 转 float：float32 / int32 / int24 / int16，多声道取均值（mono），同时累计每声道 RMS（方位/前后用）
                        // decode float32/int32/int24/int16; average to mono; accumulate per-channel RMS (for azimuth/DOA)
                        buf.Clear();
                        int bps = fmt.wBitsPerSample;
                        int cCount = Math.Min(Channels, 8);   // 最多记 8 声道：FL FR FC LFE BL BR SL SR
                        double[] cAcc = new double[cCount];
                        int[] cN = new int[cCount];
                        for (int i = 0; i < frames; i++)
                        {
                            int off = i * Channels;
                            float sum = 0f;
                            for (int c = 0; c < cCount; c++)
                            {
                                float v;
                                if (isFloat && bps == 32) v = ReadFloat(pData, (off + c) * 4);
                                else if (isPcm && bps == 32) v = Marshal.ReadInt32(pData, (off + c) * 4) / 2147483648f;
                                else if (isPcm && bps == 24) v = ReadInt24(pData, (off + c) * 3);
                                else v = (short)Marshal.ReadInt16(pData, (off + c) * 2) / 32768f;   // 16bit 兜底 / 16-bit fallback
                                cAcc[c] += v * v; cN[c]++;
                                sum += v;
                            }
                            buf.Add(sum / Channels);
                        }
                        if (cN[0] > 0)
                        {
                            var cr = new float[cCount];
                            for (int c = 0; c < cCount; c++) cr[c] = cN[c] > 0 ? (float)Math.Sqrt(cAcc[c] / cN[c]) : 0f;
                            ChanRms = cr;
                            LeftRms = cr[0];
                            RightRms = cCount > 1 ? cr[1] : 0f;
                        }
                        Blocks++;
                        var arr = buf.ToArray();
                        LatestSamples = arr;
                        GotData = true;
                        float pk = 0f;
                        for (int i = 0; i < arr.Length; i++) { float a = arr[i]; if (a < 0) a = -a; if (a > pk) pk = a; }
                        CurrentPeak = pk;
                        LastDataTick = DateTime.UtcNow.Ticks;
                        if (DataReady != null) { try { DataReady(arr); } catch { } }
                    }
                    capture.ReleaseBuffer(frames);
                }
                client.Stop();
            }
            catch (Exception ex)
            {
                LastError = ex.Message;
            }
            finally
            {
                if (pFormat != IntPtr.Zero) Marshal.FreeCoTaskMem(pFormat);
                if (pCapture != IntPtr.Zero) Marshal.Release(pCapture);
                if (pClient != IntPtr.Zero) Marshal.Release(pClient);
                if (pDev != IntPtr.Zero) Marshal.Release(pDev);
                if (pEnum != IntPtr.Zero) Marshal.Release(pEnum);
                if (co == 0) CoUninitialize();
            }
        }
    }

    // ================= Radix-2 FFT（4096 点） =================
    public static class Fft
    {
        public static int Size = 4096;

        // 输入 float[]（时域，mono），返回对数幅值数组（dB 归一 0..1）每 bin
        // input time-domain floats; returns log-magnitude per bin (0..1)
        public static float[] ComputeMagnitudes(float[] input)
        {
            int n = Size;
            var re = new double[n];
            var im = new double[n];
            int take = Math.Min(input.Length, n);
            Array.Copy(input, re, take);
            // 汉宁窗 / Hann window
            for (int i = 0; i < n; i++)
                re[i] *= 0.5 - 0.5 * Math.Cos(2 * Math.PI * i / (n - 1));
            FftRadix2(re, im);
            var mag = new float[n / 2];
            double maxMag = 1e-9;
            for (int i = 0; i < n / 2; i++)
            {
                double m = Math.Sqrt(re[i] * re[i] + im[i] * im[i]);
                mag[i] = (float)m;
                if (m > maxMag) maxMag = m;
            }
            // 归一化到 0..1（dB 压缩，参考 -60dB 底噪）
            // normalize to 0..1 with dB compression (floor -60dB)
            double scale = 20.0 * Math.Log10(maxMag + 1e-12);
            if (scale < 1) scale = 1;
            for (int i = 0; i < n / 2; i++)
            {
                double db = 20.0 * Math.Log10(mag[i] + 1e-12) - (scale - 60);
                double v = (db + 60) / 60.0;
                if (v < 0) v = 0; if (v > 1) v = 1;
                mag[i] = (float)v;
            }
            return mag;
        }

        // 绝对 dB 幅值（0dBFS 参考，FFT 归一化 + 汉宁窗补偿），用于 WebView2 注入
        // absolute dB magnitudes (0 dBFS reference, FFT-normalised + Hann-window compensated) for WebView2 injection
        public static float[] ComputeDb(float[] input)
        {
            int n = Size;
            var re = new double[n];
            var im = new double[n];
            int take = Math.Min(input.Length, n);
            Array.Copy(input, re, take);
            for (int i = 0; i < n; i++)
                re[i] *= 0.5 - 0.5 * Math.Cos(2 * Math.PI * i / (n - 1));
            FftRadix2(re, im);
            var db = new float[n / 2];
            // FFT 原始幅值 → 信号幅度：raw = A·N/4（汉宁窗减半），幅度 = raw·4/N；满幅 1.0 → 0 dBFS
            // raw FFT magnitude -> signal amplitude: raw = A·N/4 (Hann halves), amp = raw·4/N; full scale 1.0 -> 0 dBFS
            double norm = 4.0 / n;
            for (int i = 0; i < n / 2; i++)
            {
                double m = Math.Sqrt(re[i] * re[i] + im[i] * im[i]) * norm;
                double v = 20.0 * Math.Log10(m + 1e-12);
                db[i] = (float)v;
            }
            return db;
        }

        static void FftRadix2(double[] re, double[] im)
        {
            int n = re.Length;
            int levels = 0;
            for (int t = n; t > 1; t >>= 1) levels++;
            // 位反转 / bit reversal
            for (int i = 1, j = 0; i < n; i++)
            {
                int bit = n >> 1;
                for (; (j & bit) != 0; bit >>= 1) j ^= bit;
                j ^= bit;
                if (i < j)
                {
                    double tr = re[i]; re[i] = re[j]; re[j] = tr;
                    double ti = im[i]; im[i] = im[j]; im[j] = ti;
                }
            }
            // 蝶形 / butterfly
            for (int len = 2; len <= n; len <<= 1)
            {
                double ang = -2 * Math.PI / len;
                double wr = Math.Cos(ang), wi = Math.Sin(ang);
                for (int i = 0; i < n; i += len)
                {
                    double curWr = 1, curWi = 0;
                    for (int k = 0; k < len / 2; k++)
                    {
                        int a = i + k, b = i + k + len / 2;
                        double tr = curWr * re[b] - curWi * im[b];
                        double ti = curWr * im[b] + curWi * re[b];
                        re[b] = re[a] - tr; im[b] = im[a] - ti;
                        re[a] = re[a] + tr; im[a] = im[a] + ti;
                        double nwr = curWr * wr - curWi * wi;
                        curWi = curWr * wi + curWi * wr;
                        curWr = nwr;
                    }
                }
            }
        }
    }
    // ================= 3D 频谱地形图控件 / 3D spectrogram terrain control =================
    // 仿 conwayjw97.github.io/3D-Spectrogram：频率×时间×幅值 的 3D 地形瀑布。
    // 等轴测投影（最新帧在最前下方，旧帧向后上方延伸缩小）+ 画家算法层叠 + 多配色。
    // Mirrors conwayjw97.github.io/3D-Spectrogram: a 3D terrain of freq x time x amplitude.
    // Isometric projection (newest frame at front/bottom, older frames recede up and shrink)
    // + painter's-algorithm layering + multiple colour schemes.
}
