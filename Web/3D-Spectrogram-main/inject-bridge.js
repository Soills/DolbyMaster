// inject-bridge.js — DolbyMaster 注入桥接 + ODAS 风格人头方向指示 + 双语界面
// DolbyMaster injection bridge + ODAS-style head & direction dial + bilingual UI
import { enableInjectMode } from './audio.js';
import { generateAllAxisLabels } from './ui.js';

// ===== 双语字典 / bilingual dictionary =====
var __L = {
  'Settings': { zh: '设置', en: 'Settings' },
  'Audio & Analysis': { zh: '音频与分析', en: 'Audio & Analysis' },
  'Audio Source:': { zh: '音频源:', en: 'Audio Source:' },
  'Audio Input': { zh: '音频输入', en: 'Audio Input' },
  'Browser Tab': { zh: '浏览器标签页', en: 'Browser Tab' },
  'Frequency Scale:': { zh: '频率刻度:', en: 'Frequency Scale:' },
  'Logarithmic': { zh: '对数', en: 'Logarithmic' },
  'Linear': { zh: '线性', en: 'Linear' },
  'Mesh Geometry': { zh: '网格几何', en: 'Mesh Geometry' },
  'Show Wireframe:': { zh: '显示线框:', en: 'Show Wireframe:' },
  'Display & Style': { zh: '显示与样式', en: 'Display & Style' },
  'Visual Mode:': { zh: '显示模式:', en: 'Visual Mode:' },
  'Blueprint Box': { zh: '蓝图框', en: 'Blueprint Box' },
  'No Ceiling': { zh: '无顶', en: 'No Ceiling' },
  'Mesh Only': { zh: '仅网格', en: 'Mesh Only' },
  'Colour Scheme:': { zh: '配色方案:', en: 'Colour Scheme:' },
  'Standard': { zh: '标准', en: 'Standard' },
  'Synthwave': { zh: '合成波', en: 'Synthwave' },
  'Glacier': { zh: '冰川', en: 'Glacier' },
  'Magma': { zh: '熔岩', en: 'Magma' },
  'Cyberpunk': { zh: '赛博朋克', en: 'Cyberpunk' },
  // 动态前缀 / dynamic prefixes
  'Min Frequency': { zh: '最低频率', en: 'Min Frequency' },
  'Max Frequency': { zh: '最高频率', en: 'Max Frequency' },
  'Time Window': { zh: '时间窗口', en: 'Time Window' },
  'Mesh Precision': { zh: '网格精度', en: 'Mesh Precision' },
  // 3D 场景内 sprite 标签 / in-scene sprite labels
  'Current Spectrogram': { zh: '当前频谱', en: 'Current Spectrogram' },
  'Max Spectrogram (Peak Hold)': { zh: '最大频谱（峰值保持）', en: 'Max Spectrogram (Peak Hold)' },
  'Max Amplitude': { zh: '最大幅值', en: 'Max Amplitude' },
  'Average Amplitude': { zh: '平均幅值', en: 'Average Amplitude' },
  'Now': { zh: '当前', en: 'Now' },
  'L': { zh: '左', en: 'L' },
  'R': { zh: '右', en: 'R' },
  '前': { zh: '前', en: 'Front' },
  '后': { zh: '后', en: 'Rear' },
  '立体声·仅左右': { zh: '立体声·仅左右', en: 'stereo: L/R only' }
};
var __lang = 'zh';
window.__lang = __lang;
window.__T = function (t) { var d = __L[t]; return d ? (d[__lang] || t) : t; };

// 静态元素：收集一次原文，applyLang 时从原文重新翻译（支持中英双向切换）
// static elements: capture original text once, re-translate from it on each applyLang (bidirectional)
var staticEls = [];
function collectStatic() {
  staticEls = [];
  var groups = document.querySelectorAll('.group-title');
  for (var i = 0; i < groups.length; i++) staticEls.push({ el: groups[i], orig: groups[i].textContent.trim() });
  var labels = document.querySelectorAll('label');
  for (var j = 0; j < labels.length; j++) staticEls.push({ el: labels[j], orig: labels[j].textContent.trim() });
  var opts = document.querySelectorAll('option');
  for (var k = 0; k < opts.length; k++) staticEls.push({ el: opts[k], orig: opts[k].textContent.trim() });
  var sb = document.getElementById('settingsBtn');
  if (sb) staticEls.push({ el: sb, orig: sb.textContent.trim() });
}
function applyLang(lang) {
  __lang = lang === 'en' ? 'en' : 'zh';
  window.__lang = __lang;
  for (var i = 0; i < staticEls.length; i++) {
    var o = staticEls[i];
    if (__L[o.orig]) {
      var target = __T(o.orig);
      if (o.el.textContent !== target) o.el.textContent = target;   // 相同值不赋值，避免触发 observer
    }
  }
  // 动态滑块标签 / dynamic slider labels
  var dynIds = ['minFreqLabel', 'sliderLabel', 'timeLabel', 'precisionLabel'];
  for (var d = 0; d < dynIds.length; d++) {
    var el = document.getElementById(dynIds[d]);
    if (el) translateDynamicPrefix(el);
  }
  drawDial(window.__lastPan || 0);   // 人头盘 L/R 标签 / head-dial L/R labels
  try { generateAllAxisLabels(); } catch (e) { }   // 重建 3D 场景标签 / rebuild in-scene labels
}
window.__applyLang = applyLang;

