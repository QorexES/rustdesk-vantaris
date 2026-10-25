// Vantaris: manifiesto firmado de actualizaciones.
//
// En el servidor, <base>/<canal>/<plataforma>-<variante>.json es un «sobre»:
//   {"formato": 1, "clave": "<id de clave>", "carga": "<base64 de la carga>", "firma": "<base64>"}
// La firma Ed25519 va sobre los bytes EXACTOS de la carga (así no hay que canonicalizar JSON).
// La carga, ya verificada, es:
//   {"formato": 1, "producto": "vantaris", "variante": "soporte", "plataforma": "windows",
//    "canal": "estable", "version": "1.4.9", "build": 26092618, "publicado": "2026-09-26T18:00:00Z",
//    "notas": "…", "paquetes": {"x64": {"url": "…", "sha256": "…", "tamano": 123}}}
// Lo genera y firma RemoteControl/client-build/publicar-actualizacion.sh. El mismo formato lo lee
// el actualizador del runner de Windows (windows/runner/vantaris_update.cpp).

import 'dart:convert';

import 'ed25519.dart';

class VantarisPackage {
  final Uri url;
  final String sha256; // hex en minúsculas
  final int size;
  VantarisPackage(this.url, this.sha256, this.size);
}

class VantarisManifest {
  final String variante, plataforma, canal, version, notas, publicado;
  final int build;
  final Map<String, VantarisPackage> paquetes;
  VantarisManifest(this.variante, this.plataforma, this.canal, this.version,
      this.build, this.notas, this.publicado, this.paquetes);
}

class VantarisManifestError implements Exception {
  final String motivo;
  VantarisManifestError(this.motivo);
  @override
  String toString() => motivo;
}

/// «id=base64;id2=base64» → {id: bytes}. Las claves públicas las mete el build (--dart-define).
Map<String, List<int>> vantarisParseKeys(String s) {
  final r = <String, List<int>>{};
  for (final part in s.split(';')) {
    final i = part.indexOf('=');
    if (i <= 0) continue;
    try {
      final k = base64.decode(part.substring(i + 1).trim());
      if (k.length == 32) r[part.substring(0, i).trim()] = k;
    } catch (_) {}
  }
  return r;
}

/// Verifica el sobre y devuelve la carga. Lanza [VantarisManifestError] si algo no cuadra:
/// firma mala o de otra clave, manifiesto de otra variante/plataforma/canal, campos que faltan.
VantarisManifest vantarisVerifyManifest(
  String body, {
  required Uri manifestUrl,
  required Map<String, List<int>> keys,
  required String variante,
  required String plataforma,
  required String canal,
}) {
  Map<String, dynamic> env;
  try {
    env = jsonDecode(body) as Map<String, dynamic>;
  } catch (_) {
    throw VantarisManifestError('el manifiesto no es JSON');
  }
  if (env['formato'] != 1) throw VantarisManifestError('formato desconocido');
  final key = keys[env['clave']];
  if (key == null) {
    throw VantarisManifestError('clave desconocida: ${env['clave']}');
  }
  List<int> carga, firma;
  try {
    carga = base64.decode(env['carga'] as String);
    firma = base64.decode(env['firma'] as String);
  } catch (_) {
    throw VantarisManifestError('sobre mal formado');
  }
  if (!ed25519Verify(key, carga, firma)) {
    throw VantarisManifestError('FIRMA NO VÁLIDA');
  }
  Map<String, dynamic> m;
  try {
    m = jsonDecode(utf8.decode(carga)) as Map<String, dynamic>;
  } catch (_) {
    throw VantarisManifestError('carga firmada ilegible');
  }
  if (m['formato'] != 1 || m['producto'] != 'vantaris') {
    throw VantarisManifestError('carga de otro producto o formato');
  }
  // Un manifiesto bien firmado pero de otra variante/plataforma/canal no vale: evita que se sirva
  // el de Android a Windows, o el de pruebas a los equipos de estable.
  for (final e in {
    'variante': variante,
    'plataforma': plataforma,
    'canal': canal
  }.entries) {
    if (m[e.key] != e.value) {
      throw VantarisManifestError(
          '${e.key} no coincide (${m[e.key]} ≠ ${e.value})');
    }
  }
  final build = m['build'];
  if (build is! int || build <= 0) throw VantarisManifestError('build no válido');
  final paquetes = <String, VantarisPackage>{};
  final raw = m['paquetes'];
  if (raw is! Map) throw VantarisManifestError('sin paquetes');
  raw.forEach((arch, v) {
    if (v is Map &&
        v['url'] is String &&
        v['sha256'] is String &&
        v['tamano'] is int &&
        RegExp(r'^[0-9a-f]{64}$').hasMatch(v['sha256'] as String)) {
      paquetes[arch as String] = VantarisPackage(
          manifestUrl.resolve(v['url'] as String), v['sha256'] as String, v['tamano'] as int);
    }
  });
  if (paquetes.isEmpty) throw VantarisManifestError('sin paquetes válidos');
  return VantarisManifest(
    variante,
    plataforma,
    canal,
    (m['version'] ?? '').toString(),
    build,
    (m['notas'] ?? '').toString(),
    (m['publicado'] ?? '').toString(),
    paquetes,
  );
}
