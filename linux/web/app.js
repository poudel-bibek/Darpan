/* Darpan — browser client. Speaks PROTOCOL.md; no dependencies. */
'use strict';
(() => {
  const $ = (id) => document.getElementById(id);
  const UA = navigator.userAgent;
  const IS_MAC = /Macintosh|Mac OS X|iPhone|iPad/.test(UA);
  const IS_SAFARI = /^((?!chrome|chromium|crios|android|edg).)*safari/i.test(UA);
  const RAW_MOVE = 'onpointerrawupdate' in window;   // earliest pointer events (Chrome)
  const TE = new TextEncoder();
  const CHUNK = 256 * 1024;
  const UPLOAD_WINDOW = 512 * 1024;
  if (IS_MAC) document.documentElement.classList.add('mac');

  // ------------------------------------------------------------ settings (per viewer)
  const DEFAULTS = { quality: '0', fps: '60', scale: 'fit', cmd: 'ctrl', scroll: 1, invert: false, stats: false, pillX: 0.5, audio: true };
  const readJSON = (k) => { try { return JSON.parse(localStorage.getItem(k) || 'null'); } catch { return null; } };
  const writeJSON = (k, v) => { try { localStorage.setItem(k, JSON.stringify(v)); } catch { /* private mode */ } };
  const forget = (k) => { try { localStorage.removeItem(k); } catch { /* ignore */ } };
  const settings = Object.assign({}, DEFAULTS, readJSON('darpan.settings') || {});
  const saveSettings = () => writeJSON('darpan.settings', settings);
  const KEY_SLOT = 'darpan.key.' + location.host;

  // ------------------------------------------------------------ helpers
  const now = () => performance.now();
  const b64dec = (s) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
  const b64enc = (u8) => {
    let s = '';
    for (let i = 0; i < u8.length; i += 0x8000) s += String.fromCharCode.apply(null, u8.subarray(i, i + 0x8000));
    return btoa(s);
  };
  const hex2 = (x) => x.toString(16).padStart(2, '0');

  function toast(text, opts = {}) {
    const el = document.createElement('div');
    el.className = 'toast' + (opts.click ? ' click' : '') + (opts.error ? ' err' : '');
    el.textContent = text;
    if (opts.click) el.addEventListener('click', () => { opts.click(); el.remove(); });
    $('toasts').appendChild(el);
    const ttl = opts.ttl ?? (opts.click ? 9000 : 3500);
    if (ttl) setTimeout(() => el.remove(), ttl);
    return el;
  }

  // ------------------------------------------------------------ auth crypto (PROTOCOL §2)
  async function deriveKey(password, saltB64, iter) {
    const km = await crypto.subtle.importKey('raw', TE.encode(password.normalize('NFC')), 'PBKDF2', false, ['deriveBits']);
    const bits = await crypto.subtle.deriveBits({ name: 'PBKDF2', hash: 'SHA-256', salt: b64dec(saltB64), iterations: iter }, km, 256);
    return new Uint8Array(bits);
  }
  async function makeProof(key, nonceB64) {
    const k = await crypto.subtle.importKey('raw', key, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
    const label = TE.encode('darpan-auth-v1');
    const nonce = b64dec(nonceB64);
    const msg = new Uint8Array(label.length + nonce.length);
    msg.set(label);
    msg.set(nonce, label.length);
    return b64enc(new Uint8Array(await crypto.subtle.sign('HMAC', k, msg)));
  }

  // ------------------------------------------------------------ H.264: Annex-B → AVCC
  function splitNals(b) {
    const out = [];
    const n = b.length;
    let i = 0, start = -1;
    while (i + 2 < n) {
      const c = b[i + 2];
      if (c > 1) { i += 3; continue; }                    // cannot be inside a start code
      if (c === 1 && b[i] === 0 && b[i + 1] === 0) {
        if (start >= 0) {
          let end = i;
          while (end > start && b[end - 1] === 0) end--;  // strip the 4-byte start code's leading 0
          if (end > start) out.push(b.subarray(start, end));
        }
        i += 3;
        start = i;
      } else i++;
    }
    if (start >= 0 && start < n) out.push(b.subarray(start, n));
    return out;
  }
  function avcC(sps, pps) {
    const high = sps[1] === 100 || sps[1] === 110 || sps[1] === 122 || sps[1] === 144;
    const b = new Uint8Array(11 + sps.length + pps.length + (high ? 4 : 0));
    let o = 0;
    b[o++] = 1; b[o++] = sps[1]; b[o++] = sps[2]; b[o++] = sps[3]; b[o++] = 0xff; b[o++] = 0xe1;
    b[o++] = sps.length >> 8; b[o++] = sps.length & 255; b.set(sps, o); o += sps.length;
    b[o++] = 1; b[o++] = pps.length >> 8; b[o++] = pps.length & 255; b.set(pps, o); o += pps.length;
    if (high) { b[o++] = 0xfd; b[o++] = 0xf8; b[o++] = 0xf8; b[o++] = 0; }   // 4:2:0, 8-bit
    return b;
  }

  // ------------------------------------------------------------ state
  const canvas = $('screen');
  const stage = $('stage');
  const sink = $('sink');
  const ctx = canvas.getContext('2d', { alpha: false, desynchronized: true });
  const S = {
    info: null, ws: null, key: null, salt: null, iter: 0, password: null, remember: true,
    connected: false, want: false, retry: 0, sid: null, screen: null, enc: null,
    stream: null, decoder: null, cfgKey: null, needKey: true, pending: new Map(), decErrors: [],
    rtt: null, rttMin: Infinity, rttMinAt: 0, offset: null, latency: null, host: null,
    frames: 0, decodeMs: 0, fpsN: 0, bytesN: 0, fps: 0, mbps: 0,
    remoteClip: '', clipSeen: false, lastSentClip: null, modes: null, cursorId: null, cssScale: 1,
  };
  window.__darpan = S;   // live counters for automated tests

  function send(obj) {
    const ws = S.ws;
    if (ws && ws.readyState === 1) ws.send(JSON.stringify(obj));
  }

  // ------------------------------------------------------------ connection
  function connect() {
    const url = (location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + '/ws';
    const ws = new WebSocket(url);
    ws.binaryType = 'arraybuffer';
    S.ws = ws;
    S.want = true;
    ws.onmessage = (ev) => {
      if (typeof ev.data !== 'string') return onVideo(ev.data);
      let m;
      try { m = JSON.parse(ev.data); } catch { return; }
      const h = H[m.t];
      if (h) h(m);
    };
    ws.onclose = (ev) => { if (S.ws === ws) onClosed(ev); };
  }

  const H = {};
  H.hello = async (m) => {
    try {
      if (S.password != null) {
        setLoginMsg('Verifying…');
        S.key = await deriveKey(S.password, m.kdf.salt, m.kdf.iter);
        S.salt = m.kdf.salt; S.iter = m.kdf.iter;
      } else if (!S.key || S.salt !== m.kdf.salt || S.iter !== m.kdf.iter) {
        forget(KEY_SLOT);
        S.key = null; S.want = false;
        S.ws.close();
        showLogin('The password on the remote computer changed — enter it again.');
        return;
      }
      send({ t: 'auth', proof: await makeProof(S.key, m.nonce), client: clientName(), ver: m.ver });   // served by the host: same build
    } catch (e) {
      showLogin('Could not sign in: ' + e.message, true);
    }
  };
  H.ok = (m) => {
    S.connected = true; S.retry = 0; S.sid = m.sid; S.screen = m.screen; S.enc = m.enc; S.caps = m.caps || [];
    S.password = null; S.clipSeen = false;
    FS.token = null; fsWait = null;   // a new session: file requests need its token
    if (S.remember) writeJSON(KEY_SLOT, { salt: S.salt, iter: S.iter, key: b64enc(S.key) });
    else forget(KEY_SLOT);
    $('overlay').hidden = true;
    showViewer();
    startStream();
    ping();
    pump();                           // resume uploads queued before a reconnect
    startSound();
  };
  H.denied = (m) => {
    S.want = false;
    const r = m.reason;
    if (r === 'password') {
      if (S.password == null) { forget(KEY_SLOT); S.key = null; showLogin('Saved sign-in expired — enter the password.'); }
      else showLogin(m.retry ? `Wrong password. Locked for ${m.retry} s.` : 'Wrong password.', true);
    } else if (r === 'locked') showLogin(`Too many attempts. Try again in ${m.retry} s.`, true);
    else if (r === 'no_password') showLogin('No password is set on the remote computer. Run “darpan setup” there.', true);
    else if (r === 'busy') showLogin('Too many people are connected right now.', true);
    else showLogin('Access denied.', true);
  };
  // The close code decides what happens next (4003 kicked → stay out; 4004 restarting → reconnect).
  H.bye = (m) => { if (m.reason) toast(m.reason); };
  H.notice = (m) => toast(m.text, { error: m.level === 'error' });
  H.screen = () => { /* a new `stream` follows */ };
  H.stats = (m) => { S.host = m; };
  H.pong = (m) => {
    const t = now();
    const rtt = t - m.c;
    S.rtt = S.rtt == null ? rtt : S.rtt * 0.7 + rtt * 0.3;
    if (rtt <= S.rttMin || t - S.rttMinAt > 30000) {     // clock offset from the tightest sample
      S.rttMin = rtt; S.rttMinAt = t;
      S.offset = m.s - (m.c + rtt / 2) * 1000;
    }
  };
  function ping() { send({ t: 'ping', c: now() }); }

  // ------------------------------------------------------------ sound (PROTOCOL.md §12)
  // Its own WebSocket, so audio never waits behind a video frame; WebCodecs decodes the Opus, and an
  // AudioWorklet (audio-worklet.js) plays it through a small jitter buffer.
  const SND = S.sound = { ws: null, dec: null, ctx: null, node: null, packets: 0, depth: 0, target: 0 };
  async function soundContext() {
    if (!SND.ctx) {
      const ctx = new AudioContext({ latencyHint: 'interactive', sampleRate: 48000 });
      await ctx.audioWorklet.addModule('audio-worklet.js');
      SND.node = new AudioWorkletNode(ctx, 'darpan-sound', { numberOfInputs: 0, outputChannelCount: [2] });
      SND.node.port.onmessage = (e) => { SND.depth = e.data.depth; SND.target = e.data.target; };
      SND.node.connect(ctx.destination);
      SND.ctx = ctx;
    }
    if (SND.ctx.state === 'suspended') SND.ctx.resume().catch(() => {});   // needs a click or key first
  }
  // Ask for sound only once it can actually play (a page that hasn't had a click yet can't), so the
  // host doesn't capture for nobody; the first click or key then starts it.
  async function startSound() {
    if (!(S.connected && settings.audio && S.caps.includes('audio') && 'AudioDecoder' in window)) return;
    try { await soundContext(); await SND.ctx.resume(); } catch { /* not allowed yet */ }
    if (SND.ctx && SND.ctx.state === 'running') { SND.pending = false; if (S.connected) send({ t: 'audio', on: true }); }
    else SND.pending = true;
  }
  function stopSound() {
    clearTimeout(SND.idle);
    SND.slot = null;
    if (SND.ctx && SND.ctx.state === 'running') SND.ctx.suspend().catch(() => {});
    if (SND.ws) { SND.ws.close(); SND.ws = null; }
    if (SND.dec && SND.dec.state !== 'closed') SND.dec.close();
    SND.dec = null;
  }
  H.audio = async (m) => {
    if (m.error || !settings.audio || !S.connected) return;
    try { await soundContext(); } catch { return; }
    stopSound();
    const dec = SND.dec = new AudioDecoder({
      output: (a) => {
        const l = new Float32Array(a.numberOfFrames), r = new Float32Array(a.numberOfFrames);
        a.copyTo(l, { planeIndex: 0, format: 'f32-planar' });
        a.copyTo(r, { planeIndex: a.numberOfChannels > 1 ? 1 : 0, format: 'f32-planar' });
        a.close();
        SND.node.port.postMessage({ l, r }, [l.buffer, r.buffer]);
      },
      error: () => {},
    });
    dec.configure({ codec: 'opus', sampleRate: 48000, numberOfChannels: 2 });
    const ws = SND.ws = new WebSocket((location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + '/audio');
    ws.binaryType = 'arraybuffer';
    ws.onopen = () => ws.send(JSON.stringify({ t: 'auth', token: m.token }));
    ws.onmessage = (e) => {
      if (typeof e.data === 'string' || dec.state !== 'configured') return;   // {"t":"ok"}
      const d = new DataView(e.data);
      if (d.getUint8(0) !== 3) return;
      const slot = d.getUint32(2);
      if (d.getUint8(1) & 1) {                          // after silence: keep its length, or re-prime
        const gap = SND.slot == null ? 0 : (slot - SND.slot - 1) >>> 0;
        SND.node.port.postMessage({ reset: true, gap: gap <= 100 ? gap * 480 : 0 });
      }
      SND.slot = slot;
      SND.packets++;
      if (SND.ctx.state === 'suspended') SND.ctx.resume().catch(() => {});
      clearTimeout(SND.idle);                           // nothing for 2 s: let the audio device sleep
      SND.idle = setTimeout(() => SND.ctx.suspend().catch(() => {}), 2000);
      dec.decode(new EncodedAudioChunk({ type: 'key', timestamp: d.getUint32(2) * 10000, data: new Uint8Array(e.data, 14) }));
    };
    ws.onclose = () => { if (SND.ws === ws) SND.ws = null; };
  };
  for (const ev of ['pointerdown', 'keydown']) {
    addEventListener(ev, () => {
      if (SND.pending) startSound();
      else if (SND.ctx && SND.ctx.state === 'suspended' && SND.ws) SND.ctx.resume().catch(() => {});
    }, true);
  }

  function onClosed(ev) {
    const was = S.connected;
    S.connected = false; S.ws = null;
    resetDecoder(true);
    stopSound();
    if (up) {                         // the host discarded the partial file: send it again later
      up.el.remove();
      queue.unshift(up.f);
      up = null;
      toast('Upload interrupted — it will restart after reconnecting');
    }
    if (ev.code === 4001 || ev.code === 4005) return;          // `denied` already explained it
    if (ev.code === 4003) { S.want = false; toast('Disconnected by the remote computer'); showLogin(''); return; }
    if (!S.want) { showLogin(''); return; }
    if (!S.key) { showLogin('Could not reach the remote computer.', true); return; }
    const delay = Math.min(10000, 400 * 2 ** S.retry++);
    if (was || !$('viewer').hidden) {
      $('overlayMsg').textContent = ev.code === 4004 ? 'Remote computer restarting…' : 'Reconnecting…';
      $('overlay').hidden = false;
    } else setLoginMsg('Connecting…');
    setTimeout(() => { if (S.want) connect(); }, delay);
  }

  function clientName() {
    const b = /Edg\//.test(UA) ? 'Edge' : /Chrome\//.test(UA) ? 'Chrome' : /Firefox\//.test(UA) ? 'Firefox' : IS_SAFARI ? 'Safari' : 'Browser';
    const os = /iPhone|iPad/.test(UA) ? 'iOS' : IS_MAC ? 'macOS' : /Windows/.test(UA) ? 'Windows' : /Android/.test(UA) ? 'Android' : /Linux/.test(UA) ? 'Linux' : '';
    return b + (os ? ' on ' + os : '');
  }

  // ------------------------------------------------------------ video
  function startStream() {
    if (S.connected && !document.hidden) send({ t: 'start', codec: 'h264', fps: +settings.fps, bitrate: +settings.quality });
  }
  H.stream = (m) => {
    resetDecoder(false);
    S.stream = m;
    if (canvas.width !== m.w || canvas.height !== m.h) { canvas.width = m.w; canvas.height = m.h; }
    layout();
  };
  function resetDecoder(close) {
    S.pending.clear();
    S.needKey = true;
    if (close && S.decoder) {
      try { if (S.decoder.state !== 'closed') S.decoder.close(); } catch { /* ignore */ }
      S.decoder = null; S.cfgKey = null;
    }
  }
  function ack(id, n) { send({ t: 'ack', id, n }); }

  function onVideo(buf) {
    const u8 = new Uint8Array(buf);
    if (u8.length < 16 || u8[0] !== 1) return;
    const dv = new DataView(buf);
    const flags = u8[1], id = dv.getUint16(2), seq = dv.getUint32(4), ts = Number(dv.getBigUint64(8));
    const st = S.stream;
    if (!st || id !== st.id) return;                  // frame from a superseded stream
    S.bytesN += u8.length;
    const key = flags & 1;
    if (S.needKey && !key) { ack(id, seq); return; }
    const nals = splitNals(u8.subarray(16));
    let sps = null, pps = null, size = 0;
    for (const n of nals) {
      const t = n[0] & 31;
      if (t === 7) sps = n; else if (t === 8) pps = n; else if (t !== 9) size += 4 + n.length;
    }
    if (key) {
      if (!sps || !pps) { ack(id, seq); return; }
      const k = b64enc(sps) + '.' + b64enc(pps);
      if (k !== S.cfgKey || !S.decoder || S.decoder.state !== 'configured') {
        if (!configure(sps, pps, k)) { ack(id, seq); return; }
      }
    }
    const data = new Uint8Array(size);
    let o = 0;
    for (const n of nals) {
      const t = n[0] & 31;
      if (t === 7 || t === 8 || t === 9) continue;
      const l = n.length;
      data[o] = l >>> 24; data[o + 1] = (l >>> 16) & 255; data[o + 2] = (l >>> 8) & 255; data[o + 3] = l & 255;
      data.set(n, o + 4);
      o += 4 + l;
    }
    S.pending.set(seq, { t: now(), ts, id, fresh: !(flags & 2) });   // refresh frames re-encode old pixels
    try {
      S.decoder.decode(new EncodedVideoChunk({ type: key ? 'key' : 'delta', timestamp: seq, data }));
      S.needKey = false;
    } catch (e) { decoderFailed(e); }
  }

  function configure(sps, pps, k) {
    try {
      if (!S.decoder || S.decoder.state === 'closed') S.decoder = new VideoDecoder({ output: onFrame, error: decoderFailed });
      S.decoder.configure({
        codec: 'avc1.' + hex2(sps[1]) + hex2(sps[2]) + hex2(sps[3]),
        description: avcC(sps, pps), optimizeForLatency: true, hardwareAcceleration: 'no-preference',
      });
      S.cfgKey = k;
      return true;
    } catch (e) { decoderFailed(e); return false; }
  }

  function onFrame(frame) {
    const seq = frame.timestamp;
    ctx.drawImage(frame, 0, 0, canvas.width, canvas.height);   // draw the moment it exists
    frame.close();
    const p = S.pending.get(seq);
    if (p) {
      S.pending.delete(seq);
      ack(p.id, seq);
      const t = now();
      S.decodeMs = S.decodeMs * 0.9 + (t - p.t) * 0.1;
      if (S.offset != null && p.fresh) S.latency = (t * 1000 + S.offset - p.ts) / 1000;
    }
    S.frames++; S.fpsN++;
  }

  function decoderFailed(e) {
    console.warn('video decoder:', e);
    for (const [seq, p] of S.pending) ack(p.id, seq);
    resetDecoder(true);
    const t = now();
    S.decErrors = S.decErrors.filter((x) => t - x < 10000);
    S.decErrors.push(t);
    if (S.decErrors.length > 6) {
      toast('This browser failed to decode the video. Try Chrome or Safari.', { error: true, ttl: 8000 });
      return;
    }
    send({ t: 'kf' });
  }

  // ------------------------------------------------------------ layout
  let rect = null;
  function layout() {
    rect = null;
    const st = S.stream;
    if (!st) return;
    const dpr = window.devicePixelRatio || 1;
    let cw, ch;
    if (settings.scale === 'actual') {
      cw = st.w / dpr; ch = st.h / dpr;              // one remote pixel = one device pixel
      stage.classList.add('actual');
    } else {
      const s = Math.min(stage.clientWidth / st.w, stage.clientHeight / st.h);
      cw = Math.max(1, Math.floor(st.w * s)); ch = Math.max(1, Math.floor(st.h * s));
      stage.classList.remove('actual');
    }
    canvas.style.width = cw + 'px';
    canvas.style.height = ch + 'px';
    S.cssScale = cw / st.w;
    applyCursor();
  }
  new ResizeObserver(layout).observe(stage);
  stage.addEventListener('scroll', () => { rect = null; }, { passive: true });
  matchMedia('(resolution: 1dppx)').addEventListener?.('change', layout);

  function toRemote(e) {
    const st = S.stream;
    if (!st) return null;
    if (!rect) rect = canvas.getBoundingClientRect();
    if (!rect.width) return null;
    let x = Math.floor((e.clientX - rect.left) * st.w / rect.width);
    let y = Math.floor((e.clientY - rect.top) * st.h / rect.height);
    x = x < 0 ? 0 : x >= st.w ? st.w - 1 : x;
    y = y < 0 ? 0 : y >= st.h ? st.h - 1 : y;
    return [x, y];
  }

  // ------------------------------------------------------------ cursor (drawn locally → zero lag)
  const cursors = new Map();     // id → { w, h, hx, hy, img }   (the host sends each image once)
  const cursorCss = new Map();   // id@scale → CSS value
  H.cur = (m) => {
    if (m.png && !cursors.has(m.id)) {
      const c = { w: m.w, h: m.h, hx: m.hx, hy: m.hy, img: new Image() };
      c.img.onload = () => { if (S.cursorId === m.id) applyCursor(); };
      c.img.src = 'data:image/png;base64,' + m.png;
      cursors.set(m.id, c);
    }
    S.cursorId = m.id;
    applyCursor();
  };
  function cursorUrl(c, w, h) {
    const cv = document.createElement('canvas');
    cv.width = w; cv.height = h;
    const g = cv.getContext('2d');
    g.imageSmoothingQuality = 'high';
    g.drawImage(c.img, 0, 0, w, h);
    return cv.toDataURL('image/png');
  }
  function applyCursor() {
    const id = S.cursorId;
    if (id == null) return;
    if (id === 0) { canvas.style.cursor = 'none'; return; }
    const c = cursors.get(id);
    if (!c || !c.img.complete || !c.img.naturalWidth) { canvas.style.cursor = 'default'; return; }
    // Scaled like the video (PROTOCOL §4), but never under 12 CSS px tall so it stays usable.
    const s = Math.max(S.cssScale || 1, 12 / c.h);
    const dpr = window.devicePixelRatio || 1;
    const key = id + '@' + s.toFixed(3) + '@' + dpr;
    let css = cursorCss.get(key);
    if (!css) {
      const w = Math.max(1, Math.round(c.w * s)), h = Math.max(1, Math.round(c.h * s));
      const hx = Math.min(w - 1, Math.round(c.hx * s)), hy = Math.min(h - 1, Math.round(c.hy * s));
      const plain = `url("${cursorUrl(c, w, h)}") ${hx} ${hy}, default`;
      css = plain;
      if (dpr > 1) {          // sharp on Retina where image-set() cursors are supported
        const hi = `image-set(url("${cursorUrl(c, Math.round(w * dpr), Math.round(h * dpr))}") ${dpr}x) ${hx} ${hy}, default`;
        canvas.style.cursor = '';
        canvas.style.cursor = hi;
        if (canvas.style.cursor) css = hi;
      }
      if (cursorCss.size > 256) cursorCss.clear();
      cursorCss.set(key, css);
    }
    canvas.style.cursor = css;
  }

  // ------------------------------------------------------------ mouse / touch
  let lastX = -1, lastY = -1;
  function move(e) {
    if (!S.connected) return;
    const p = toRemote(e);
    if (!p || (p[0] === lastX && p[1] === lastY)) return;
    lastX = p[0]; lastY = p[1];
    send({ t: 'mm', x: p[0], y: p[1] });
  }
  canvas.addEventListener(RAW_MOVE ? 'pointerrawupdate' : 'pointermove', (e) => { if (e.pointerType !== 'touch') move(e); });
  canvas.addEventListener('pointerdown', (e) => {
    closePanels();
    focusSink();
    if (e.pointerType === 'touch') return touchStart(e);
    e.preventDefault();
    canvas.setPointerCapture(e.pointerId);
    move(e);
    send({ t: 'mb', b: e.button, d: true });
  });
  canvas.addEventListener('pointerup', (e) => {
    if (e.pointerType === 'touch') return touchEnd(e);
    e.preventDefault();
    move(e);
    send({ t: 'mb', b: e.button, d: false });
  });
  canvas.addEventListener('pointercancel', (e) => { if (e.pointerType === 'touch') touches.delete(e.pointerId); });
  canvas.addEventListener('pointermove', (e) => { if (e.pointerType === 'touch') touchMove(e); });
  canvas.addEventListener('contextmenu', (e) => e.preventDefault());
  for (const ev of ['mouseup', 'mousedown', 'auxclick']) {     // stop back/forward buttons navigating away
    canvas.addEventListener(ev, (e) => { if (e.button > 0) e.preventDefault(); });
  }

  let wX = 0, wY = 0;
  canvas.addEventListener('wheel', (e) => {
    e.preventDefault();
    if (!S.connected) return;
    const unit = e.deltaMode === 1 ? 40 : e.deltaMode === 2 ? 360 : 2.4;   // → 1/120-notch units (≈50 px per notch)
    const k = unit * settings.scroll * (settings.invert ? -1 : 1);
    wY += e.deltaY * k; wX += e.deltaX * k;
    const dy = Math.trunc(wY), dx = Math.trunc(wX);
    if (dx || dy) { wY -= dy; wX -= dx; send({ t: 'wh', dx, dy }); }
  }, { passive: false });

  // touch: tap = click, drag = drag, long-press = right click, two fingers = scroll
  const touches = new Map();
  let touchTimer = 0, touchMode = null;
  function touchStart(e) {
    touches.set(e.pointerId, { x: e.clientX, y: e.clientY, t: now() });
    if (touches.size === 1) {
      touchMode = 'tap';
      move(e);
      clearTimeout(touchTimer);
      touchTimer = setTimeout(() => {
        if (touchMode === 'tap') { touchMode = 'done'; send({ t: 'mb', b: 2, d: true }); send({ t: 'mb', b: 2, d: false }); }
      }, 550);
    } else { touchMode = 'scroll'; clearTimeout(touchTimer); }
  }
  function touchMove(e) {
    const p = touches.get(e.pointerId);
    if (!p) return;
    const dx = e.clientX - p.x, dy = e.clientY - p.y;
    if (touchMode === 'scroll') {
      p.x = e.clientX; p.y = e.clientY;
      if (e.pointerId === touches.keys().next().value) send({ t: 'wh', dx: Math.round(-dx * 2.4), dy: Math.round(-dy * 2.4) });
      return;
    }
    if (touchMode === 'tap' && Math.hypot(dx, dy) > 8) { touchMode = 'drag'; clearTimeout(touchTimer); send({ t: 'mb', b: 0, d: true }); }
    if (touchMode === 'drag') move(e);
  }
  function touchEnd(e) {
    touches.delete(e.pointerId);
    clearTimeout(touchTimer);
    if (touchMode === 'tap') { send({ t: 'mb', b: 0, d: true }); send({ t: 'mb', b: 0, d: false }); }
    else if (touchMode === 'drag') send({ t: 'mb', b: 0, d: false });
    if (!touches.size) touchMode = null;
  }

  // ------------------------------------------------------------ keyboard
  const pressed = new Map();          // physical code → code sent to the host
  let metaDown = false;
  function sendKey(c, d, cmd) { send(cmd ? { t: 'key', c, d, cmd: true } : { t: 'key', c, d }); }
  // ⌘+letter while ⌘ acts as Ctrl: the host makes it Ctrl+Shift+letter in terminals (PROTOCOL.md §5)
  const viaCmd = (code) => IS_MAC && settings.cmd === 'ctrl' && metaDown && /^Key[A-Z]$/.test(code);
  function mapCode(code) {
    if (IS_MAC && settings.cmd === 'ctrl') {
      if (code === 'MetaLeft') return 'ControlLeft';
      if (code === 'MetaRight') return 'ControlRight';
    }
    return code;
  }
  const MODS = new Set(['ShiftLeft', 'ShiftRight', 'ControlLeft', 'ControlRight', 'AltLeft', 'AltRight', 'MetaLeft', 'MetaRight', 'CapsLock', 'Fn']);
  const paste = { waiting: false, mapped: null, timer: 0, early: false };

  sink.addEventListener('keydown', (e) => {
    if (!S.connected) return;
    if (e.isComposing || e.keyCode === 229) return;             // IME composing: wait for compositionend
    const code = e.code;
    if (!code || code === 'Unidentified') return;              // mobile keyboards: handled by beforeinput
    if (IS_MAC && code === 'CapsLock') { e.preventDefault(); sendKey('CapsLock', true); sendKey('CapsLock', false); return; }
    if (code === 'MetaLeft' || code === 'MetaRight') metaDown = true;
    const mapped = mapCode(code);
    const cmdish = e.ctrlKey || (IS_MAC && settings.cmd === 'ctrl' && e.metaKey);
    if (code === 'KeyV' && cmdish && !e.altKey && !e.repeat) {
      // Let the browser raise a `paste` event: its clipboard text reaches the host first,
      // then the key goes through, so the remote app pastes what's on *this* device.
      pressed.set(code, mapped);
      paste.waiting = true; paste.mapped = mapped; paste.early = false; paste.cmd = viaCmd(code);
      paste.timer = setTimeout(() => finishPaste(null), 150);
      return;
    }
    if (IS_SAFARI && cmdish && (code === 'KeyC' || code === 'KeyX')) armSafariCopy();
    e.preventDefault();
    if (IS_MAC && metaDown && !MODS.has(code)) {
      // macOS never delivers key-up for keys pressed while ⌘ is held: send a full tap.
      sendKey(mapped, true, viaCmd(code)); sendKey(mapped, false);
      return;
    }
    pressed.set(code, mapped);
    sendKey(mapped, true);
  });
  sink.addEventListener('keyup', (e) => {
    if (!S.connected) return;
    const code = e.code;
    if (!code || code === 'Unidentified') return;
    e.preventDefault();
    if (IS_MAC && code === 'CapsLock') { sendKey('CapsLock', true); sendKey('CapsLock', false); return; }
    if (paste.waiting && code === 'KeyV') { paste.early = true; return; }
    const mapped = pressed.get(code);
    pressed.delete(code);
    if (mapped) sendKey(mapped, false);
    if (code === 'MetaLeft' || code === 'MetaRight') {
      metaDown = false;
      for (const [c, m] of pressed) if (!MODS.has(c)) { sendKey(m, false); pressed.delete(c); }
    }
  });
  sink.addEventListener('paste', (e) => {
    e.preventDefault();
    if (paste.waiting) finishPaste(e.clipboardData ? e.clipboardData.getData('text/plain') : null);
  });
  function finishPaste(text) {
    if (!paste.waiting) return;
    clearTimeout(paste.timer);
    paste.waiting = false;
    // Compare with what the host holds now (it may have changed since we last sent anything).
    if (text && text !== S.remoteClip) { S.lastSentClip = S.remoteClip = text; send({ t: 'clip', text }); }
    sendKey(paste.mapped, true, paste.cmd);
    // ⌘ already let go (its key-up released V before this down went out): release V now too
    if (paste.early || (IS_MAC && metaDown) || !pressed.has('KeyV')) { sendKey(paste.mapped, false); pressed.delete('KeyV'); }
  }
  sink.addEventListener('compositionend', (e) => { if (e.data) send({ t: 'txt', s: e.data }); sink.value = ''; });
  sink.addEventListener('beforeinput', (e) => {       // soft keyboards that don't emit key codes
    if (!S.connected || e.isComposing) return;
    if (e.inputType === 'insertText' && e.data) send({ t: 'txt', s: e.data });
    else if (e.inputType === 'deleteContentBackward') { sendKey('Backspace', true); sendKey('Backspace', false); }
    else if (e.inputType === 'insertLineBreak' || e.inputType === 'insertParagraph') { sendKey('Enter', true); sendKey('Enter', false); }
    e.preventDefault();
  });

  function releaseAll() {
    // Unconditional: also frees a mouse button held by a drag that left the window.
    if (S.connected) send({ t: 'rel' });
    pressed.clear();
    metaDown = false;
  }
  window.addEventListener('blur', releaseAll);
  function focusSink() { if (document.activeElement !== sink) sink.focus({ preventScroll: true }); }

  function combo(spec) {
    const keys = spec.split('+');
    for (const k of keys) sendKey(k, true);
    for (const k of keys.reverse()) sendKey(k, false);
    focusSink();
  }

  // ------------------------------------------------------------ clipboard
  let copyResolve = null;
  function armSafariCopy() {
    // Safari only writes the clipboard inside a user gesture: start the write now with a
    // promise that resolves when the host reports what the remote app copied.
    if (!navigator.clipboard || !window.ClipboardItem) return;
    const p = new Promise((resolve, reject) => {
      copyResolve = resolve;
      setTimeout(() => { if (copyResolve === resolve) { copyResolve = null; reject(new Error('no copy')); } }, 2000);
    });
    navigator.clipboard.write([new ClipboardItem({ 'text/plain': p.then((t) => new Blob([t], { type: 'text/plain' })) })]).catch(() => {});
  }
  H.clip = (m) => {
    S.remoteClip = m.text;
    if (!S.clipSeen) { S.clipSeen = true; return; }     // don't clobber this device's clipboard on connect
    if (copyResolve) { const r = copyResolve; copyResolve = null; r(m.text); return; }
    writeLocal(m.text);
  };
  function writeLocal(text) {
    const fail = () => toast('Remote clipboard updated — click to copy', { click: () => navigator.clipboard?.writeText(text) });
    if (!navigator.clipboard || !document.hasFocus()) return fail();
    navigator.clipboard.writeText(text).catch(fail);
  }
  window.addEventListener('focus', async () => {   // Chrome with permission: keep clipboards in sync silently
    if (!S.connected || !navigator.permissions || !navigator.clipboard?.readText) return;
    try {
      const p = await navigator.permissions.query({ name: 'clipboard-read' });
      if (p.state !== 'granted') return;
      const text = await navigator.clipboard.readText();
      if (text && text !== S.lastSentClip && text !== S.remoteClip) { S.lastSentClip = S.remoteClip = text; send({ t: 'clip', text }); }
    } catch { /* not supported */ }
  });

  // ------------------------------------------------------------ uploads over /ws (hosts without §7.1)
  const queue = [];
  let up = null, nextId = 1;
  function enqueue(files) { for (const f of files) queue.push(f); pump(); }
  function pump() {
    if (up || !queue.length || !S.connected) return;
    const f = queue.shift();
    up = { id: nextId++, f, sent: 0, acked: 0, busy: false, el: xferUI('up', f.name, true) };
    send({ t: 'fput', id: up.id, name: f.name, size: f.size });
  }
  async function sendChunks() {
    const u = up;
    if (!u || u.busy) return;
    u.busy = true;
    try {
      while (up === u && u.sent < u.f.size && u.sent - u.acked < UPLOAD_WINDOW && S.ws) {
        const end = Math.min(u.sent + CHUNK, u.f.size);
        const data = new Uint8Array(await u.f.slice(u.sent, end).arrayBuffer());
        const msg = new Uint8Array(5 + data.length);
        msg[0] = 2;
        new DataView(msg.buffer).setUint32(1, u.id);
        msg.set(data, 5);
        S.ws.send(msg);
        u.sent = end;
      }
    } finally { u.busy = false; }
  }
  H.fok = (m) => { if (up && up.id === m.id) sendChunks(); };
  H.fack = (m) => {
    if (!up || up.id !== m.id) return;
    up.acked = m.n;
    progress(up.el, m.n / Math.max(1, up.f.size));
    sendChunks();
  };
  H.fdone = (m) => {
    if (up && up.id === m.id) { finished(up.el, 'done', 'on the desktop'); up = null; }
    pump();
  };
  H.ferr = (m) => {
    if (up && up.id === m.id) { finished(up.el, 'fail', m.e); up = null; }
    pump();
  };

  // ------------------------------------------------------------ files (PROTOCOL.md §7.1)
  // The remote computer's files in a window of their own: browse, Send and Receive. File data
  // travels over separate HTTP requests, never over /ws, so video and input never wait for it.
  const ICON = {
    dir: '<svg viewBox="0 0 24 24"><path d="M3 7.5V18a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2V9.5a2 2 0 0 0-2-2h-7L10 5H5a2 2 0 0 0-2 2.5z"/></svg>',
    file: '<svg viewBox="0 0 24 24"><path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><path d="M14 3v5h5"/></svg>',
    other: '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="7"/></svg>',
    up: '<svg viewBox="0 0 24 24"><path d="M12 19V5M6 11l6-6 6 6"/></svg>',
    down: '<svg viewBox="0 0 24 24"><path d="M12 5v14M6 13l6 6 6-6"/></svg>',
    x: '<svg viewBox="0 0 24 24"><path d="M6 6l12 12M18 6L6 18"/></svg>',
  };
  const FS_MSG = { notfound: 'Not found', denied: 'Permission denied', exists: 'Already exists', notdir: 'Not a folder',
    isdir: 'It’s a folder', notfile: 'Not a regular file', nospace: 'The disk is full', busy: 'Busy', token: 'The session ended',
    invalid: 'Not a valid path', failed: 'Failed', network: 'Connection lost', cancelled: 'Cancelled', range: 'Failed' };
  class FsError extends Error { constructor(code) { super(FS_MSG[code] || code); this.code = code; } }
  const FS = { token: null, home: '', inbox: '', ready: null, path: '', entries: [], view: [], more: false, sel: new Set(), anchor: -1,
    sort: { key: 'name', dir: 1 }, xfers: [], running: 0 };
  S.fs = FS;                                        // for automated tests
  const filesWin = $('files');
  const hasFs = () => (S.caps || []).includes('fs');
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const joinPath = (d, n) => (d.endsWith('/') ? d : d + '/') + n;
  const parentOf = (p) => { const q = p.replace(/\/+$/, ''); const i = q.lastIndexOf('/'); return i <= 0 ? '/' : q.slice(0, i); };
  const baseName = (p) => p.replace(/\/+$/, '').split('/').pop() || '/';
  const fmtSize = (n) => n < 1000 ? n + ' B' : n < 1e6 ? (n / 1e3).toFixed(1) + ' KB' : n < 1e9 ? (n / 1e6).toFixed(1) + ' MB' : (n / 1e9).toFixed(2) + ' GB';
  const fmtDate = (t) => new Date(t * 1000).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' });

  let fsWait = null;
  function fsSession() {                            // the session's file token, asked for once
    if (FS.token) return Promise.resolve();
    if (!fsWait) {
      fsWait = new Promise((resolve, reject) => {
        FS.ready = resolve;
        send({ t: 'fs' });
        setTimeout(() => { fsWait = null; reject(new FsError('network')); }, 5000);
      });
    }
    return fsWait;
  }
  H.fs = (m) => { FS.token = m.token; FS.home = m.home; FS.inbox = m.inbox; if (FS.ready) FS.ready(); };

  async function fsFetch(method, path, params, retry = true) {
    await fsSession();
    const r = await fetch(path + '?' + new URLSearchParams(params), { method, cache: 'no-store', headers: { Authorization: 'Bearer ' + FS.token } });
    const j = await r.json().catch(() => ({}));
    if (r.ok) return j;
    if (j.e === 'token' && retry) { FS.token = null; fsWait = null; return fsFetch(method, path, params, false); }   // reconnected meanwhile
    throw new FsError(j.e || 'failed');
  }
  function fsPut(file, path, exists, onProgress) {    // XHR, not fetch: it reports upload progress
    const xhr = new XMLHttpRequest();
    const done = new Promise((resolve, reject) => {
      xhr.open('PUT', '/fs/file?' + new URLSearchParams({ path, exists }));
      xhr.setRequestHeader('Authorization', 'Bearer ' + FS.token);
      xhr.upload.onprogress = (e) => onProgress(e.loaded / Math.max(1, e.total || file.size));
      xhr.onload = () => {
        let j = {};
        try { j = JSON.parse(xhr.responseText); } catch { /* not JSON */ }
        if (xhr.status === 201) resolve(j.path); else reject(new FsError(j.e || 'failed'));
      };
      xhr.onerror = () => reject(new FsError('network'));
      xhr.onabort = () => reject(new FsError('cancelled'));
      xhr.send(file);
    });
    return { done, abort: () => xhr.abort() };
  }
  async function fsDownload(path) {                 // a single-use link: the browser saves it like any download
    const { ticket } = await fsFetch('POST', '/fs/ticket', { path });
    const a = document.createElement('a');
    a.href = '/fs/file?' + new URLSearchParams({ ticket });
    a.download = baseName(path);
    document.body.append(a);
    a.click();
    a.remove();
  }

  // a transfer's line: in the window's list, or as a toast for files dropped on the desktop
  function xferUI(dir, name, inToast) {
    const el = document.createElement('div');
    el.className = inToast ? 'toast xfer-toast' : 'xfer';
    el.innerHTML = (dir === 'down' ? ICON.down : ICON.up) + '<span class="name"></span><span class="pbar"><i></i></span><span class="pct"></span>' +
      (inToast ? '' : '<button class="x" title="Cancel">' + ICON.x + '</button>');
    el.querySelector('.name').textContent = name;
    (inToast ? $('toasts') : $('fsXfers')).append(el);
    return el;
  }
  function progress(el, f) {
    el.querySelector('.pbar i').style.width = Math.round(f * 100) + '%';
    el.querySelector('.pct').textContent = Math.floor(f * 100) + '%';
  }
  function finished(el, state, note) {
    el.classList.add(state);
    if (state === 'done') progress(el, 1);
    el.querySelector('.pct').textContent = state === 'done' ? '✓' : state === 'fail' ? '!' : '';
    if (note) { el.title = note; el.querySelector('.name').textContent += ' — ' + note; }
    // a failed line in the window stays until dismissed with its ×; everything else goes by itself
    if (state !== 'fail' || !el.querySelector('.x')) setTimeout(() => el.remove(), state === 'fail' ? 6000 : 3500);
  }

  function queueXfer(x) {                           // x: {dir, name, file, exists, toast}
    x.state = 'queued';
    x.el = xferUI('up', x.name, x.toast);
    x.el.querySelector('.x')?.addEventListener('click', () => {
      if (x.state === 'running') x.req.abort();
      else { x.state = 'cancelled'; x.el.remove(); }
    });
    FS.xfers.push(x);
    pumpXfers();
  }
  function pumpXfers() {
    while (FS.running < 2) {                        // the host takes 4 requests at once: leave room for browsing
      const x = FS.xfers.find((y) => y.state === 'queued');
      if (!x) break;
      x.state = 'running';
      FS.running++;
      (async () => {
        try {
          await fsSession();
          x.req = fsPut(x.file, joinPath(x.dir, x.name), x.exists, (f) => progress(x.el, f));
          const final = await x.req.done;
          x.state = 'done';
          finished(x.el, 'done', x.toast ? 'on the desktop' : (baseName(final) !== x.name ? 'saved as ' + baseName(final) : ''));
          if (x.dir === FS.path && !filesWin.hidden) refreshSoon();
        } catch (e) {
          if (e.code === 'busy') { x.state = 'wait'; setTimeout(() => { x.state = 'queued'; pumpXfers(); }, 800); return; }
          x.state = e.code === 'cancelled' ? 'cancelled' : 'fail';
          if (x.state === 'cancelled') x.el.remove(); else finished(x.el, 'fail', e.message);
        } finally {
          FS.running--;
          pumpXfers();
        }
      })();
    }
    FS.xfers = FS.xfers.filter((y) => y.state === 'queued' || y.state === 'running' || y.state === 'wait');
  }
  let refreshTimer = 0;
  function refreshSoon() { clearTimeout(refreshTimer); refreshTimer = setTimeout(() => fsOpen(FS.path, true), 300); }

  // ---- the window
  async function openFiles() {
    filesWin.hidden = false;
    bar.querySelector('[data-act=files]').classList.add('on');
    $('filesTitle').textContent = 'Files on ' + ((S.info && S.info.host) || location.hostname);
    filesWin.focus({ preventScroll: true });
    try { await fsSession(); } catch (e) { return showFsMessage(e.message); }
    fsOpen(FS.path || FS.home);
  }
  function closeFiles() {
    filesWin.hidden = true;
    bar.querySelector('[data-act=files]').classList.remove('on');
    focusSink();
  }
  function showFsMessage(text) {
    const p = document.createElement('div');
    p.className = 'files-empty';
    p.textContent = text;
    $('fsList').replaceChildren(p);
  }
  async function fsOpen(path, keepSel) {
    try {
      const r = await fsFetch('GET', '/fs/list', { path });
      const same = r.path === FS.path;
      FS.path = r.path; FS.entries = r.entries; FS.more = r.more;
      if (!(keepSel && same)) { FS.sel.clear(); FS.anchor = -1; }
      $('fsPath').value = FS.path;
      renderFiles();
    } catch (e) {
      $('fsPath').value = path;
      showFsMessage(e.message);
    }
  }
  function renderFiles() {
    const { key, dir } = FS.sort;
    const byName = (a, b) => a.name.localeCompare(b.name, undefined, { numeric: true, sensitivity: 'base' });
    FS.view = FS.entries.filter((e) => $('fsHidden').checked || !e.name.startsWith('.'))
      .sort((a, b) => ((b.type === 'd') - (a.type === 'd')) || (key === 'name' ? byName(a, b) : (a[key] - b[key]) || byName(a, b)) * dir);
    const rows = FS.view.map((e, i) => {
      const row = document.createElement('div');
      row.className = 'file' + (e.type === 'd' ? ' dir' : '');
      row.setAttribute('role', 'option');
      row.dataset.i = i;
      const name = document.createElement('div');
      name.className = 'name';
      name.innerHTML = e.type === 'd' ? ICON.dir : e.type === 'f' ? ICON.file : ICON.other;
      const label = document.createElement('span');
      label.textContent = e.name;
      name.append(label);
      const size = document.createElement('div');
      size.className = 'size';
      size.textContent = e.type === 'f' ? fmtSize(e.size) : '';
      const when = document.createElement('div');
      when.className = 'when';
      when.textContent = e.mtime ? fmtDate(e.mtime) : '';
      row.append(name, size, when);
      return row;
    });
    $('fsList').replaceChildren(...rows);
    if (!rows.length) showFsMessage('This folder is empty');
    else if (FS.more) { const p = document.createElement('div'); p.className = 'files-empty'; p.textContent = 'Showing the first 20,000 items'; $('fsList').append(p); }
    for (const b of document.querySelectorAll('.files-cols button')) b.className = b.dataset.sort === key ? (dir > 0 ? 'asc' : 'desc') : '';
    updateSel();
  }
  function updateSel() {
    for (const row of $('fsList').querySelectorAll('.file')) {
      const on = FS.sel.has(FS.view[+row.dataset.i].name);
      row.classList.toggle('sel', on);
      row.setAttribute('aria-selected', on);
    }
    const n = FS.sel.size;
    $('fsSel').textContent = n ? `${n} selected` : `${FS.view.length} item${FS.view.length === 1 ? '' : 's'}`;
    $('fsReceive').disabled = !n;
  }
  $('fsList').addEventListener('click', (e) => {
    const row = e.target.closest('.file');
    if (!row) { FS.sel.clear(); return updateSel(); }
    const i = +row.dataset.i, name = FS.view[i].name;
    if (e.shiftKey && FS.anchor >= 0) {
      if (!(e.metaKey || e.ctrlKey)) FS.sel.clear();
      for (let k = Math.min(FS.anchor, i); k <= Math.max(FS.anchor, i); k++) FS.sel.add(FS.view[k].name);
    } else if (e.metaKey || e.ctrlKey) {
      if (FS.sel.has(name)) FS.sel.delete(name); else FS.sel.add(name);
      FS.anchor = i;
    } else {
      FS.sel.clear();
      FS.sel.add(name);
      FS.anchor = i;
    }
    updateSel();
  });
  $('fsList').addEventListener('dblclick', (e) => {
    const row = e.target.closest('.file');
    if (!row) return;
    const ent = FS.view[+row.dataset.i];
    if (ent.type === 'd') fsOpen(joinPath(FS.path, ent.name));
    else if (ent.type === 'f') fsReceive([ent]);
  });
  for (const b of document.querySelectorAll('.files-cols button')) {
    b.addEventListener('click', () => {
      FS.sort = { key: b.dataset.sort, dir: FS.sort.key === b.dataset.sort ? -FS.sort.dir : 1 };
      renderFiles();
    });
  }
  filesWin.addEventListener('click', (e) => {
    const a = e.target.closest('[data-fs]')?.dataset.fs;
    if (a === 'close') closeFiles();
    else if (a === 'up') fsOpen(parentOf(FS.path));
    else if (a === 'home') fsOpen(FS.home);
    else if (a === 'refresh') fsOpen(FS.path, true);
    else if (a === 'mkdir') newFolderRow();
  });
  filesWin.addEventListener('keydown', (e) => { if (e.key === 'Escape' && $('fsAsk').hidden) { e.preventDefault(); closeFiles(); } });
  $('fsPath').addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); fsOpen($('fsPath').value.trim() || '/'); } });
  $('fsHidden').addEventListener('change', renderFiles);

  function newFolderRow() {                         // a row with a name field; Enter creates the folder
    const row = document.createElement('div');
    row.className = 'file dir';
    const name = document.createElement('div');
    name.className = 'name';
    name.innerHTML = ICON.dir;
    const input = document.createElement('input');
    input.className = 'path';
    input.value = 'New folder';
    name.append(input);
    row.append(name);
    $('fsList').prepend(row);
    input.select();
    let done = false;
    const finish = async (create) => {
      if (done) return;
      done = true;
      const n = input.value.trim();
      if (create && n && !n.includes('/')) {
        try { await fsFetch('POST', '/fs/mkdir', { path: joinPath(FS.path, n) }); } catch (e) { toast(`Couldn’t create “${n}”: ${e.message}`, { error: true }); }
      }
      await fsOpen(FS.path, true);
      if (create) { FS.sel = new Set([n]); updateSel(); }
    };
    input.addEventListener('keydown', (e) => {
      e.stopPropagation();
      if (e.key === 'Enter') finish(true);
      else if (e.key === 'Escape') finish(false);
    });
    input.addEventListener('blur', () => finish(false));
  }

  // ---- Receive: the selection, a single-use link per file; a folder arrives as its files
  async function fsReceive(ents = FS.view.filter((e) => FS.sel.has(e.name))) {
    for (const e of ents) {
      const p = joinPath(FS.path, e.name), el = xferUI('down', e.name, false);
      el.querySelector('.x').remove();
      if (e.type !== 'f' && e.type !== 'd') { finished(el, 'fail', FS_MSG.notfile); continue; }
      try {
        let files = [p];
        if (e.type === 'd') files = (await fsFetch('GET', '/fs/list', { path: p, deep: 1 })).entries.filter((x) => x.type === 'f').map((x) => joinPath(p, x.name));
        for (const [i, f] of files.entries()) {
          if (i) await sleep(150);                  // browsers take a burst of downloads better when paced
          await fsDownload(f);
          progress(el, (i + 1) / files.length);
        }
        finished(el, 'done', e.type === 'd' ? `${files.length} file${files.length === 1 ? '' : 's'} to your downloads` : 'to your downloads');
      } catch (err) { finished(el, 'fail', err.message); }
    }
  }
  $('fsReceive').addEventListener('click', () => fsReceive());

  // ---- Send: files or a folder into the folder shown, asking before anything is replaced
  function ask(name) {
    return new Promise((resolve) => {
      $('fsAskText').textContent = `“${name}” already exists here.`;
      $('fsAskAll').checked = false;
      $('fsAsk').hidden = false;
      for (const b of $('fsAsk').querySelectorAll('[data-ask]')) {
        b.onclick = () => { $('fsAsk').hidden = true; resolve({ how: b.dataset.ask, all: $('fsAskAll').checked }); };
      }
    });
  }
  async function fsMkdirOk(p) { try { await fsFetch('POST', '/fs/mkdir', { path: p }); } catch (e) { if (e.code !== 'exists') throw e; } }
  async function freeFolder(dir, name) {            // "name (1)", "name (2)"…: the first that can be created
    for (let n = 1; ; n++) {
      try { await fsFetch('POST', '/fs/mkdir', { path: joinPath(dir, `${name} (${n})`) }); return `${name} (${n})`; } catch (e) { if (e.code !== 'exists') throw e; }
    }
  }
  async function fsSend(items, dir) {               // items: [{file, rel: "name" or "folder/…/name"}]
    let names;
    try { names = new Set((dir === FS.path ? FS.entries : (await fsFetch('GET', '/fs/list', { path: dir })).entries).map((e) => e.name)); }
    catch (e) { return toast(`Can’t send to ${dir}: ${e.message}`, { error: true }); }
    const groups = new Map();                       // top-level name → a file, or a folder's files
    for (const it of items) {
      const top = it.rel.split('/')[0];
      if (!groups.has(top)) groups.set(top, []);
      groups.get(top).push(it);
    }
    let always = null;
    for (const [top, its] of groups) {
      const folder = its[0].rel.includes('/');
      let how = 'fail';
      if (names.has(top)) {
        const a = always || await ask(top);
        if (a.all) always = a;
        if (a.how === 'skip') continue;
        how = a.how;
      }
      if (!folder) { queueXfer({ dir, name: top, file: its[0].file, exists: how }); continue; }
      try {
        const root = joinPath(dir, how === 'rename' ? await freeFolder(dir, top) : top);
        await fsMkdirOk(root);
        const dirs = new Set();
        for (const it of its) { const parts = it.rel.split('/').slice(1, -1); for (let k = 1; k <= parts.length; k++) dirs.add(parts.slice(0, k).join('/')); }
        for (const d of [...dirs].sort((a, b) => a.split('/').length - b.split('/').length)) await fsMkdirOk(joinPath(root, d));
        for (const it of its) {
          const rest = it.rel.split('/').slice(1);
          queueXfer({ dir: rest.length > 1 ? joinPath(root, rest.slice(0, -1).join('/')) : root, name: rest[rest.length - 1], file: it.file,
            exists: how === 'replace' ? 'replace' : 'fail' });
        }
      } catch (e) { toast(`Couldn’t send “${top}”: ${e.message}`, { error: true }); }
    }
    if (dir === FS.path) refreshSoon();
  }
  $('fsSend').addEventListener('click', () => $('fsFiles').click());
  $('fsSendFolder').addEventListener('click', () => $('fsFolder').click());
  $('fsFiles').addEventListener('change', (e) => {
    const files = [...e.target.files];
    e.target.value = '';
    if (!hasFs()) enqueue(files);
    else fsSend(files.map((file) => ({ file, rel: file.name })), FS.path);
  });
  $('fsFolder').addEventListener('change', (e) => {
    const files = [...e.target.files];
    e.target.value = '';
    fsSend(files.map((file) => ({ file, rel: file.webkitRelativePath || file.name })), FS.path);
  });

  // ---- moving the window by its title
  let winDrag = null;
  $('filesHead').addEventListener('pointerdown', (e) => {
    if (e.target.closest('button')) return;
    const r = filesWin.getBoundingClientRect();
    winDrag = { dx: e.clientX - r.left, dy: e.clientY - r.top };
    $('filesHead').setPointerCapture(e.pointerId);
  });
  $('filesHead').addEventListener('pointermove', (e) => {
    if (!winDrag) return;
    const x = Math.min(innerWidth - 60, Math.max(60 - filesWin.offsetWidth, e.clientX - winDrag.dx));
    const y = Math.min(innerHeight - 40, Math.max(0, e.clientY - winDrag.dy));
    Object.assign(filesWin.style, { left: x + 'px', top: y + 'px', transform: 'none' });
  });
  $('filesHead').addEventListener('pointerup', () => { winDrag = null; });

  // ---- dropping files: into the window's folder when dropped on it, else onto the desktop
  let dragDepth = 0;
  const overFiles = (e) => !filesWin.hidden && !!e.target.closest?.('#files');
  window.addEventListener('dragenter', (e) => {
    if (S.connected && e.dataTransfer?.types.includes('Files')) { dragDepth++; $('drop').hidden = false; e.preventDefault(); }
  });
  window.addEventListener('dragover', (e) => {
    if (!S.connected) return;
    e.preventDefault();
    const inside = overFiles(e);
    filesWin.classList.toggle('target', inside);
    $('drop').classList.toggle('over-files', inside);
  });
  window.addEventListener('dragleave', () => {
    if (--dragDepth <= 0) { dragDepth = 0; $('drop').hidden = true; filesWin.classList.remove('target'); }
  });
  window.addEventListener('drop', (e) => {
    e.preventDefault();
    dragDepth = 0;
    $('drop').hidden = true;
    filesWin.classList.remove('target');
    const dt = e.dataTransfer;
    if (!S.connected || !dt?.files.length) return;
    const folders = [...dt.items].filter((i) => i.webkitGetAsEntry?.()?.isDirectory).length;
    const files = [...dt.files].filter((_, i) => !dt.items[i]?.webkitGetAsEntry?.()?.isDirectory);
    if (folders) toast('To send a folder, use Send folder… in Files.');
    if (!files.length) return;
    if (!hasFs()) return enqueue(files);
    if (overFiles(e)) return fsSend(files.map((file) => ({ file, rel: file.name })), FS.path);
    fsSession().then(() => { for (const file of files) queueXfer({ dir: FS.inbox, name: file.name, file, exists: 'rename', toast: true }); },
      () => enqueue(files));
  });

  // ------------------------------------------------------------ resolution
  H.modes = (m) => { S.modes = m; renderModes(); };
  function bestForWindow(modes) {
    const dpr = window.devicePixelRatio || 1;
    const vw = innerWidth * dpr, vh = innerHeight * dpr, ar = vw / vh;
    let best = null, score = -1;
    for (const [w, h] of modes) {
      if (w > vw || h > vh) continue;
      const s = w * h * (1 - Math.min(0.9, Math.abs(w / h - ar)));
      if (s > score) { score = s; best = [w, h]; }
    }
    return best;
  }
  function renderModes() {
    const box = $('modes');
    box.textContent = '';
    const m = S.modes;
    if (!m || !m.modes || !m.modes.length) { box.textContent = 'Not available'; return; }
    const cur = m.current ? m.current.join('×') : '';
    const nat = m.native ? m.native.join('×') : '';
    const item = (label, sub, on, msg) => {
      const b = document.createElement('button');
      b.className = on ? 'on' : '';
      const a = document.createElement('span'); a.textContent = label;
      const c = document.createElement('span'); c.className = 'sub'; c.textContent = sub;
      b.append(a, c);
      b.addEventListener('click', () => { send(msg); toast('Changing resolution…', { ttl: 1500 }); });
      box.appendChild(b);
    };
    item('Native', nat, cur === nat, { t: 'res', native: true });
    const best = bestForWindow(m.modes);
    if (best && best.join('×') !== nat) item('Fit this window', best.join('×'), false, { t: 'res', w: best[0], h: best[1] });
    for (const [w, h] of m.modes) {
      const k = w + '×' + h;
      if (k !== nat) item(k, '', cur === k, { t: 'res', w, h });
    }
  }

  // ------------------------------------------------------------ toolbar
  const bar = $('bar'), pill = $('pill');
  let collapseTimer = 0;
  function expand() { clearTimeout(collapseTimer); bar.classList.remove('collapsed'); }
  function collapseSoon(ms = 700) {
    clearTimeout(collapseTimer);
    collapseTimer = setTimeout(() => { if (!openPanel) bar.classList.add('collapsed'); }, ms);
  }
  let openPanel = null;
  function closePanels() {
    for (const p of document.querySelectorAll('.panel')) p.hidden = true;
    for (const b of document.querySelectorAll('[data-panel]')) b.classList.remove('on');
    openPanel = null;
    bar.classList.add('collapsed');
  }
  function togglePanel(name, btn) {
    const was = openPanel === name;
    for (const p of document.querySelectorAll('.panel')) p.hidden = true;
    for (const b of document.querySelectorAll('[data-panel]')) b.classList.remove('on');
    openPanel = was ? null : name;
    if (!was) { $('panel-' + name).hidden = false; btn.classList.add('on'); if (name === 'display') { send({ t: 'modes' }); renderModes(); } }
  }
  bar.addEventListener('pointerenter', expand);
  bar.addEventListener('pointerleave', () => collapseSoon(openPanel ? 1800 : 600));
  // keep keyboard focus on the remote while clicking toolbar buttons
  bar.addEventListener('pointerdown', (e) => { if (e.target.closest('button')) e.preventDefault(); });

  // the pill can be dragged along the top edge so it never covers something important
  let drag = null;
  function placeBar() { bar.style.left = Math.round(settings.pillX * innerWidth) + 'px'; }
  pill.addEventListener('pointerdown', (e) => { drag = { x: e.clientX, moved: false }; pill.setPointerCapture(e.pointerId); });
  pill.addEventListener('pointermove', (e) => {
    if (!drag) return;
    if (Math.abs(e.clientX - drag.x) > 4) drag.moved = true;
    if (drag.moved) { settings.pillX = Math.min(0.95, Math.max(0.05, e.clientX / innerWidth)); placeBar(); }
  });
  pill.addEventListener('pointerup', () => {
    if (drag && drag.moved) saveSettings(); else expand();
    drag = null;
  });
  window.addEventListener('resize', placeBar);
  placeBar();

  for (const b of document.querySelectorAll('[data-panel]')) b.addEventListener('click', () => togglePanel(b.dataset.panel, b));
  for (const b of document.querySelectorAll('[data-combo]')) b.addEventListener('click', () => combo(b.dataset.combo));
  bar.querySelector('[data-act=fullscreen]').addEventListener('click', toggleFullscreen);
  bar.querySelector('[data-act=files]').addEventListener('click', () => {
    if (!hasFs()) $('fsFiles').click();                // a host without §7.1: straight to the desktop over /ws
    else if (filesWin.hidden) openFiles(); else closeFiles();
  });
  bar.querySelector('[data-act=stats]').addEventListener('click', () => { settings.stats = !settings.stats; saveSettings(); applySettings(); });
  bar.querySelector('[data-act=audio]').addEventListener('click', () => {
    settings.audio = !settings.audio; saveSettings(); applySettings();
    if (settings.audio) { soundContext().catch(() => {}); startSound(); } else { send({ t: 'audio', on: false }); stopSound(); }
  });
  bar.querySelector('[data-act=disconnect]').addEventListener('click', disconnect);

  for (const seg of document.querySelectorAll('.seg[data-setting]')) {
    const key = seg.dataset.setting;
    for (const b of seg.querySelectorAll('button')) {
      b.addEventListener('click', () => {
        settings[key] = b.dataset.v;
        saveSettings();
        applySettings();
        if (key === 'quality') send({ t: 'cfg', bitrate: +settings.quality });
        if (key === 'fps') send({ t: 'cfg', fps: +settings.fps });
      });
    }
  }
  const scrollEl = $('scrollSpeed'), invertEl = $('invertScroll');
  scrollEl.addEventListener('input', () => { settings.scroll = +scrollEl.value; saveSettings(); });
  invertEl.addEventListener('change', () => { settings.invert = invertEl.checked; saveSettings(); });

  function applySettings() {
    for (const seg of document.querySelectorAll('.seg[data-setting]')) {
      for (const b of seg.querySelectorAll('button')) b.classList.toggle('on', String(settings[seg.dataset.setting]) === b.dataset.v);
    }
    scrollEl.value = settings.scroll;
    invertEl.checked = !!settings.invert;
    $('stats').hidden = !settings.stats;
    bar.querySelector('[data-act=stats]').classList.toggle('on', !!settings.stats);
    bar.querySelector('[data-act=audio]').classList.toggle('on', !!settings.audio);
    layout();
  }

  async function toggleFullscreen() {
    const el = document.documentElement;
    if (!document.fullscreenElement && !document.webkitFullscreenElement) {
      try { await (el.requestFullscreen ? el.requestFullscreen({ navigationUI: 'hide' }) : el.webkitRequestFullscreen()); } catch { return; }
      // In full screen Chrome can hand us ⌘W, Esc, etc. instead of acting on them itself.
      navigator.keyboard?.lock?.().catch(() => {});
    } else {
      navigator.keyboard?.unlock?.();
      (document.exitFullscreen || document.webkitExitFullscreen).call(document);
    }
    focusSink();
  }

  // ------------------------------------------------------------ stats + quality dot
  setInterval(() => {
    S.fps = S.fpsN * 2; S.mbps = S.bytesN * 16 / 1e6;
    S.fpsN = 0; S.bytesN = 0;
    const lat = S.latency, rtt = S.rtt;
    const dot = $('dot');
    const q = lat != null && S.connected ? lat : rtt;
    dot.className = 'dot' + (q == null || !S.connected ? '' : q < 45 ? ' good' : q < 110 ? ' fair' : ' poor');
    if (!settings.stats) return;
    const st = S.stream, h = S.host;
    const lines = [];
    if (st) lines.push(`${st.w}×${st.h}  ${st.enc}  ${S.fps} fps`);
    lines.push(`video ${S.mbps.toFixed(2)} Mbps` + (h ? `  target ${(h.br / 1000).toFixed(1)} Mbps` : ''));
    lines.push(`rtt ${rtt == null ? '–' : rtt.toFixed(1)} ms  e2e ${lat == null ? '–' : '~' + lat.toFixed(0)} ms`);
    lines.push(`decode ${S.decodeMs.toFixed(1)} ms` + (h ? `  host ${h.cap_ms}+${h.enc_ms} ms` : ''));
    if (SND.ws) lines.push(`sound buffer ${(SND.depth / 48).toFixed(0)} ms (target ${(SND.target / 48).toFixed(0)})`);
    $('stats').textContent = lines.join('\n');
  }, 500);
  setInterval(() => { if (S.connected) ping(); }, 2000);

  // ------------------------------------------------------------ page lifecycle
  document.addEventListener('visibilitychange', () => {
    if (!S.connected) return;
    if (document.hidden) { releaseAll(); send({ t: 'stop' }); }   // host encoder idles → ~0 cost
    else startStream();
  });
  window.addEventListener('beforeunload', (e) => { if (S.connected) { e.preventDefault(); e.returnValue = ''; } });

  function showViewer() {
    $('login').hidden = true;
    $('viewer').hidden = false;
    applySettings();
    focusSink();
  }
  function setLoginMsg(t, err) { const el = $('loginMsg'); el.textContent = t || ''; el.classList.toggle('err', !!err); }
  function showLogin(msg, err) {
    $('overlay').hidden = true;
    $('viewer').hidden = true;
    $('login').hidden = false;
    $('connectBtn').disabled = false;
    setLoginMsg(msg, err);
    const saved = readJSON(KEY_SLOT);
    $('password').placeholder = saved ? 'Saved on this device' : '';
    $('password').focus();
  }
  function disconnect() {
    S.want = false;
    releaseAll();
    if (S.ws) S.ws.close(1000);
    showLogin('Disconnected.');
  }

  // ------------------------------------------------------------ start
  $('loginForm').addEventListener('submit', (e) => {
    e.preventDefault();
    const pw = $('password').value;
    S.remember = $('remember').checked;
    const saved = readJSON(KEY_SLOT);
    if (!pw && saved) { S.key = b64dec(saved.key); S.salt = saved.salt; S.iter = saved.iter; S.password = null; }
    else if (!pw) { setLoginMsg('Enter the password.', true); return; }
    else { S.password = pw; }
    $('password').value = '';
    $('connectBtn').disabled = true;
    setLoginMsg('Connecting…');
    connect();
  });

  (async function init() {
    applySettings();
    try {
      S.info = await (await fetch('/api/info', { cache: 'no-store' })).json();
      $('hostName').textContent = S.info.host;
      document.title = 'Darpan — ' + S.info.host;
    } catch { $('hostName').textContent = location.host; }
    if (!window.isSecureContext || !('VideoDecoder' in window)) {
      $('insecure').hidden = false;
      const url = S.info && S.info.url;
      if (url) $('secureLink').href = url; else $('secureLink').removeAttribute('href');
      if (!('VideoDecoder' in window) && window.isSecureContext) $('insecure').textContent = 'This browser can’t decode the video stream. Use a current Chrome, Safari, Edge or Firefox.';
      $('connectBtn').disabled = true;
      return;
    }
    const saved = readJSON(KEY_SLOT);
    if (saved && saved.key) {
      S.key = b64dec(saved.key); S.salt = saved.salt; S.iter = saved.iter; S.password = null;
      $('connectBtn').disabled = true;
      setLoginMsg('Connecting…');
      connect();
    } else showLogin('');
  })();
})();
