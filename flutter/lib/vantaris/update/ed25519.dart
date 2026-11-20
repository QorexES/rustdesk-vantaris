// Vantaris: firmas Ed25519 (RFC 8032) en Dart puro: verificar los manifiestos de actualización y
// FIRMAR la prueba del alta automática (vantaris/acceso.dart, con la clave del propio equipo). No hace
// falta que sea rápido (una firma de vez en cuando) ni de tiempo constante: se firma una vez, en el
// propio equipo y sin nadie que mida tiempos. Sigue la implementación de
// referencia en Python de la RFC 8032 §6. Probado con los vectores de la RFC en
// test/vantaris_update_test.dart.

import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha512;

final BigInt _p = (BigInt.one << 255) - BigInt.from(19);
final BigInt _q = (BigInt.one << 252) +
    BigInt.parse('27742317777372353535851937790883648493');
final BigInt _d = (BigInt.from(-121665) * _inv(BigInt.from(121666))) % _p;
final BigInt _sqrtM1 = BigInt.two.modPow((_p - BigInt.one) >> 2, _p);

BigInt _inv(BigInt x) => x.modPow(_p - BigInt.two, _p);

// Punto en coordenadas extendidas (X, Y, Z, T), x = X/Z, y = Y/Z, x*y = T/Z.
class _P {
  final BigInt x, y, z, t;
  const _P(this.x, this.y, this.z, this.t);
}

_P _add(_P a, _P b) {
  final aa = ((a.y - a.x) * (b.y - b.x)) % _p;
  final bb = ((a.y + a.x) * (b.y + b.x)) % _p;
  final cc = (BigInt.two * a.t * b.t * _d) % _p;
  final dd = (BigInt.two * a.z * b.z) % _p;
  final e = bb - aa, f = dd - cc, g = dd + cc, h = bb + aa;
  return _P((e * f) % _p, (g * h) % _p, (f * g) % _p, (e * h) % _p);
}

_P _mul(BigInt s, _P p) {
  var q = _P(BigInt.zero, BigInt.one, BigInt.one, BigInt.zero);
  while (s > BigInt.zero) {
    if (s.isOdd) q = _add(q, p);
    p = _add(p, p);
    s = s >> 1;
  }
  return q;
}

bool _equal(_P a, _P b) =>
    (a.x * b.z - b.x * a.z) % _p == BigInt.zero &&
    (a.y * b.z - b.y * a.z) % _p == BigInt.zero;

BigInt _le(List<int> b) {
  var r = BigInt.zero;
  for (var i = b.length - 1; i >= 0; i--) {
    r = (r << 8) | BigInt.from(b[i]);
  }
  return r;
}

BigInt? _recoverX(BigInt y, int sign) {
  if (y >= _p) return null;
  final x2 = ((y * y - BigInt.one) * _inv(_d * y * y + BigInt.one)) % _p;
  if (x2 == BigInt.zero) return sign == 1 ? null : BigInt.zero;
  var x = x2.modPow((_p + BigInt.from(3)) >> 3, _p);
  if ((x * x - x2) % _p != BigInt.zero) x = (x * _sqrtM1) % _p;
  if ((x * x - x2) % _p != BigInt.zero) return null;
  if ((x.isOdd ? 1 : 0) != sign) x = _p - x;
  return x;
}

_P? _decompress(List<int> s) {
  if (s.length != 32) return null;
  var y = _le(s);
  final sign = (y >> 255).toInt() & 1;
  y = y & ((BigInt.one << 255) - BigInt.one);
  final x = _recoverX(y, sign);
  if (x == null) return null;
  return _P(x, y, BigInt.one, (x * y) % _p);
}

final _P _g = () {
  final y = (BigInt.from(4) * _inv(BigInt.from(5))) % _p;
  final x = _recoverX(y, 0)!;
  return _P(x, y, BigInt.one, (x * y) % _p);
}();

/// true si [signature] (64 bytes) es una firma Ed25519 válida de [message] con [publicKey] (32 bytes).
bool ed25519Verify(List<int> publicKey, List<int> message, List<int> signature) {
  if (publicKey.length != 32 || signature.length != 64) return false;
  final a = _decompress(publicKey);
  if (a == null) return false;
  final rs = signature.sublist(0, 32);
  final r = _decompress(rs);
  if (r == null) return false;
  final s = _le(signature.sublist(32));
  if (s >= _q) return false;
  final h = _le(sha512
          .convert(Uint8List.fromList([...rs, ...publicKey, ...message]))
          .bytes) %
      _q;
  return _equal(_mul(s, _g), _add(r, _mul(h, a)));
}

List<int> _le32(BigInt n) => List<int>.generate(32, (i) => ((n >> (8 * i)) & BigInt.from(255)).toInt());

List<int> _compress(_P p) {
  final zi = _inv(p.z);
  final x = (p.x * zi) % _p, y = (p.y * zi) % _p;
  return _le32(y | ((x & BigInt.one) << 255));
}

/// Escalar «a» y prefijo de la clave a partir de la semilla de 32 bytes (RFC 8032 §5.1.5).
(BigInt, List<int>) _expandir(List<int> seed) {
  final h = sha512.convert(seed).bytes;
  var a = _le(h.sublist(0, 32));
  a &= (BigInt.one << 254) - BigInt.from(8);
  a |= BigInt.one << 254;
  return (a, h.sublist(32));
}

/// Clave pública (32 bytes) de la semilla [seed] (los 32 primeros bytes de la clave secreta de libsodium).
Uint8List ed25519PublicKey(List<int> seed) =>
    Uint8List.fromList(_compress(_mul(_expandir(seed).$1, _g)));

/// Firma Ed25519 (64 bytes) de [message] con la semilla [seed] de 32 bytes.
Uint8List ed25519Sign(List<int> seed, List<int> message) {
  if (seed.length != 32) throw ArgumentError('semilla de 32 bytes');
  final (a, prefijo) = _expandir(seed);
  final pub = _compress(_mul(a, _g));
  final r = _le(sha512.convert([...prefijo, ...message]).bytes) % _q;
  final rr = _compress(_mul(r, _g));
  final k = _le(sha512.convert([...rr, ...pub, ...message]).bytes) % _q;
  final s = (r + k * a) % _q;
  return Uint8List.fromList([...rr, ..._le32(s)]);
}