// 动态前缀（中英双向匹配，保留数值部分）/ dynamic prefixes (match zh|en, keep the value part)
var prefixPairs = [
  { en: 'Min Frequency', zh: '最低频率' },
  { en: 'Max Frequency', zh: '最高频率' },
  { en: 'Time Window', zh: '时间窗口' },
  { en: 'Mesh Precision', zh: '网格精度' }
];
function translateDynamicPrefix(el) {
  for (var i = 0; i < prefixPairs.length; i++) {
    var p = prefixPairs[i];
    var m = el.textContent.match(new RegExp('^\\s*(' + p.en + '|' + p.zh + ')\\s*:'));
    if (m) {
      var rest = el.textContent.slice(m[0].length);
      var newText = (__lang === 'zh' ? p.zh : p.en) + ':' + rest;
      if (el.textContent !== newText) el.textContent = newText;   // 相同值不赋值，避免触发 observer
      return;
    }
  }
}
window.addEventListener('message', function (e) {
  var msg = e.data;
  if (typeof msg === 'string') { try { msg = JSON.parse(msg); } catch (err) { return; } }
  if (msg && msg.type === 'lang' && (msg.value === 'zh' || msg.value === 'en')) applyLang(msg.value);
});

// 动态标签跟随语言（ui.js 更新后用 MutationObserver 翻译前缀，只处理 4 个已知 label，避免误触发死循环）
// keep dynamic labels translated; observer only watches the 4 known labels to avoid mutation loops
var dynEls = ['minFreqLabel', 'sliderLabel', 'timeLabel', 'precisionLabel'];
var obs = new MutationObserver(function (muts) {
  for (var i = 0; i < muts.length; i++) {
    var m = muts[i];
    if (m.type === 'characterData' && m.target && m.target.parentNode &&
        dynEls.indexOf(m.target.parentNode.id) >= 0) {
      translateDynamicPrefix(m.target.parentNode);
    } else if (m.type === 'childList') {
      for (var j = 0; j < m.addedNodes.length; j++) {
        var n = m.addedNodes[j];
        if (n.nodeType === 3 && n.parentNode && dynEls.indexOf(n.parentNode.id) >= 0) {
          translateDynamicPrefix(n.parentNode);
        }
      }
    }
  }
});
if (document.body) obs.observe(document.body, { childList: true, characterData: true, subtree: true });
collectStatic();   // 收集静态元素原文（DOM 已就绪）/ capture static elements' original text

// WebView2 宿主环境：自动启用注入模式（数据来自 C# WASAPI 环回捕获 + FFT）
if (window.chrome && window.chrome.webview) {
  enableInjectMode(48000);
  var startBtn = document.getElementById('startButton');
  if (startBtn) startBtn.style.display = 'none';        // 数据来自 C#，隐藏 Start
  var srcSel = document.getElementById('sourceSelect');
  if (srcSel) srcSel.style.display = 'none';            // 隐藏音频源选择
  // 假 analyser 就绪后重建频率轴标签 / rebuild axis labels once the fake analyser is ready
  setTimeout(function () { try { generateAllAxisLabels(); } catch (e) { } }, 400);
}

// ===== 人头 + 方向指示盘（ODAS 风格声像定位）=====
// head + direction dial (ODAS-style pan/DOA), canvas overlay top-right
var dial = document.createElement('canvas');
dial.id = 'headDial';
dial.width = 140;
dial.height = 140;
dial.style.cssText =
  'position:absolute;top:16px;right:16px;z-index:30;' +
  'background:rgba(0,0,0,0.55);border:1px solid rgba(120,140,160,0.6);border-radius:70px;' +
  'pointer-events:none;';
document.body.appendChild(dial);

