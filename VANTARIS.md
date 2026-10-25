# Vantaris Soporte — código fuente

Este repositorio contiene el código fuente completo de **Vantaris Soporte** y **Vantaris Técnico**,
las aplicaciones de asistencia remota de Vantaris (Sevilla, España). Son una versión modificada de
[RustDesk](https://github.com/rustdesk/rustdesk) y se distribuyen bajo la misma licencia,
**GNU Affero General Public License v3.0** (ver [`LICENCE`](LICENCE)).

- Proyecto original: https://github.com/rustdesk/rustdesk — © Purslane Ltd. y colaboradores de RustDesk.
- Base de esta versión: RustDesk 1.5.0 (commit upstream `fada664df`).
- Todo lo añadido por Vantaris lleva el prefijo «Vantaris» en los commits y vive sobre todo en
  `flutter/lib/vantaris/`, `flutter/android/app/src/main/kotlin/com/carriez/flutter_hbb/Vantaris*.kt`
  y `flutter/windows/runner/vantaris_*`.

## Qué cambia respecto a RustDesk

Marca e iconos de Vantaris, pizarra y láser sobre la pantalla del equipo asistido, modo «no tocar»,
captura de la pantalla remota, videollamada técnico-cliente (WebRTC), grabación para el resumen de la
asistencia, diagnóstico del equipo, respuestas rápidas en el chat, alta del equipo para el acceso
desatendido y actualizaciones propias firmadas con Ed25519.

## Lo que NO está en el repositorio

La configuración de cada instalación no es código y se inyecta al compilar:

| Dato | Cómo se pasa |
|------|--------------|
| Configuración del servidor (RustDesk Server Pro, firmada) | `VANTARIS_CUSTOM_CLIENT_FILE` (Android) / `--dart-define=VANTARIS_CUSTOM_CLIENT` / `custom.txt` junto al `.exe` |
| Servidor TURN de la videollamada | `--dart-define=VANTARIS_TURN` (solo Técnico) |
| Servicio de resumen | `--dart-define=VANTARIS_RESUMEN_URL` |
| Claves públicas de actualización | `--dart-define=VANTARIS_UPDATE_KEYS` |
| Firma de Android | `flutter/android/key.properties` + keystore (sin ellos se firma con la clave de depuración) |

Sin esos datos el programa compila igual y se conecta al servidor que se configure en *Ajustes → Red*.

## Compilar

Requisitos y pasos: los mismos que RustDesk 1.5.0 (ver [`README.md`](README.md) y
`.github/workflows/flutter-build.yml`). Variables propias:

```bash
# Android (APK de «Vantaris Soporte»)
export VANTARIS_APP_ID=es.vantaris.soporte VANTARIS_APP_LABEL="Vantaris Soporte"
export VANTARIS_CUSTOM_CLIENT_FILE=/ruta/a/config-firmada.txt   # opcional
cd flutter && flutter build apk --release --target-platform android-arm64,android-arm   --split-per-abi --dart-define=VANTARIS_VARIANT=soporte --dart-define=VANTARIS_VARIANTE=soporte
```

## Marcas

La licencia AGPL cubre el código. El nombre «Vantaris», el pulpo y los logotipos son marcas de
Vantaris y no se ceden (AGPL §7 e): si redistribuyes una versión modificada, quita la marca.
«RustDesk» es marca de sus titulares.

## Contacto

Peticiones del código fuente correspondiente a una versión concreta publicada: soporte@vantaris.es
