// Browser end-to-end test: headless Chrome ↔ real host on a private Xvfb display.
// No npm dependencies: speaks the Chrome DevTools Protocol over Node's built-in WebSocket.
//   node tools/webclient_test.mjs
import { spawn } from 'node:child_process';
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const CHROME = process.env.CHROME || '/home/user/.omp/puppeteer/chrome/linux-150.0.7871.24/chrome-linux64/chrome';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const results = [];
const ok = (name, cond, detail = '') => { results.push(!!cond); console.log(`  ${cond ? 'PASS' : 'FAIL'} ${name.padEnd(36)} ${detail}`); };

function lines(stream, onLine) {
  let buf = '';
  stream.on('data', (d) => { buf += d; let i; while ((i = buf.indexOf('\n')) >= 0) { onLine(buf.slice(0, i)); buf = buf.slice(i + 1); } });
}

const procs = [];
// Runs once: a second SIGINT would interrupt the host harness's own cleanup (leaking Xvfb).
const cleanup = () => { for (const p of procs.splice(0).reverse()) { try { p.kill('SIGINT'); } catch {} } };
process.on('exit', cleanup);
process.on('SIGINT', () => process.exit(2));

// 1) host on a private display
const host = spawn('python3', [join(ROOT, 'tools/test_host.py'), '--serve', '--port', '47491'], { stdio: ['ignore', 'pipe', 'inherit'] });
procs.push(host);
const env = await new Promise((resolve, reject) => {
  lines(host.stdout, (l) => { try { resolve(JSON.parse(l)); } catch {} });
  setTimeout(() => reject(new Error('host did not start')), 20000);
});
console.log(`host ready on ${env.display}, port ${env.port}`);

// 2) Chrome
const profile = mkdtempSync(join(tmpdir(), 'darpan-chrome-'));
// --no-sandbox: Ubuntu 24.04 blocks the user namespaces Chrome's sandbox needs; this test
// browser only ever loads our own page on 127.0.0.1.
const chrome = spawn(CHROME, ['--headless=new', '--no-sandbox', '--remote-debugging-port=0', `--user-data-dir=${profile}`, '--no-first-run',
  '--no-default-browser-check', '--window-size=1400,860', '--disable-background-timer-throttling', 'about:blank'],
  { stdio: ['ignore', 'ignore', 'pipe'] });
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
  writeFileSync(join(env.tmp, 'browser-toolbar.png'), Buffer.from(shot2.data, 'base64'));
  console.log('  screenshot:', join(env.tmp, 'browser-toolbar.png'));

  // hidden tab → host stops encoding; visible → resumes with a fresh key frame
  await call('Emulation.setFocusEmulationEnabled', { enabled: true }, sid).catch(() => {});
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
