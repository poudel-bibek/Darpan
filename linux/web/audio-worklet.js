// Plays the host's sound with a small jitter buffer (PROTOCOL.md §12). Runs on the audio thread.
// Starts at 40 ms of buffering; a late packet grows it by 10 ms (up to 200 ms), ~4 s without one
// shrinks it again. A gap that ends with a FIRST packet was silence, not lateness: if audio is still
// buffered, the skipped slots are played as silence (timing kept); if not, it re-primes.
class DarpanSound extends AudioWorkletProcessor {
  constructor() {
    super();
    this.cap = 48000;                                   // 1 s ring
    this.l = new Float32Array(this.cap);
    this.r = new Float32Array(this.cap);
    this.w = 0; this.rd = 0; this.n = 0;                // write index, read index, frames buffered
    this.target = 1920;                                 // 40 ms at 48 kHz
    this.playing = false;
    this.starved = false;                               // ran dry: late packet or silence? the next packet says
    this.calm = 0;
    this.port.onmessage = (e) => {
      const m = e.data;
      if (m.reset) {
        this.starved = false;
        if (this.n > 0 && m.gap) this.silence(m.gap); else this.playing = false;
        return;
      }
      if (this.starved) { this.target = Math.min(9600, this.target + 480); this.starved = false; this.calm = 0; }
      const L = m.l, R = m.r, k = L.length;
      if (this.n + k > this.cap) this.skip(this.n + k - this.cap);
      for (let i = 0; i < k; i++) {
        this.l[this.w] = L[i]; this.r[this.w] = R[i];
        this.w = (this.w + 1) % this.cap;
      }
      this.n += k;
    };
  }

  skip(k) { this.rd = (this.rd + k) % this.cap; this.n -= k; }

  silence(k) {
    k = Math.min(k, this.cap - this.n);
    for (let i = 0; i < k; i++) { this.l[this.w] = 0; this.r[this.w] = 0; this.w = (this.w + 1) % this.cap; }
    this.n += k;
  }

  process(inputs, outputs) {
    const L = outputs[0][0], R = outputs[0][1] || outputs[0][0], k = L.length;
    if (!this.playing && this.n >= this.target) this.playing = true;
    if (!this.playing || this.n < k) {
      if (this.playing) { this.playing = false; this.starved = true; }
      L.fill(0); R.fill(0);
      this.report();
      return true;
    }
    if (this.n > 2 * this.target) this.skip(this.n - this.target);   // clock drift or a burst: catch up
    for (let i = 0; i < k; i++) {
      L[i] = this.l[this.rd]; R[i] = this.r[this.rd];
      this.rd = (this.rd + 1) % this.cap;
    }
    this.n -= k;
    if (++this.calm > 1500 && this.target > 1920) { this.target -= 480; this.calm = 0; }
    this.report();
    return true;
  }

  report() {
    if ((currentFrame & 8191) < 128) this.port.postMessage({ depth: this.n, target: this.target });   // ~6/s
  }
}
registerProcessor('darpan-sound', DarpanSound);
