import math, wave, struct

def decode_pcm16(fn):
    """Read a mono/stereo 16-bit PCM WAV into a mono int list + frame rate."""
    w = wave.open(fn, "rb")
    ch = w.getnchannels(); sw = w.getsampwidth(); fr = w.getframerate(); n = w.getnframes()
    if sw != 2:
        raise ValueError("needs 16-bit PCM, got %d bytes/sample" % sw)
    data = w.readframes(n)
    w.close()
    vals = struct.unpack("<%dh" % (len(data) // 2), data)
    if ch == 1:
        return list(vals), fr
    mono = []
    for i in range(0, len(vals) - ch + 1, ch):
        mono.append(sum(vals[i:i + ch]) // ch)
    return mono, fr

def _resample(samp, fr, target=8000):
    if fr == target:
        return samp
    n = len(samp)
    if n == 0:
        return []
    out = [0] * int(n * target / fr)
    ratio = (n - 1) / float(len(out) - 1) if len(out) > 1 else 0
    for i in range(len(out)):
        pos = i * ratio
        i0 = int(pos); i1 = min(i0 + 1, n - 1)
        frac = pos - i0
        out[i] = samp[i0] * (1 - frac) + samp[i1] * frac
    return out

ROW = [697, 770, 852, 941]
COL = [1209, 1336, 1477, 1633]
KEYMAP = [['1','2','3','A'],['4','5','6','B'],['7','8','9','C'],['*','0','#','D']]


class _GoertzelBank:
    """Incremental Goertzel so we don't recompute from scratch each block."""
    def __init__(self, freqs, fr, block):
        self.fr = fr
        self.st = []
        for f in freqs:
            w = 2.0 * math.pi * f / fr
            self.st.append((2.0 * math.cos(w), 0.0, 0.0))  # coeff, s1, s2

    def push_block(self, samples):
        mags = []
        for (coeff, s1, s2), _ in zip(self.st, range(len(self.st))):
            s1 = s2 = 0.0
            for x in samples:
                s0 = x + coeff * s1 - s2
                s2 = s1; s1 = s0
            mags.append(math.sqrt(s1 * s1 + s2 * s2 - coeff * s1 * s2))
        return mags


class DtmfToneDetector:
    """Detect DTMF dual-tones from a stream of 16-bit PCM mono samples.

    Feed samples via `feed(samples, fr)`. When a key-press is recognised the
    detector yields `(time_sec, digit)` via the `on_dtmf` callback or by
    iterating `detected`.
    """
    def __init__(self, on_dtmf=None, block_ms=20, hold_blocks=3,
                 release_blocks=10, ratio=0.60, min_abs=40000):
        self.on_dtmf = on_dtmf
        self.fr = 8000
        self.block = int(self.fr * block_ms / 1000)
        self.hold = hold_blocks
        self.release = release_blocks
        self.ratio = ratio
        self.min_abs = min_abs
        self._rowbank = _GoertzelBank(ROW, self.fr, self.block)
        self._colbank = _GoertzelBank(COL, self.fr, self.block)
        self._pending_mono = []      # resampled-to-8k samples not yet in a block
        self._buf = []               # 8k samples in the current analysis window
        self._cur = None             # (row_idx, col_idx) currently held, or None
        self._hold_count = 0
        self._release_count = 0
        self._elapsed = 0.0
        self.detected = []           # (time_sec, digit)
        self._last_emit_t = -1.0

    def feed_mono(self, samples, sr):
        rs = _resample(samples, sr, 8000)
        self._pending_mono.extend(rs)
        # consume whole 20ms blocks
        n = len(self._pending_mono)
        while n >= self.block:
            blk = self._pending_mono[:self.block]
            self._pending_mono = self._pending_mono[self.block:]
            self._process_block(blk)
            self._elapsed += self.block / 8000.0
            n = len(self._pending_mono)

    def feed_bytes(self, raw, sr, channels=1):
        """Feed raw little-endian 16-bit PCM bytes."""
        n = len(raw) // 2
        vals = struct.unpack("<%dh" % n, raw)
        if channels == 1:
            self.feed_mono(list(vals), sr)
        else:
            mono = [sum(vals[i:i + channels]) // channels
                    for i in range(0, n - channels + 1, channels)]
            self.feed_mono(mono, sr)

    def _process_block(self, blk):
        rmags = self._rowbank.push_block(blk)
        cmags = self._colbank.push_block(blk)
        # find max row and col that pass the absolute floor
        rmax = max(range(4), key=lambda i: rmags[i])
        cmax = max(range(4), key=lambda i: cmags[i])
        rv, cv = rmags[rmax], cmags[cmax]
        # a valid DTMF: both a row and a col tone clearly above the rest
        other_r = sorted((rmags[i] for i in range(4) if i != rmax), reverse=True)
        other_c = sorted((cmags[i] for i in range(4) if i != cmax), reverse=True)
        row_ok = rv > self.min_abs and rv > self.ratio * (other_r[0] if other_r else 1)
        col_ok = cv > self.min_abs and cv > self.ratio * (other_c[0] if other_c else 1)
        # balance between the pair members (both must be strong)
        pair = (rmax, cmax)
        if row_ok and col_ok and (rv > self.ratio * cv or cv > self.ratio * rv) \
           and rv > self.min_abs and cv > self.min_abs:
            if self._cur == pair:
                self._hold_count += 1
                self._release_count = 0
            else:
                self._cur = pair
                self._hold_count = 1
                self._release_count = 0
        else:
            self._release_count += 1
            if self._cur is not None and self._release_count >= self.release:
                self._cur = None
                self._hold_count = 0
        # emit when the dual-tone has held long enough
        if self._cur is not None and self._hold_count >= self.hold:
            digit = KEYMAP[self._cur[0]][self._cur[1]]
            if self._elapsed - self._last_emit_t > 0.3:
                self._last_emit_t = self._elapsed
                self.detected.append((self._elapsed, digit))
                if self.on_dtmf:
                    try:
                        self.on_dtmf(digit)
                    except Exception:
                        pass


def detect(fn, on_dtmf=None, min_abs=40000):
    samp, fr = decode_pcm16(fn)
    d = DtmfToneDetector(on_dtmf=on_dtmf, min_abs=min_abs)
    d.feed_mono(samp, fr)
    return d.detected


if __name__ == "__main__":
    import sys
    res = detect(sys.argv[1])
    if not res:
        print("NO DTMF TONES DETECTED")
    else:
        for t, k in res:
            print("DTMF %s at %.2fs" % (k, t))
