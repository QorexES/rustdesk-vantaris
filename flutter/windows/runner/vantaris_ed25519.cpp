// Vantaris: verificación Ed25519 (RFC 8032) para los manifiestos de actualización.
// Aritmética adaptada de TweetNaCl (dominio público, Bernstein et al.). Las constantes (d, 2d,
// sqrt(-1) y el punto base) se calculan al arrancar en vez de copiarlas a mano. SHA-512 con BCrypt.
// Probado con los vectores de la RFC 8032 (ver RemoteControl/client-build/actualizaciones.md).

#include "vantaris_ed25519.h"

#include <windows.h>
#include <bcrypt.h>

#include <cstring>
#include <mutex>
#include <vector>

#pragma comment(lib, "bcrypt.lib")

namespace {

typedef long long i64;
typedef unsigned char u8;
typedef i64 gf[16];

gf gf0 = {0}, gf1 = {1}, D, D2, I, BX, BY;

void set(gf r, const gf a) { for (int i = 0; i < 16; i++) r[i] = a[i]; }

void car(gf o) {
  for (int i = 0; i < 16; i++) {
    o[i] += (1LL << 16);
    i64 c = o[i] >> 16;
    o[(i + 1) * (i < 15)] += c - 1 + 37 * (c - 1) * (i == 15);
    o[i] -= c << 16;
  }
}

void sel(gf p, gf q, int b) {
  i64 c = ~(b - 1);
  for (int i = 0; i < 16; i++) {
    i64 t = c & (p[i] ^ q[i]);
    p[i] ^= t;
    q[i] ^= t;
  }
}

void pack25519(u8* o, const gf n) {
  gf m, t;
  set(t, n);
  car(t); car(t); car(t);
  for (int j = 0; j < 2; j++) {
    m[0] = t[0] - 0xffed;
    for (int i = 1; i < 15; i++) {
      m[i] = t[i] - 0xffff - ((m[i - 1] >> 16) & 1);
      m[i - 1] &= 0xffff;
    }
    m[15] = t[15] - 0x7fff - ((m[14] >> 16) & 1);
    int b = (int)((m[15] >> 16) & 1);
    m[14] &= 0xffff;
    sel(t, m, 1 - b);
  }
  for (int i = 0; i < 16; i++) {
    o[2 * i] = (u8)(t[i] & 0xff);
    o[2 * i + 1] = (u8)(t[i] >> 8);
  }
}

bool neq(const gf a, const gf b) {
  u8 c[32], d[32];
  pack25519(c, a);
  pack25519(d, b);
  return memcmp(c, d, 32) != 0;
}

int par(const gf a) {
  u8 d[32];
  pack25519(d, a);
  return d[0] & 1;
}

void unpack25519(gf o, const u8* n) {
  for (int i = 0; i < 16; i++) o[i] = n[2 * i] + ((i64)n[2 * i + 1] << 8);
  o[15] &= 0x7fff;
}

void A(gf o, const gf a, const gf b) { for (int i = 0; i < 16; i++) o[i] = a[i] + b[i]; }
void Z(gf o, const gf a, const gf b) { for (int i = 0; i < 16; i++) o[i] = a[i] - b[i]; }

void M(gf o, const gf a, const gf b) {
  i64 t[31] = {0};
  for (int i = 0; i < 16; i++)
    for (int j = 0; j < 16; j++) t[i + j] += a[i] * b[j];
  for (int i = 0; i < 15; i++) t[i] += 38 * t[i + 16];
  for (int i = 0; i < 16; i++) o[i] = t[i];
  car(o);
  car(o);
}

void S(gf o, const gf a) { M(o, a, a); }

// o = i^e, e en little endian (32 bytes)
void powe(gf o, const gf i, const u8* e) {
  gf c;
  set(c, gf1);
  for (int a = 255; a >= 0; a--) {
    S(c, c);
    if ((e[a / 8] >> (a & 7)) & 1) M(c, c, i);
  }
  set(o, c);
}

void inv(gf o, const gf i) {  // i^(p-2)
  gf c;
  set(c, i);
  for (int a = 253; a >= 0; a--) {
    S(c, c);
    if (a != 2 && a != 4) M(c, c, i);
  }
  set(o, c);
}

void pow2523(gf o, const gf i) {  // i^((p-5)/8)
  gf c;
  set(c, i);
  for (int a = 250; a >= 0; a--) {
    S(c, c);
    if (a != 1) M(c, c, i);
  }
  set(o, c);
}

void add(gf p[4], gf q[4]) {
  gf a, b, c, d, t, e, f, g, h;
  Z(a, p[1], p[0]); Z(t, q[1], q[0]); M(a, a, t);
  A(b, p[0], p[1]); A(t, q[0], q[1]); M(b, b, t);
  M(c, p[3], q[3]); M(c, c, D2);
  M(d, p[2], q[2]); A(d, d, d);
  Z(e, b, a); Z(f, d, c); A(g, d, c); A(h, b, a);
  M(p[0], e, f); M(p[1], h, g); M(p[2], g, f); M(p[3], e, h);
}

void cswap(gf p[4], gf q[4], u8 b) { for (int i = 0; i < 4; i++) sel(p[i], q[i], b); }

void pack(u8* r, gf p[4]) {
  gf tx, ty, zi;
  inv(zi, p[2]);
  M(tx, p[0], zi);
  M(ty, p[1], zi);
  pack25519(r, ty);
  r[31] ^= (u8)(par(tx) << 7);
}

void scalarmult(gf p[4], gf q[4], const u8* s) {
  set(p[0], gf0); set(p[1], gf1); set(p[2], gf1); set(p[3], gf0);
  for (int i = 255; i >= 0; --i) {
    u8 b = (s[i / 8] >> (i & 7)) & 1;
    cswap(p, q, b);
    add(q, p);
    add(p, p);
    cswap(p, q, b);
  }
}

void scalarbase(gf p[4], const u8* s) {
  gf q[4];
  set(q[0], BX); set(q[1], BY); set(q[2], gf1); M(q[3], BX, BY);
  scalarmult(p, q, s);
}

// Decodifica el punto y lo NIEGA (como TweetNaCl): r = -P.
int unpackneg(gf r[4], const u8 p[32]) {
  gf t, chk, num, den, den2, den4, den6;
  set(r[2], gf1);
  unpack25519(r[1], p);
  S(num, r[1]); M(den, num, D); Z(num, num, r[2]); A(den, r[2], den);
  S(den2, den); S(den4, den2); M(den6, den4, den2); M(t, den6, num); M(t, t, den);
  pow2523(t, t); M(t, t, num); M(t, t, den); M(t, t, den); M(r[0], t, den);
  S(chk, r[0]); M(chk, chk, den);
  if (neq(chk, num)) M(r[0], r[0], I);
  S(chk, r[0]); M(chk, chk, den);
  if (neq(chk, num)) return -1;
  if (par(r[0]) == (p[31] >> 7)) Z(r[0], gf0, r[0]);
  M(r[3], r[0], r[1]);
  return 0;
}

const i64 L[32] = {0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58, 0xd6, 0x9c, 0xf7,
                   0xa2, 0xde, 0xf9, 0xde, 0x14, 0,    0,    0,    0,    0,    0,
                   0,    0,    0,    0,    0,    0,    0,    0,    0,    0x10};

void modL(u8* r, i64 x[64]) {
  i64 carry;
  int i, j;
  for (i = 63; i >= 32; --i) {
    carry = 0;
    for (j = i - 32; j < i - 12; ++j) {
      x[j] += carry - 16 * x[i] * L[j - (i - 32)];
      carry = (x[j] + 128) >> 8;
      x[j] -= carry << 8;
    }
    x[j] += carry;
    x[i] = 0;
  }
  carry = 0;
  for (j = 0; j < 32; j++) {
    x[j] += carry - (x[31] >> 4) * L[j];
    carry = x[j] >> 8;
    x[j] &= 255;
  }
  for (j = 0; j < 32; j++) x[j] -= carry * L[j];
  for (i = 0; i < 32; i++) {
    x[i + 1] += x[i] >> 8;
    r[i] = (u8)(x[i] & 255);
  }
}

void reduce(u8* r) {
  i64 x[64];
  for (int i = 0; i < 64; i++) x[i] = (i64)(unsigned long long)r[i];
  for (int i = 0; i < 64; i++) r[i] = 0;
  modL(r, x);
}

bool sha512(const std::vector<u8>& in, u8 out[64]) {
  BCRYPT_ALG_HANDLE alg = nullptr;
  if (BCryptOpenAlgorithmProvider(&alg, BCRYPT_SHA512_ALGORITHM, nullptr, 0) != 0) return false;
  NTSTATUS st = BCryptHash(alg, nullptr, 0, (PUCHAR)in.data(), (ULONG)in.size(), out, 64);
  BCryptCloseAlgorithmProvider(alg, 0);
  return st == 0;
}

std::once_flag g_init;

void init_constants() {
  // d = -121665 / 121666
  gf a = {0}, b = {0}, t;
  a[0] = 121665 & 0xffff; a[1] = 121665 >> 16;
  b[0] = 121666 & 0xffff; b[1] = 121666 >> 16;
  inv(t, b);
  M(t, t, a);
  Z(D, gf0, t);
  A(D2, D, D);
  // sqrt(-1) = 2^((p-1)/4), (p-1)/4 = 2^253 - 5
  u8 e[32];
  memset(e, 0xff, 32);
  e[0] = 0xfb;
  e[31] = 0x1f;
  gf two = {2};
  powe(I, two, e);
  // Punto base: y = 4/5, x par. Se decodifica su codificación estándar (58 66 66 … 66) y se
  // deshace la negación de unpackneg.
  u8 enc[32];
  memset(enc, 0x66, 32);
  enc[0] = 0x58;
  gf q[4];
  unpackneg(q, enc);
  Z(BX, gf0, q[0]);
  set(BY, q[1]);
}

}  // namespace

bool VantarisEd25519Verify(const unsigned char pk[32], const unsigned char* msg, size_t len,
                           const unsigned char sig[64]) {
  std::call_once(g_init, init_constants);
  // S < L (evita firmas maleables)
  for (int i = 31; i >= 0; i--) {
    if (sig[32 + i] < L[i]) break;
    if (sig[32 + i] > L[i]) return false;
    if (i == 0) return false;  // igual a L
  }
  gf p[4], q[4];
  if (unpackneg(q, pk)) return false;
  std::vector<u8> m(64 + len);
  memcpy(m.data(), sig, 32);
  memcpy(m.data() + 32, pk, 32);
  if (len) memcpy(m.data() + 64, msg, len);
  u8 h[64];
  if (!sha512(m, h)) return false;
  reduce(h);
  scalarmult(p, q, h);  // p = -h*A
  scalarbase(q, sig + 32);  // q = S*B
  add(p, q);
  u8 t[32];
  pack(t, p);
  return memcmp(t, sig, 32) == 0;
}
