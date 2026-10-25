// Vantaris: pruebas de lib/vantaris/red.dart que no tocan la red (validación, lectura de respuestas,
// bytes ESC/POS y clasificación). Ejecutar: flutter test test/vantaris_red_test.dart
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_hbb/vantaris/oui.dart';
import 'package:flutter_hbb/vantaris/red.dart';
import 'package:flutter_test/flutter_test.dart';

List<int> tlv(int t, List<int> v) => [t, v.length, ...v];

void main() {
  test('solo IPs privadas y bien escritas', () {
    for (final ok in ['192.168.1.50', '10.0.0.7', '172.16.4.1', '172.31.255.254', '169.254.10.20']) {
      expect(vantarisIpPrivada(ok), isTrue, reason: ok);
    }
    for (final mal in [
      '8.8.8.8', '172.32.0.1', '192.169.1.1', '192.168.1.0', '192.168.1.255', '192.168.1.256',
      '192.168.01.5', '192.168.1', '192.168.1.5;calc', ' 192.168.1.5', '127.0.0.1', 'localhost'
    ]) {
      expect(vantarisIpPrivada(mal), isFalse, reason: mal);
    }
    expect(vantarisRedArgValido('ping', '192.168.1.5'), isTrue);
    expect(vantarisRedArgValido('ping', '1.1.1.1'), isFalse);
    expect(vantarisRedArgValido('red', null), isTrue);
    expect(vantarisRedArgValido('red', '192.168.1.5'), isFalse);
    expect(vantarisRedArgValido('cajonlocal', '2'), isTrue);
    expect(vantarisRedArgValido('cajonlocal', '-1'), isFalse);
  });

  test('salida de ping de Windows (español e inglés) y Android', () {
    const es = 'Respuesta desde 192.168.1.1: bytes=32 tiempo=3ms TTL=64\n'
        'Respuesta desde 192.168.1.1: bytes=32 tiempo<1m TTL=64\n';
    expect(vantarisLeerPing(es), [(3.0, 64), (1.0, 64)]);
    const en = 'Reply from 192.168.1.20: bytes=32 time=12ms TTL=128\n';
    expect(vantarisLeerPing(en), [(12.0, 128)]);
    const android = '64 bytes from 192.168.1.1: icmp_seq=1 ttl=64 time=4.21 ms\n';
    expect(vantarisLeerPing(android), [(4.21, 64)]);
    expect(vantarisLeerPing('Tiempo de espera agotado para esta solicitud.'), isEmpty);
  });

  test('bytes ESC/POS', () {
    expect(vantarisPulsoCajon(0), [0x1B, 0x70, 0x00, 0x19, 0xFA]);
    expect(vantarisPulsoCajon(1), [0x1B, 0x70, 0x01, 0x19, 0xFA]);
    final t = vantarisTicketPrueba(destino: 'Impresión cocina', ahora: DateTime(2026, 10, 25, 9, 5));
    expect(t.sublist(0, 2), [0x1B, 0x40]);
    expect(t.sublist(t.length - 4), [0x1D, 0x56, 0x42, 0x00]);
    expect(t.every((b) => b < 0x80), isTrue, reason: 'solo ASCII');
    final texto = latin1.decode(t);
    expect(texto, contains('Impresora: Impresion cocina'));
    expect(texto, contains('25/10/2026 09:05'));
  });

  test('petición y respuesta NetBIOS', () {
    final p = vantarisNbstatPeticion(0x1234);
    expect(p.length, 50);
    expect(p.sublist(0, 2), [0x12, 0x34]);
    final nombre = latin1.encode('CAJA-BARRA     ');
    final resp = Uint8List.fromList([
      0x12, 0x34, 0x84, 0x00, 0, 0, 0, 1, 0, 0, 0, 0,
      0x20, ...List.filled(32, 0x41), 0x00,
      0x00, 0x21, 0x00, 0x01, 0, 0, 0, 0, 0x00, 0x41,
      2,
      ...latin1.encode('WORKGROUP      '), 0x00, 0x84, 0x00, // grupo: no vale
      ...nombre, 0x00, 0x04, 0x00,
      0x00, 0x26, 0x18, 0xAA, 0xBB, 0xCC,
    ]);
    expect(vantarisLeerNbstat(resp), ('CAJA-BARRA', '00-26-18-aa-bb-cc'));
  });

  test('petición y respuesta SNMP', () {
    final p = vantarisSnmpPeticion(7, [
      [0x2B, 6, 1, 2, 1, 1, 1, 0]
    ]);
    expect(p.first, 0x30);
    expect(latin1.decode(p), contains('public'));
    final resp = Uint8List.fromList(tlv(0x30, [
      ...tlv(0x02, [0]),
      ...tlv(0x04, ascii.encode('public')),
      ...tlv(0xA2, [
        ...tlv(0x02, [0, 7]),
        ...tlv(0x02, [0]),
        ...tlv(0x02, [0]),
        ...tlv(0x30, [
          ...tlv(0x30, [...tlv(0x06, [0x2B, 6, 1, 2, 1, 1, 1, 0]), ...tlv(0x04, ascii.encode('EPSON TM-T20II'))]),
        ]),
      ]),
    ]));
    expect(vantarisLeerSnmp(resp), ['EPSON TM-T20II']);
    expect(vantarisLeerSnmp(Uint8List.fromList([0x30, 0x05, 0x02])), isEmpty);
  });

  test('fabricante por MAC', () {
    expect(vantarisFabricanteMac('00-26-AB-11-22-33'), 'Epson');
    expect(vantarisFabricanteMac('zz'), isNull);
  });

  test('clasificación', () {
    expect(vantarisClasificar(puertos: {9100, 80}, fabricante: 'Epson')['tipo'], 'impresora');
    expect(vantarisClasificar(puertos: {80, 443}, puertaEnlace: true)['tipo'], 'router');
    final pc = vantarisClasificar(puertos: {445, 139}, netbios: 'CAJA-BARRA', ttl: 128);
    expect(pc['tipo'], 'ordenador');
    expect(pc['so'], 'Windows (estimado)');
    expect(vantarisClasificar(puertos: {}, fabricante: 'Sunmi')['tipo'], 'TPV / terminal Android');
    expect(vantarisClasificar(puertos: {62078})['so'], 'iOS');
    final imp = vantarisClasificar(puertos: {9100}, snmp: 'EPSON Built-in 11b/g/n Print Server', modeloSnmp: 'TM-T20III');
    expect(imp['modelo'], 'TM-T20III');
  });
}
