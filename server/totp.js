import crypto from 'node:crypto';

// TOTP (RFC 6238) with the conventional authenticator-app defaults:
// SHA-1, 6 digits, 30-second steps. Keeping the implementation local avoids a
// dependency for a handful of lines and lets tests generate codes directly.

const BASE32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

export function base32Encode(buffer) {
  let bits = 0;
  let value = 0;
  let out = '';
  for (const byte of buffer) {
    value = (value << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      out += BASE32[(value >>> (bits - 5)) & 31];
      bits -= 5;
    }
  }
  if (bits > 0) out += BASE32[(value << (5 - bits)) & 31];
  return out;
}

export function base32Decode(input) {
  const clean = String(input)
    .toUpperCase()
    .replace(/[\s=-]/g, '');
  let bits = 0;
  let value = 0;
  const bytes = [];
  for (const char of clean) {
    const index = BASE32.indexOf(char);
    if (index === -1) throw new Error('invalid base32');
    value = (value << 5) | index;
    bits += 5;
    if (bits >= 8) {
      bytes.push((value >>> (bits - 8)) & 0xff);
      bits -= 8;
    }
  }
  return Buffer.from(bytes);
}

/// 20 random bytes -> 32 base32 characters (160 bits, the RFC 4226 default).
export function generateSecret() {
  return base32Encode(crypto.randomBytes(20));
}

export function hotp(secret, counter) {
  const key = base32Decode(secret);
  const buf = Buffer.alloc(8);
  buf.writeUInt32BE(Math.floor(counter / 0x100000000), 0);
  buf.writeUInt32BE(counter >>> 0, 4);
  const digest = crypto.createHmac('sha1', key).update(buf).digest();
  const offset = digest[digest.length - 1] & 0x0f;
  const value =
    ((digest[offset] & 0x7f) << 24) |
    ((digest[offset + 1] & 0xff) << 16) |
    ((digest[offset + 2] & 0xff) << 8) |
    (digest[offset + 3] & 0xff);
  return String(value % 1_000_000).padStart(6, '0');
}

export function generateTotp(secret, time = Date.now()) {
  return hotp(secret, Math.floor(time / 1000 / 30));
}

/// Accepts one step of clock drift in either direction, like most apps do.
export function verifyTotp(secret, code, { window = 1, time = Date.now() } = {}) {
  const clean = String(code ?? '').replace(/\s+/g, '');
  if (!/^\d{6}$/.test(clean)) return false;
  const counter = Math.floor(time / 1000 / 30);
  for (let offset = -window; offset <= window; offset++) {
    const expected = hotp(secret, counter + offset);
    if (
      expected.length === clean.length &&
      crypto.timingSafeEqual(Buffer.from(expected), Buffer.from(clean))
    ) {
      return true;
    }
  }
  return false;
}

export function otpauthUrl({ secret, account, issuer = 'Commsuite' }) {
  const label = `${encodeURIComponent(issuer)}:${encodeURIComponent(account)}`;
  const params = new URLSearchParams({
    secret,
    issuer,
    algorithm: 'SHA1',
    digits: '6',
    period: '30',
  });
  return `otpauth://totp/${label}?${params.toString()}`;
}

/// Normalise user input (case, spaces, the visual dash) before hashing.
export function normalizeRecoveryCode(code) {
  return String(code ?? '')
    .toUpperCase()
    .replace(/[^A-Z0-9]/g, '');
}

function randomRecoveryCode() {
  // 8 base32 characters = 40 bits per code.
  return base32Encode(crypto.randomBytes(5)).match(/.{4}/g).join('-');
}

export function generateRecoveryCodes(count = 10) {
  const codes = new Set();
  while (codes.size < count) codes.add(randomRecoveryCode());
  return [...codes];
}