// 人头 + 方向盘（ODAS 风格方位指示）
// head + direction dial: angle 0=前(front) +右(right) ±180=后(rear);
// multi=true 时用环绕声道算真方位（可指背后）；false 时只有 L/R → 指针限 ±90° 前弧，标注“仅左右”
function drawDial(angle, multi) {
  var ctx = dial.getContext('2d');
  var cx = 70, cy = 70, R = 58;
  ctx.clearRect(0, 0, 140, 140);
  // 外环
  ctx.strokeStyle = 'rgba(150,170,190,0.8)';
  ctx.lineWidth = 2;
  ctx.beginPath(); ctx.arc(cx, cy, R, 0, Math.PI * 2); ctx.stroke();
  // 刻度：多声道整圈（每 15°）；立体声只画前弧 ±90°
  ctx.strokeStyle = 'rgba(170,180,210,0.6)';
  ctx.lineWidth = 1;
  var from = multi ? -180 : -90, to = multi ? 180 : 90;
  for (var deg = from; deg <= to; deg += 15) {
    var rad = deg * Math.PI / 180;
    ctx.beginPath();
    ctx.moveTo(cx + Math.sin(rad) * (R - 6), cy - Math.cos(rad) * (R - 6));
    ctx.lineTo(cx + Math.sin(rad) * (R - 12), cy - Math.cos(rad) * (R - 12));
    ctx.stroke();
  }
  // 标签 L / 前 / R / 后（双语）
  ctx.fillStyle = 'rgba(190,200,220,0.9)';
  ctx.font = '10px Arial';
  ctx.textAlign = 'center';
  ctx.fillText(__T('L'), cx - R - 12, cy + 4);
  ctx.fillText(__T('R'), cx + R + 12, cy + 4);
  ctx.fillText(__T('前'), cx, cy - R - 10);
  if (multi) ctx.fillText(__T('后'), cx, cy + R + 16);
  // 简笔人头（朝上/朝前）
  ctx.fillStyle = '#e8c49a';
  ctx.beginPath(); ctx.arc(cx, cy, 12, 0, Math.PI * 2); ctx.fill();
  ctx.strokeStyle = '#5a4632';
  ctx.lineWidth = 1;
  ctx.stroke();
  // 耳朵
  ctx.fillStyle = '#e8c49a';
  ctx.beginPath(); ctx.ellipse(cx - 17, cy - 2, 3, 7, 0, 0, Math.PI * 2); ctx.fill();
  ctx.beginPath(); ctx.ellipse(cx + 17, cy - 2, 3, 7, 0, 0, Math.PI * 2); ctx.fill();
  // 方向指针（亮青，长度随能量脉冲）：角度 0=前(上)，正=右
  // needle: angle 0=front(up), positive=right
  var rad = (angle || 0) * Math.PI / 180;
  var energy = window.__lastEnergy || 0;
  var len = (R - 8) * (0.55 + 0.45 * energy);
  var nx = cx + Math.sin(rad) * len;
  var ny = cy - Math.cos(rad) * len;
  ctx.strokeStyle = '#59e7ff';
  ctx.lineWidth = 3;
  ctx.beginPath(); ctx.moveTo(cx, cy); ctx.lineTo(nx, ny); ctx.stroke();
  // 箭头（小夹角，指向尖端）
  var a1 = rad + 0.09, a2 = rad - 0.09;
  ctx.fillStyle = '#59e7ff';
  ctx.beginPath();
  ctx.moveTo(nx, ny);
  ctx.lineTo(nx + Math.sin(a1) * 9, ny - Math.cos(a1) * 9);
  ctx.lineTo(nx + Math.sin(a2) * 9, ny - Math.cos(a2) * 9);
  ctx.closePath(); ctx.fill();
  // 能量光晕（有声时头部外圈发亮）/ energy halo (head glows when sound plays)
  if (energy > 0.25) {
    ctx.strokeStyle = 'rgba(89,231,255,' + Math.min(0.85, energy).toFixed(2) + ')';
    ctx.lineWidth = 2;
    ctx.beginPath(); ctx.arc(cx, cy, 14 + 7 * energy, 0, Math.PI * 2); ctx.stroke();
  }
  // 立体声提示：前后在信号里不存在，诚实标注 / stereo caption: front/back not in the signal
  if (!multi) {
    ctx.fillStyle = 'rgba(210,210,220,0.75)';
    ctx.font = '8px Arial';
    ctx.textAlign = 'center';
    ctx.fillText(__T('立体声·仅左右', 'stereo: L/R only'), cx, cy + 36);
  }
}

window.__onPan = drawDial;
window.__lastPan = 0;
drawDial(0);
