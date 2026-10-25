// Vantaris: pruebas del verificador Ed25519 y del manifiesto firmado de actualizaciones.
//   flutter test test/vantaris_update_test.dart
import 'dart:convert';

import 'package:flutter_hbb/vantaris/update/ed25519.dart';
import 'package:flutter_hbb/vantaris/update/manifest.dart';
import 'package:flutter_test/flutter_test.dart';

List<int> hex(String s) =>
    [for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)];

// Sobre firmado con la clave de PRUEBAS «pruebas-2026-09» (publicar-actualizacion.sh).
const _pub = 'Ncdm3VDAF76qSBvwXpPdwE7HwUiJD3rpuRJl1rQdjv0=';
const _sobre =
    '{"formato": 1, "clave": "pruebas-2026-09", "carga": "eyJmb3JtYXRvIjogMSwgInByb2R1Y3RvIjogInZhbnRhcmlzIiwgInZhcmlhbnRlIjogInRlY25pY28iLCAicGxhdGFmb3JtYSI6ICJ3aW5kb3dzIiwgImNhbmFsIjogImVzdGFibGUiLCAidmVyc2lvbiI6ICIxLjQuOSIsICJidWlsZCI6IDk5MDAwMDAxLCAicHVibGljYWRvIjogIjIwMjYtMDktMjZUMDA6MDA6MDBaIiwgIm5vdGFzIjogInBydWViYSIsICJwYXF1ZXRlcyI6IHsieDY0IjogeyJ1cmwiOiAicGFxdWV0ZXMveC56aXAiLCAic2hhMjU2IjogIjAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAiLCAidGFtYW5vIjogMTB9fX0=", "firma": "56g8Jg0KURDDb+x5d2k7OT0hJsJuhNR6EmR3gwV3OvmH/YdGzjaTGixHEnOBwO8ts1yPp4BK1N7oXCUkmT/rCA=="}';

void main() {
  group('Ed25519 (vectores de la RFC 8032 §7.1)', () {
    final vectors = [
      [
        'd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a',
        '',
        'e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b'
      ],
      [
        '3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c',
        '72',
        '92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00'
      ],
      [
        'fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025',
        'af82',
        '6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a'
      ],
    ];
    for (final v in vectors) {
      test('válida: mensaje "${v[1]}"', () {
        expect(ed25519Verify(hex(v[0]), hex(v[1]), hex(v[2])), isTrue);
      });
      test('rechaza firma con un bit cambiado: "${v[1]}"', () {
        final sig = hex(v[2]);
        sig[5] ^= 1;
        expect(ed25519Verify(hex(v[0]), hex(v[1]), sig), isFalse);
      });
      test('rechaza mensaje cambiado: "${v[1]}"', () {
        expect(ed25519Verify(hex(v[0]), [...hex(v[1]), 0], hex(v[2])), isFalse);
      });
    }
  });

  group('Manifiesto', () {
    final keys = vantarisParseKeys('pruebas-2026-09=$_pub');
    final url = Uri.parse('http://127.0.0.1:8765/estable/windows-tecnico.json');
    VantarisManifest verify(String body,
            {String variante = 'tecnico', String canal = 'estable'}) =>
        vantarisVerifyManifest(body,
            manifestUrl: url,
            keys: keys,
            variante: variante,
            plataforma: 'windows',
            canal: canal);

    test('bueno: se acepta y resuelve la URL del paquete', () {
      final m = verify(_sobre);
      expect(m.build, 99000001);
      expect(m.paquetes['x64']!.url.toString(),
          'http://127.0.0.1:8765/estable/paquetes/x.zip');
    });
    test('carga cambiada (otro build) con la firma vieja: se rechaza', () {
      final env = jsonDecode(_sobre) as Map<String, dynamic>;
      final carga = utf8.decode(base64.decode(env['carga']));
      env['carga'] = base64.encode(utf8.encode(carga.replaceAll('99000001', '99000002')));
      expect(() => verify(jsonEncode(env)), throwsA(isA<VantarisManifestError>()));
    });
    test('firma mala: se rechaza', () {
      final env = jsonDecode(_sobre) as Map<String, dynamic>;
      final f = base64.decode(env['firma']);
      f[0] ^= 0x80;
      env['firma'] = base64.encode(f);
      expect(() => verify(jsonEncode(env)), throwsA(isA<VantarisManifestError>()));
    });
    test('clave desconocida: se rechaza', () {
      expect(
          () => vantarisVerifyManifest(_sobre,
              manifestUrl: url,
              keys: vantarisParseKeys('otra=$_pub'),
              variante: 'tecnico',
              plataforma: 'windows',
              canal: 'estable'),
          throwsA(isA<VantarisManifestError>()));
    });
    test('bien firmado pero de otra variante o canal: se rechaza', () {
      expect(() => verify(_sobre, variante: 'soporte'),
          throwsA(isA<VantarisManifestError>()));
      expect(() => verify(_sobre, canal: 'pruebas'),
          throwsA(isA<VantarisManifestError>()));
    });
  });
}
