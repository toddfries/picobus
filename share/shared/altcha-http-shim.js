/**
 * ALTCHA widget needs crypto.subtle.digest(SHA-256). That exists only in a
 * secure context (HTTPS or localhost). The LAN demo is http://100.64.2.3/, so:
 *  - disable Workers (their blob realm has no subtle and never sees this file)
 *  - polyfill crypto.subtle.digest for SHA-256 on the window
 */
(function () {
  'use strict';
  var secure = false;
  try {
    secure = !!(window.isSecureContext && window.crypto && crypto.subtle && crypto.subtle.digest);
  } catch (e) {}
  if (secure) return;

  window.Worker = function () {
    throw new Error('ALTCHA workers need HTTPS; using in-page SHA-256');
  };

  function rotr(x, n) { return (x >>> n) | (x << (32 - n)); }
  function sha256bytes(bytes) {
    var K = [
      0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
      0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
      0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
      0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
      0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
      0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
      0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
      0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
    ];
    var h0=0x6a09e667,h1=0xbb67ae85,h2=0x3c6ef372,h3=0xa54ff53a,h4=0x510e527f,h5=0x9b05688c,h6=0x1f83d9ab,h7=0x5be0cd19;
    var len = bytes.length;
    var bit = len * 8;
    var pad = ((len + 9 + 63) & ~63);
    var buf = new Uint8Array(pad);
    buf.set(bytes);
    buf[len] = 0x80;
    var dv = new DataView(buf.buffer);
    dv.setUint32(pad - 4, bit >>> 0);
    var W = new Uint32Array(64);
    for (var off = 0; off < pad; off += 64) {
      var i, a=h0,b=h1,c=h2,d=h3,e=h4,f=h5,g=h6,h=h7, t1, t2, s0, s1, ch, maj;
      for (i = 0; i < 16; i++) W[i] = dv.getUint32(off + i * 4);
      for (i = 16; i < 64; i++) {
        s0 = rotr(W[i-15],7) ^ rotr(W[i-15],18) ^ (W[i-15]>>>3);
        s1 = rotr(W[i-2],17) ^ rotr(W[i-2],19) ^ (W[i-2]>>>10);
        W[i] = (W[i-16] + s0 + W[i-7] + s1) >>> 0;
      }
      for (i = 0; i < 64; i++) {
        s1 = rotr(e,6) ^ rotr(e,11) ^ rotr(e,25);
        ch = (e & f) ^ (~e & g);
        t1 = (h + s1 + ch + K[i] + W[i]) >>> 0;
        s0 = rotr(a,2) ^ rotr(a,13) ^ rotr(a,22);
        maj = (a & b) ^ (a & c) ^ (b & c);
        t2 = (s0 + maj) >>> 0;
        h=g; g=f; f=e; e=(d + t1) >>> 0; d=c; c=b; b=a; a=(t1 + t2) >>> 0;
      }
      h0=(h0+a)>>>0; h1=(h1+b)>>>0; h2=(h2+c)>>>0; h3=(h3+d)>>>0;
      h4=(h4+e)>>>0; h5=(h5+f)>>>0; h6=(h6+g)>>>0; h7=(h7+h)>>>0;
    }
    var out = new Uint8Array(32);
    var o = new DataView(out.buffer);
    o.setUint32(0,h0); o.setUint32(4,h1); o.setUint32(8,h2); o.setUint32(12,h3);
    o.setUint32(16,h4); o.setUint32(20,h5); o.setUint32(24,h6); o.setUint32(28,h7);
    return out.buffer;
  }

  var cryptoObj = window.crypto || (window.crypto = {});
  var subtle = cryptoObj.subtle || (cryptoObj.subtle = {});
  var orig = subtle.digest && subtle.digest.bind(subtle);
  subtle.digest = function (algo, data) {
    var name = (typeof algo === 'string' ? algo : (algo && algo.name) || '').toUpperCase();
    if (name !== 'SHA-256') {
      if (orig) return orig(algo, data);
      return Promise.reject(new Error('only SHA-256 polyfilled'));
    }
    var bytes = data instanceof ArrayBuffer ? new Uint8Array(data)
      : data instanceof Uint8Array ? data : new Uint8Array(data);
    try {
      return Promise.resolve(sha256bytes(bytes));
    } catch (e) {
      return Promise.reject(e);
    }
  };
})();
