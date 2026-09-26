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
  const DEFAULTS = { quality: '0', fps: '60', scale: 'fit', cmd: 'ctrl', scroll: 1, invert: false, stats: false, pillX: 0.5 };
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
    S.connected = true; S.retry = 0; S.sid = m.sid; S.screen = m.screen; S.enc = m.enc;
    S.password = null; S.clipSeen = false;
    if (S.remember) writeJSON(KEY_SLOT, { salt: S.salt, iter: S.iter, key: b64enc(S.key) });
    else forget(KEY_SLOT);
    $('overlay').hidden = true;
    showViewer();
    startStream();
    ping();
    pump();                           // resume uploads queued before a reconnect
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

  function onClosed(ev) {
    const was = S.connected;
    S.connected = false; S.ws = null;
    resetDecoder(true);
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
    $('remoteClip').value = m.text;
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

  // ------------------------------------------------------------ uploads
  const queue = [];
  let up = null, nextId = 1;
  function enqueue(files) { for (const f of files) queue.push(f); pump(); }
  function pump() {
    if (up || !queue.length || !S.connected) return;
    const f = queue.shift();
    up = { id: nextId++, f, sent: 0, acked: 0, busy: false, el: toast(`Sending ${f.name}…`, { ttl: 0 }) };
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
    up.el.textContent = `Sending ${up.f.name}… ${Math.floor(100 * m.n / Math.max(1, up.f.size))}%`;
    sendChunks();
  };
  H.fdone = (m) => {
    if (up && up.id === m.id) { up.el.remove(); up = null; }
    toast('Saved to ' + m.path.replace(/^\/home\/[^/]+/, '~'));
    pump();
  };
  H.ferr = (m) => {
    if (up && up.id === m.id) { up.el.remove(); up = null; }
    toast('Upload failed: ' + m.e, { error: true });
    pump();
  };
  $('fileInput').addEventListener('change', (e) => { enqueue(e.target.files); e.target.value = ''; });
  let dragDepth = 0;
  window.addEventListener('dragenter', (e) => { if (S.connected && e.dataTransfer?.types.includes('Files')) { dragDepth++; $('drop').hidden = false; e.preventDefault(); } });
  window.addEventListener('dragover', (e) => { if (S.connected) e.preventDefault(); });
  window.addEventListener('dragleave', () => { if (--dragDepth <= 0) { dragDepth = 0; $('drop').hidden = true; } });
  window.addEventListener('drop', (e) => {
    e.preventDefault();
    dragDepth = 0; $('drop').hidden = true;
    if (S.connected && e.dataTransfer?.files.length) enqueue(e.dataTransfer.files);
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
  bar.querySelector('[data-act=upload]').addEventListener('click', () => $('fileInput').click());
  bar.querySelector('[data-act=stats]').addEventListener('click', () => { settings.stats = !settings.stats; saveSettings(); applySettings(); });
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
    layout();
  }

  $('copyRemote').addEventListener('click', () => {
    navigator.clipboard?.writeText(S.remoteClip).then(() => toast('Copied'), () => toast('Copy failed', { error: true }));
  });
  $('sendClip').addEventListener('click', () => {
    const t = $('localClip').value;
    if (t) { S.lastSentClip = S.remoteClip = t; send({ t: 'clip', text: t }); toast('Remote clipboard set'); }
  });
  $('typeClip').addEventListener('click', () => {
    const t = $('localClip').value;
    if (t) { send({ t: 'txt', s: t }); focusSink(); }
  });

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
