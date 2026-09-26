// Browser end-to-end test: headless Chrome ↔ real host on a private Xvfb display.
// No npm dependencies: speaks the Chrome DevTools Protocol over Node's built-in WebSocket.
//   node tools/webclient_test.mjs
import { spawn, spawnSync } from 'node:child_process';
import { readFileSync, writeFileSync, mkdtempSync, rmSync, mkdirSync, existsSync, truncateSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
// Chrome/Chromium: $CHROME, else the first browser found in PATH or a puppeteer/playwright cache.
const CHROME = process.env.CHROME || findChrome();
function findChrome() {
  for (const name of ['google-chrome', 'google-chrome-stable', 'chromium', 'chromium-browser']) {
    const r = spawnSync('sh', ['-c', `command -v ${name}`], { encoding: 'utf8' });
    if (r.status === 0 && r.stdout.trim()) return r.stdout.trim();
  }
  const r = spawnSync('sh', ['-c', 'ls -d "$HOME"/.cache/ms-playwright/chromium-*/chrome-linux*/chrome "$HOME"/.*/puppeteer/chrome/linux-*/chrome-linux64/chrome 2>/dev/null | tail -1'], { encoding: 'utf8' });
  if (r.stdout.trim()) return r.stdout.trim();
  throw new Error('no Chrome/Chromium found: set CHROME=/path/to/chrome');
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const results = [];
const ok = (name, cond, detail = '') => { results.push(!!cond); console.log(`  ${cond ? 'PASS' : 'FAIL'} ${name.padEnd(36)} ${detail}`); };

function lines(stream, onLine) {
  let buf = '';
  stream.on('data', (d) => { buf += d; let i; while ((i = buf.indexOf('\n')) >= 0) { onLine(buf.slice(0, i)); buf = buf.slice(i + 1); } });
}

const procs = [], dirs = [];
// Runs once: a second SIGINT would interrupt the host harness's own cleanup (leaking Xvfb). Chrome
// gets SIGKILL: headless, it can ignore SIGINT and outlive the test.
const cleanup = () => {
  for (const p of procs.splice(0).reverse()) { try { p.kill(p.signal || 'SIGINT'); } catch {} }
  for (const d of dirs.splice(0)) rmSync(d, { recursive: true, force: true, maxRetries: 5 });
};
process.on('exit', cleanup);
process.on('SIGINT', () => process.exit(2));

// 1) host on a private display
const host = spawn('python3', [join(ROOT, 'tools/test_host.py'), '--serve', '--port', process.env.DARPAN_TEST_PORT || '47491'],
  { stdio: ['ignore', 'pipe', 'inherit'] });
procs.push(host);
const env = await new Promise((resolve, reject) => {
  lines(host.stdout, (l) => { try { resolve(JSON.parse(l)); } catch {} });
  setTimeout(() => reject(new Error('host did not start')), 20000);
});
console.log(`host ready on ${env.display}, port ${env.port}`);

// 2) Chrome
const profile = mkdtempSync(join(tmpdir(), 'darpan-chrome-'));
dirs.push(profile);
// --no-sandbox: Ubuntu 24.04 blocks the user namespaces Chrome's sandbox needs; this test
// browser only ever loads our own page on 127.0.0.1.
const chrome = spawn(CHROME, ['--headless=new', '--no-sandbox', '--remote-debugging-port=0', `--user-data-dir=${profile}`, '--no-first-run',
  '--no-default-browser-check', '--window-size=1400,860', '--disable-background-timer-throttling',
  '--autoplay-policy=no-user-gesture-required', 'about:blank'],   // sound starts without a real click
  { stdio: ['ignore', 'ignore', 'pipe'] });
chrome.signal = 'SIGKILL';
procs.push(chrome);
const wsUrl = await new Promise((resolve, reject) => {
  lines(chrome.stderr, (l) => { const m = l.match(/DevTools listening on (ws:\/\/\S+)/); if (m) resolve(m[1]); });
  setTimeout(() => reject(new Error('chrome did not start')), 20000);
});

// 3) minimal CDP client
const cdp = new WebSocket(wsUrl);
await new Promise((r) => cdp.addEventListener('open', r, { once: true }));
let msgId = 0;
const waiters = new Map();
const events = [];
cdp.addEventListener('message', (ev) => {
  const m = JSON.parse(ev.data);
  if (m.id && waiters.has(m.id)) { waiters.get(m.id)(m); waiters.delete(m.id); }
  else if (m.method) events.push(m);
});
const call = (method, params = {}, sessionId) => new Promise((resolve, reject) => {
  const id = ++msgId;
  waiters.set(id, (m) => (m.error ? reject(new Error(method + ': ' + m.error.message)) : resolve(m.result)));
  cdp.send(JSON.stringify({ id, method, params, sessionId }));
});
const { targetInfos } = await call('Target.getTargets');
const page = targetInfos.find((t) => t.type === 'page');
const { sessionId: sid } = await call('Target.attachToTarget', { targetId: page.targetId, flatten: true });
const ev = (expr) => call('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true }, sid).then((r) => r.result.value);
await call('Page.enable', {}, sid);
await call('Runtime.enable', {}, sid);
await call('Page.navigate', { url: `http://127.0.0.1:${env.port}/` }, sid);
await sleep(1200);

const probeLog = () => readFileSync(env.probe_log, 'utf8').split('\n');
const until = async (expr, ms = 5000) => { let v; for (const t0 = Date.now(); Date.now() - t0 < ms; await sleep(100)) if ((v = await ev(expr))) return v; return v; };
try {
  const sup = await ev(`VideoDecoder.isConfigSupported({codec:'avc1.640028', optimizeForLatency:true}).then(r => r.supported)`);
  ok('WebCodecs H.264 supported', sup === true);
  ok('login page shows host', (await ev(`document.getElementById('hostName').textContent`)).length > 0);

  // wrong password first
  await ev(`document.getElementById('password').value='nope-nope'; document.getElementById('loginForm').requestSubmit(); 1`);
  await sleep(1500);
  const msg = await ev(`document.getElementById('loginMsg').textContent`);
  ok('wrong password message', /Wrong password/.test(msg), JSON.stringify(msg));

  await ev(`document.getElementById('password').value=${JSON.stringify(env.password)}; document.getElementById('loginForm').requestSubmit(); 1`);
  let frames = 0;
  for (let i = 0; i < 40 && !frames; i++) { await sleep(250); frames = await ev('window.__darpan.frames'); }
  ok('video frames decoded', frames > 0, `${frames} frame(s)`);
  ok('viewer visible', await ev(`!document.getElementById('viewer').hidden`));
  const saved = await ev(`!!localStorage.getItem('darpan.key.' + location.host)`);
  ok('device remembered (key only)', saved && !(await ev(`localStorage.getItem('darpan.key.' + location.host).includes(${JSON.stringify(env.password)})`)));

  // the first time: the toolbar stays open, a tip points at it and at its grip, until "Got it"
  const tipState = `(() => { const t = document.getElementById('tip'), r = t.getBoundingClientRect();
    return { shown: !t.hidden, title: document.getElementById('tipTitle').textContent, tools: document.querySelector('.tools').offsetWidth > 0,
      grip: document.querySelector('.handle').offsetWidth > 0, onScreen: r.left >= 0 && r.right <= innerWidth && r.top >= 0 && r.bottom <= innerHeight,
      seen: localStorage.getItem('darpan.tipSeen') }; })()`;
  const tip1 = await until(`(${tipState}).shown && ${tipState}`);
  ok('first time: the toolbar tip shows', tip1 && tip1.title === 'Your controls' && tip1.tools && tip1.grip && tip1.onScreen && !tip1.seen, JSON.stringify(tip1));
  writeFileSync(join(process.env.DARPAN_TEST_SHOTS || env.tmp, 'browser-tip.png'), Buffer.from((await call('Page.captureScreenshot', { format: 'png' }, sid)).data, 'base64'));
  await ev(`document.getElementById('tipOk').click()`);
  const tip2 = await ev(tipState);
  ok('"Got it" hides it, for good', !tip2.shown && !tip2.tools && tip2.seen === 'true', JSON.stringify(tip2));

  const shot = await call('Page.captureScreenshot', { format: 'png' }, sid);
  writeFileSync(join(env.tmp, 'browser.png'), Buffer.from(shot.data, 'base64'));
  console.log('  screenshot:', join(env.tmp, 'browser.png'));

  // pointer → host
  const r = await ev(`(() => { const b = document.getElementById('screen').getBoundingClientRect(); return [b.left, b.top, b.width, b.height, window.__darpan.stream.w, window.__darpan.stream.h]; })()`);
  const [left, top, width, height, sw, shh] = r;
  const cx = left + width * (200 / sw), cy = top + height * (150 / shh);
  await call('Input.dispatchMouseEvent', { type: 'mouseMoved', x: cx, y: cy }, sid);
  await call('Input.dispatchMouseEvent', { type: 'mousePressed', x: cx, y: cy, button: 'left', buttons: 1, clickCount: 1 }, sid);
  await call('Input.dispatchMouseEvent', { type: 'mouseReleased', x: cx, y: cy, button: 'left', buttons: 0, clickCount: 1 }, sid);
  await call('Input.dispatchMouseEvent', { type: 'mouseWheel', x: cx, y: cy, deltaX: 0, deltaY: 100 }, sid);
  await sleep(400);
  let log = probeLog();
  const mot = log.filter((l) => l.startsWith('MOTION')).pop() || '';
  const [mx, my] = mot.split(' ').slice(1).map(Number);
  ok('mouse move mapped to remote px', Math.abs(mx - 200) <= 2 && Math.abs(my - 150) <= 2, mot);
  ok('mouse click', log.includes('BUTTON press 1') && log.includes('BUTTON release 1'));
  ok('wheel → 2 notches', log.filter((l) => l === 'BUTTON press 5').length === 2);

  // keyboard → host (the page keeps focus on its hidden key sink)
  for (const [code, key, vk] of [['KeyH', 'h', 72], ['KeyI', 'i', 73]]) {
    await call('Input.dispatchKeyEvent', { type: 'keyDown', code, key, text: key, windowsVirtualKeyCode: vk }, sid);
    await call('Input.dispatchKeyEvent', { type: 'keyUp', code, key, windowsVirtualKeyCode: vk }, sid);
  }
  await sleep(400);
  log = probeLog();
  ok('typing reaches the host', log.some((l) => l.includes("text='h'")) && log.some((l) => l.includes("text='i'")));

  // a key press repaints the probe window: measure browser→host→browser round trip
  const lat = [];
  for (let i = 0; i < 8; i++) {
    const before = await ev('window.__darpan.frames');
    const t0 = Date.now();
    await call('Input.dispatchKeyEvent', { type: 'keyDown', code: 'KeyA', key: 'a', text: 'a', windowsVirtualKeyCode: 65 }, sid);
    let f = before;
    while (f === before && Date.now() - t0 < 2000) f = await ev('window.__darpan.frames');
    lat.push(Date.now() - t0);
    await call('Input.dispatchKeyEvent', { type: 'keyUp', code: 'KeyA', key: 'a', windowsVirtualKeyCode: 65 }, sid);
    await sleep(200);
  }
  lat.sort((a, b) => a - b);
  ok('key → decoded frame in browser', lat[4] < 60, `median ${lat[4]} ms incl. CDP polling overhead (min ${lat[0]})`);

  // a drag interrupted by losing focus must not leave the button held on the host
  await call('Input.dispatchMouseEvent', { type: 'mousePressed', x: cx, y: cy, button: 'left', buttons: 1, clickCount: 1 }, sid);
  await sleep(150);
  const presses = probeLog().filter((l) => l === 'BUTTON press 1').length;
  await ev(`window.dispatchEvent(new Event('blur')); 1`);
  await sleep(400);
  log = probeLog();
  ok('blur mid-drag releases the button', log.filter((l) => l === 'BUTTON release 1').length >= presses,
     `${presses} presses, ${log.filter((l) => l === 'BUTTON release 1').length} releases`);
  await call('Input.dispatchMouseEvent', { type: 'mouseReleased', x: cx, y: cy, button: 'left', buttons: 0, clickCount: 1 }, sid);

  const cur = await ev(`({css: document.getElementById('screen').style.cursor, scale: window.__darpan.cssScale})`);
  ok('pointer drawn at display scale', /^(url|image-set)\(/.test(cur.css) && cur.scale < 1, `scale ${cur.scale.toFixed(2)}, ${cur.css.slice(0, 40)}…`);

  const st = await ev(`({fps: window.__darpan.fps, lat: window.__darpan.latency, dec: window.__darpan.decodeMs, rtt: window.__darpan.rtt, enc: window.__darpan.stream.enc})`);
  ok('stats populated', st.rtt != null, JSON.stringify(st));

  // sound: the host's (stand-in) pw-record tone arrives on /audio, decodes, fills the worklet buffer
  let snd = null;
  for (let i = 0; i < 50; i++) {
    snd = await ev(`({packets: window.__darpan.sound.packets, depth: window.__darpan.sound.depth, target: window.__darpan.sound.target, state: window.__darpan.sound.ctx && window.__darpan.sound.ctx.state})`);
    if (snd.packets > 50 && snd.depth > 0) break;
    await sleep(100);
  }
  ok('sound plays (Opus → worklet buffer)', snd.packets > 50 && snd.depth > 0 && snd.state === 'running', JSON.stringify(snd));
  // muting stops the stream and lets the audio graph sleep; unmuting brings it back
  await ev(`document.querySelector('[data-act=audio]').click()`);
  await sleep(600);
  const muted = await ev(`({state: window.__darpan.sound.ctx.state, ws: !!window.__darpan.sound.ws, packets: window.__darpan.sound.packets})`);
  await ev(`document.querySelector('[data-act=audio]').click()`);
  let resumed = null;
  for (let i = 0; i < 40; i++) {
    resumed = await ev(`({state: window.__darpan.sound.ctx.state, packets: window.__darpan.sound.packets})`);
    if (resumed.packets > muted.packets + 30 && resumed.state === 'running') break;
    await sleep(100);
  }
  ok('mute suspends audio, unmute resumes', muted.state === 'suspended' && !muted.ws && resumed.packets > muted.packets + 30 && resumed.state === 'running',
     `muted ${muted.state}, then ${resumed.state} +${resumed.packets - muted.packets} packets`);

  // toolbar: collapsed by default, expands on click
  ok('toolbar collapsed by default', await ev(`document.getElementById('bar').classList.contains('collapsed')`));
  const pr = await ev(`(() => { const b = document.getElementById('pill').getBoundingClientRect(); return [b.x + b.width/2, b.y + b.height/2, b.width, b.height]; })()`);
  ok('collapsed pill is tiny', pr[2] <= 48 && pr[3] <= 20, `${pr[2]}×${pr[3]} px`);
  await call('Input.dispatchMouseEvent', { type: 'mouseMoved', x: pr[0], y: pr[1] }, sid);
  await call('Input.dispatchMouseEvent', { type: 'mousePressed', x: pr[0], y: pr[1], button: 'left', buttons: 1, clickCount: 1 }, sid);
  await call('Input.dispatchMouseEvent', { type: 'mouseReleased', x: pr[0], y: pr[1], button: 'left', buttons: 0, clickCount: 1 }, sid);
  await sleep(200);
  ok('toolbar expands', !(await ev(`document.getElementById('bar').classList.contains('collapsed')`)));
  const modes = await ev(`(document.querySelector('[data-panel=display]').click(), new Promise(r => setTimeout(() => r(document.querySelectorAll('#modes button').length), 600)))`);
  ok('resolution list rendered', modes >= 1, `${modes} option(s)`);
  const shot2 = await call('Page.captureScreenshot', { format: 'png' }, sid);
  writeFileSync(join(process.env.DARPAN_TEST_SHOTS || env.tmp, 'browser-toolbar.png'), Buffer.from(shot2.data, 'base64'));
  console.log('  screenshot:', join(process.env.DARPAN_TEST_SHOTS || env.tmp, 'browser-toolbar.png'));

  // files (PROTOCOL.md §7.1): the transfer window lists the Linux side, sends, asks before replacing, receives
  ok('no clipboard panel', await ev(`!document.getElementById('panel-clip') && !document.querySelector('[data-panel=clip]')`));
  const waitFile = async (p, ms = 5000) => { for (const t0 = Date.now(); Date.now() - t0 < ms; await sleep(100)) if (existsSync(p)) return readFileSync(p, 'utf8'); return null; };
  const xdir = join(env.tmp, 'xfer');
  mkdirSync(join(xdir, 'sub'), { recursive: true });
  writeFileSync(join(xdir, 'a.txt'), 'hello from linux\n');
  writeFileSync(join(xdir, 'sub', 'b.txt'), 'b\n');
  // (the toolbar check above clicked where the pill was, which is where the Files button appears: it may be open already)
  await ev(`document.getElementById('files').hidden && document.querySelector('[data-act=files]').click()`);
  const home = await until(`window.__darpan.fs.path`);
  const shown = await ev(`!document.getElementById('files').hidden`);
  ok('files window opens on home', home === env.tmp && shown, JSON.stringify({ home, tmp: env.tmp, shown }));
  await ev(`(() => { const p = document.getElementById('fsPath'); p.value = ${JSON.stringify(xdir)};
    p.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true })); })()`);
  const names = await until(`window.__darpan.fs.path === ${JSON.stringify(xdir)} && [...document.querySelectorAll('#fsList .file .name span')].map(s => s.textContent).join(',')`);
  ok('lists a folder, folders first', names === 'sub,a.txt', names);
  const shots = process.env.DARPAN_TEST_SHOTS || env.tmp;
  writeFileSync(join(shots, 'browser-files.png'), Buffer.from((await call('Page.captureScreenshot', { format: 'png' }, sid)).data, 'base64'));
  console.log('  screenshot:', join(shots, 'browser-files.png'));

  const local = join(profile, 'upload.txt');
  writeFileSync(local, 'sent from the browser\n');
  const { root } = await call('DOM.getDocument', {}, sid);
  const input = (await call('DOM.querySelector', { nodeId: root.nodeId, selector: '#fsFiles' }, sid)).nodeId;
  await call('DOM.setFileInputFiles', { nodeId: input, files: [local] }, sid);
  ok('send a file into the folder shown', (await waitFile(join(xdir, 'upload.txt'))) === 'sent from the browser\n');
  await until(`[...document.querySelectorAll('#fsList .file .name span')].some(s => s.textContent === 'upload.txt')`);
  await call('DOM.setFileInputFiles', { nodeId: input, files: [local] }, sid);
  const asked = await until(`!document.getElementById('fsAsk').hidden && document.getElementById('fsAskText').textContent`);
  writeFileSync(join(shots, 'browser-files-ask.png'), Buffer.from((await call('Page.captureScreenshot', { format: 'png' }, sid)).data, 'base64'));
  await ev(`document.querySelector('[data-ask=rename]').click()`);
  ok('asks before replacing; Keep both', /upload\.txt/.test(asked || '') && (await waitFile(join(xdir, 'upload (1).txt'))) === 'sent from the browser\n', asked);

  const downloads = join(profile, 'downloads');
  mkdirSync(downloads);
  await call('Browser.setDownloadBehavior', { behavior: 'allow', downloadPath: downloads });
  await ev(`(() => { const row = [...document.querySelectorAll('#fsList .file')].find(r => r.textContent.startsWith('a.txt')); row.click();
    document.getElementById('fsReceive').click(); })()`);
  ok('receive downloads the selection', (await waitFile(join(downloads, 'a.txt'), 8000)) === 'hello from linux\n');

  // a folder keeps its structure where the browser can write folders; the origin-private file system
  // stands in for the folder the user would pick
  await ev(`window.showDirectoryPicker = async () => navigator.storage.getDirectory()`);
  const receiveSub = `(() => { const row = [...document.querySelectorAll('#fsList .file')].find(r => r.textContent.startsWith('sub')); row.click();
    document.getElementById('fsReceive').click(); })()`;
  const opfs = (expr) => `(async () => { const r = await navigator.storage.getDirectory(); try { ${expr} } catch { return ''; } })()`;
  await ev(receiveSub);
  const tree = await until(opfs(`const d = await r.getDirectoryHandle('sub'); return await (await (await d.getFileHandle('b.txt')).getFile()).text();`), 8000);
  ok('receive a folder: keeps its structure', tree === 'b\n', JSON.stringify(tree));
  await ev(receiveSub);
  const both = await until(opfs(`await r.getDirectoryHandle('sub (1)'); return 'yes';`), 8000);
  ok('receive it again: keeps both', both === 'yes', JSON.stringify(both));

  // a folder on its way can be cancelled, and nothing half-written is kept
  mkdirSync(join(xdir, 'big'));
  writeFileSync(join(xdir, 'big', 'huge.bin'), '');
  truncateSync(join(xdir, 'big', 'huge.bin'), 1 << 30);
  mkdirSync(join(xdir, 'two'));
  writeFileSync(join(xdir, 'two', 'one.txt'), 'first\n');
  writeFileSync(join(xdir, 'two', 'two.txt'), 'second\n');
  await ev(`(() => { const p = document.getElementById('fsPath'); p.value = ${JSON.stringify(xdir)};
    p.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true })); })()`);
  await until(`[...document.querySelectorAll('#fsList .file .name span')].some(s => s.textContent === 'two')`);
  const receiveOne = (n) => `(() => { const row = [...document.querySelectorAll('#fsList .file')].find(r => r.textContent.startsWith(${JSON.stringify(n)})); row.click();
    document.getElementById('fsReceive').click(); })()`;
  const line = (n) => `[...document.querySelectorAll('#fsXfers .xfer')].find(x => x.querySelector('.name').textContent.startsWith(${JSON.stringify(n)}))`;
  await ev(receiveOne('big'));
  await until(`(${line('big')}) && parseInt((${line('big')}).querySelector('.pct').textContent) > 0`, 8000);
  await ev(`(${line('big')}).querySelector('.x').click()`);
  const cancelled = await until(`(${line('big')})?.classList.contains('cancelled') && (${line('big')}).textContent`, 5000);
  const partial = await ev(opfs(`const d = await r.getDirectoryHandle('big'); return String((await (await d.getFileHandle('huge.bin')).getFile()).size);`));
  ok('receive a folder: Cancel stops it, no half-written file', /Cancelled: 0 of 1/.test(cancelled || '') && partial === '0',
     JSON.stringify({ cancelled, partial }));
  // the session reconnected mid-folder: its old file token is dead, and a new one is fetched
  await ev(`(() => { const f = window.fetch; let first = true;
    window.fetch = (u, o) => { if (first && String(u).startsWith('/fs/file?path=')) { first = false; window.__darpan.fs.token = 'stale';
      o = { ...o, headers: { Authorization: 'Bearer stale' } }; } return f(u, o); }; })()`);
  await ev(receiveOne('two'));
  const second = await until(opfs(`const d = await r.getDirectoryHandle('two'); return (await (await (await d.getFileHandle('one.txt')).getFile()).text()) + (await (await (await d.getFileHandle('two.txt')).getFile()).text());`), 8000);
  ok('receive a folder: a new token after a reconnect', second === 'first\nsecond\n', JSON.stringify(second));

  await ev(`(() => { const dt = new DataTransfer(); dt.items.add(new File(['into the folder'], 'dropped-here.txt'));
    document.getElementById('fsList').dispatchEvent(new DragEvent('drop', { dataTransfer: dt, bubbles: true, cancelable: true })); })()`);
  ok('drop on the window: into its folder', (await waitFile(join(xdir, 'dropped-here.txt'))) === 'into the folder');
  await ev(`(() => { const dt = new DataTransfer(); dt.items.add(new File(['on the desktop'], 'dropped.txt'));
    document.getElementById('stage').dispatchEvent(new DragEvent('drop', { dataTransfer: dt, bubbles: true, cancelable: true })); })()`);
  ok('drop elsewhere: onto the desktop', (await waitFile(join(env.tmp, 'Desktop', 'dropped.txt'))) === 'on the desktop');
  writeFileSync(join(shots, 'browser-drop-toast.png'), Buffer.from((await call('Page.captureScreenshot', { format: 'png' }, sid)).data, 'base64'));
  await ev(`document.querySelector('[data-fs=close]').click()`);
  ok('files window closes', await ev(`document.getElementById('files').hidden`));
  await ev(`(() => { const dt = new DataTransfer(); dt.items.add(new File(['x'], 'x.txt'));
    window.dispatchEvent(new DragEvent('dragenter', { dataTransfer: dt, bubbles: true, cancelable: true })); })()`);
  const target = await ev(`!document.getElementById('drop').hidden`);
  writeFileSync(join(shots, 'browser-drop-target.png'), Buffer.from((await call('Page.captureScreenshot', { format: 'png' }, sid)).data, 'base64'));
  await ev(`window.dispatchEvent(new DragEvent('dragleave', { bubbles: true }))`);
  ok('a drag shows the drop target', target && await ev(`document.getElementById('drop').hidden`));

  // hidden tab → host stops encoding; visible → resumes with a fresh key frame
  await call('Emulation.setFocusEmulationEnabled', { enabled: true }, sid).catch(() => {});
  // host restart (it says bye + closes 4004): the client must come back by itself
  const f0 = await ev('window.__darpan.frames');
  process.kill(host.pid, 'SIGUSR1');
  let down = false, back = false;
  for (let i = 0; i < 60 && !back; i++) {
    await sleep(250);
    const c = await ev('window.__darpan.connected');
    if (!c) down = true;
    else if (down) back = true;
  }
  await sleep(1500);
  const f1 = await ev('window.__darpan.frames');
  ok('reconnects after host restart', down && back && f1 > f0 && await ev(`document.getElementById('login').hidden`),
     `down=${down} back=${back} frames ${f0}→${f1}`);

  // the tip again (forgotten): dragging the toolbar by its grip moves it and counts as "Got it"; after a
  // reload it stays away
  const reload = async () => {
    await ev(`document.querySelector('[data-act=disconnect]').click()`);   // disconnected: no "leave this page?"
    await until(`!window.__darpan.connected`);
    await call('Page.reload', {}, sid);
    await sleep(1200);
    await until(`window.__darpan.frames > 0`, 10000);
  };
  await ev(`localStorage.removeItem('darpan.tipSeen')`);
  await reload();
  const tip3 = await until(`(${tipState}).shown && ${tipState}`);
  await ev(`document.querySelector('.tools').getAnimations().forEach((a) => a.finish())`);   // the nudge
  const hb = await ev(`(() => { const b = document.querySelector('.handle').getBoundingClientRect(); return [b.x + b.width / 2, b.y + b.height / 2]; })()`);
  const x0 = await ev(`parseFloat(document.getElementById('bar').style.left)`);
  await call('Input.dispatchMouseEvent', { type: 'mouseMoved', x: hb[0], y: hb[1] }, sid);
  await call('Input.dispatchMouseEvent', { type: 'mousePressed', x: hb[0], y: hb[1], button: 'left', buttons: 1, clickCount: 1 }, sid);
  for (const dx of [10, 40, 80]) await call('Input.dispatchMouseEvent', { type: 'mouseMoved', x: hb[0] + dx, y: hb[1], button: 'left', buttons: 1 }, sid);
  await call('Input.dispatchMouseEvent', { type: 'mouseReleased', x: hb[0] + 80, y: hb[1], button: 'left', buttons: 0, clickCount: 1 }, sid);
  const tip4 = await ev(tipState);
  const moved = (await ev(`parseFloat(document.getElementById('bar').style.left)`)) - x0;
  ok('drag by the grip: moves, ends the tip', tip3 && !tip4.shown && tip4.seen === 'true' && Math.abs(moved - 80) <= 2,
     `moved ${moved} px; ${JSON.stringify(tip4)}`);
  // a toolbar button ends it too (here clicked without a pointer, as from the keyboard): the toolbar
  // stays open with its panel
  await ev(`localStorage.removeItem('darpan.tipSeen')`);
  await reload();
  await until(`(${tipState}).shown`);
  await ev(`document.querySelector('[data-panel=display]').click()`);
  const tip5 = await ev(`(() => ({ tip: !document.getElementById('tip').hidden, panel: !document.getElementById('panel-display').hidden,
    tools: document.querySelector('.tools').offsetWidth > 0 }))()`);
  ok('a toolbar button ends the tip, the toolbar stays open', !tip5.tip && tip5.panel && tip5.tools, JSON.stringify(tip5));
  await ev(`document.querySelector('[data-panel=display]').click()`);   // and closes its panel again
  await reload();
  await sleep(800);
  ok('the tip stays away after a reload', !(await ev(tipState)).shown);

  const hostLog = () => readFileSync(env.host_log, 'utf8');
  ok('no host errors', !/Traceback|ERROR|E tc/.test(hostLog()), hostLog().split('\n').filter((l) => /Traceback|E tc/.test(l)).slice(0, 3).join(' | '));
} catch (e) {
  ok('test crashed', false, e.stack);
}
console.log('\nRESULT:', results.every(Boolean) ? 'ALL PASS' : 'FAILURES');
cdp.close();
cleanup();
rmSync(profile, { recursive: true, force: true });
process.exit(results.every(Boolean) ? 0 : 1);
