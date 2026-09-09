export const audioState = {
  context: null,
  analyser: null,
  dataArray: null,
  isRecording: false,
  minFrequency: 0,
  targetFrequency: 10000,
  timeWindow: 2.0,
  sourceType: 'mic',    
  activeStream: null,    
  showWireframe: true,
  showTopLines: true,           
  showBlueprintLines: true,      
  axisLinesOnly: false,          
  disableAllLinesLabels: false,
  colorScheme: 0,
  frequencyScale: 'logarithmic',
  injectMode: false,
  injectedFrame: null            // C# 注入的频谱帧 (Uint8Array 0-255) / spectrum frame injected by C#
};

// ===== 注入模式（WebView2：C# 推送频谱代替 Web Audio API）=====
// Injection mode (WebView2: C# pushes spectrum instead of Web Audio API)
export function enableInjectMode(sampleRate) {
  audioState.injectMode = true;
  audioState.sourceType = 'inject';
  const rate = sampleRate || 48000;
  if (!audioState.context || audioState.context.sampleRate !== rate) {
    audioState.context = {
      sampleRate: rate,
      resume: function () {},
      close: function () {}
    };
  }
  // 假 analyser：与 Web Audio AnalyserNode 相同接口，数据来自 injectedFrame
  // Fake analyser: same interface as Web Audio AnalyserNode, data from injectedFrame
  audioState.analyser = {
    fftSize: 2048,
    frequencyBinCount: 1024,
    minDecibels: -100,
    maxDecibels: -30,
    getByteFrequencyData: function (arr) {
      const f = audioState.injectedFrame;
      if (!f) { for (let i = 0; i < arr.length; i++) arr[i] = 0; return; }
      if (arr.length === f.length) { arr.set(f); return; }
      for (let i = 0; i < arr.length; i++) {
        arr[i] = i < f.length ? f[i] : 0;
      }
    }
  };
  audioState.dataArray = new Uint8Array(audioState.analyser.frequencyBinCount);
  audioState.isRecording = true;
  return audioState;
}

export function setInjectedFrame(data) {
  if (!audioState.injectedFrame || audioState.injectedFrame.length !== data.length) {
    audioState.injectedFrame = new Uint8Array(data.length);
  }
  audioState.injectedFrame.set(data);
}

// 接收 WebView2 宿主消息（C# → JS）：{type:'spectrum',data:[...0-255]} 或 {type:'pan',value}
// Receive host messages (C# -> JS)
window.__msgCount = 0;   // 探针：收到消息计数 / probe: received message counter
if (window.chrome && window.chrome.webview) {
  window.chrome.webview.addEventListener('message', function (e) {
    var msg = e.data;
    if (typeof msg === 'string') { try { msg = JSON.parse(msg); } catch (err) { return; } }
    if (!msg || typeof msg !== 'object') return;
    if (msg.type === 'spectrum' && Array.isArray(msg.data)) {
      setInjectedFrame(msg.data);
      window.__msgCount++;
      // 帧能量（0..1）驱动人头盘脉冲 / frame energy (0..1) drives head-dial pulse
      var e = 0;
      for (var i = 0; i < msg.data.length; i++) e += msg.data[i];
      window.__lastEnergy = e / msg.data.length / 255;
    } else if (msg.type === 'pan') {
      window.__lastPan = msg.angle || 0;
      if (window.__onPan) window.__onPan(msg.angle || 0, !!msg.multi);
    } else if (msg.type === 'stop') {
      audioState.isRecording = false;
      if (audioState.injectedFrame) audioState.injectedFrame.fill(0);
    } else if (msg.type === 'start') {
      if (!audioState.injectMode) enableInjectMode(48000);
      audioState.isRecording = true;
    } else if (msg.type === 'lang' && (msg.value === 'zh' || msg.value === 'en')) {
      if (window.__applyLang) window.__applyLang(msg.value);
    }
  });
}

export async function startAudio(onSuccess) {
  if (!audioState.context) {
    audioState.context = new (window.AudioContext || window.webkitAudioContext)();
    audioState.analyser = audioState.context.createAnalyser();
    
    audioState.analyser.fftSize = 2048; 
    audioState.analyser.minDecibels = -100;
    audioState.analyser.maxDecibels = -30;

    const bufferLength = audioState.analyser.frequencyBinCount; 
    audioState.dataArray = new Uint8Array(bufferLength);
  } else {
    audioState.context.resume();
  }

  try {
    let stream;
    if (audioState.sourceType === 'tab') {
      stream = await navigator.mediaDevices.getDisplayMedia({
        video: true,
        audio: true
      });

      stream.getVideoTracks().forEach(track => track.stop());

      if (stream.getAudioTracks().length === 0) {
        stream.getTracks().forEach(track => track.stop());

        const isFirefox = navigator.userAgent.toLowerCase().includes('firefox');
        
        if (isFirefox) {
          throw new Error(
            'Firefox does not support capturing browser tab or system audio. ' +
            'Please run this visualiser in a Chromium-based browser (such as Chrome or Edge) to share tab audio, ' +
            'or switch your Audio Source back to "Microphone".'
          );
        } else {
          throw new Error(
            'No audio selected! Ensure the "Share tab audio" checkbox is checked. ' +
            '(Note: You must share a specific browser tab, as choosing "Entire Screen" or "Window" does not support audio capture.)'
          );
        }
      }
    } else {
      stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    }

    audioState.activeStream = stream;
    const source = audioState.context.createMediaStreamSource(stream);
    source.connect(audioState.analyser);
    audioState.isRecording = true;
    
    if (onSuccess) onSuccess();
  } catch (err) {
    console.error('Failed to acquire audio input stream:', err);
    stopAudio();
    alert(err.message || 'Could not access audio stream source.');
  }
}

export function stopAudio() {
  if (audioState.activeStream) {
    audioState.activeStream.getTracks().forEach(track => track.stop());
    audioState.activeStream = null;
  }
  if (audioState.context) {
    audioState.context.close();
    audioState.context = null;
    audioState.analyser = null;
    audioState.dataArray = null;
    audioState.isRecording = false;
  }
}
