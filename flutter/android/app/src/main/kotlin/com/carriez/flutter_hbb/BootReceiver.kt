package com.carriez.flutter_hbb

import android.Manifest.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS
import android.Manifest.permission.SYSTEM_ALERT_WINDOW
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import android.widget.Toast
import com.hjq.permissions.XXPermissions
import io.flutter.embedding.android.FlutterActivity

const val DEBUG_BOOT_COMPLETED = "com.carriez.flutter_hbb.DEBUG_BOOT_COMPLETED"
// Vantaris: el launcher (Vantaris Inicio) lo manda al arrancar, para que una app recién instalada
// que nadie ha abierto (Landi la instala sola) arranque y se dé de alta sin que nadie la toque.
const val VANTARIS_ARRANCAR = "es.vantaris.soporte.ARRANCAR"

class BootReceiver : BroadcastReceiver() {
    private val logTag = "tagBootReceiver"

    override fun onReceive(context: Context, intent: Intent) {
        Log.d(logTag, "onReceive ${intent.action}")

        // Vantaris: también tras actualizar (MY_PACKAGE_REPLACED). Una pantalla en el techo no tiene a
        // nadie que vuelva a pulsar «Iniciar servicio»; Android permite arrancar el servicio desde aquí.
        if (Intent.ACTION_BOOT_COMPLETED == intent.action || DEBUG_BOOT_COMPLETED == intent.action ||
            Intent.ACTION_MY_PACKAGE_REPLACED == intent.action || VANTARIS_ARRANCAR == intent.action) {
            VantarisA11y.ensureEnabled(context)
            if (VantarisAlta.dadoDeBaja(context)) {
                Log.d(logTag, "equipo dado de baja a propósito: no se arranca")
                return
            }
            val prefs = context.getSharedPreferences(KEY_SHARED_PREFERENCES, FlutterActivity.MODE_PRIVATE)
            val conAlta = prefs.getBoolean(KEY_START_ON_BOOT_OPT, false)
            // Vantaris: SIN alta también se arranca. El servicio registra el ID en el servidor y Dart
            // (sin pantalla) hace el alta automática; así un equipo actualizado o instalado por Landi
            // se da de alta solo, sin que nadie vaya a tocarlo. Ver vantaris/alta.dart.
            if (conAlta &&
                !XXPermissions.isGranted(context, REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, SYSTEM_ALERT_WINDOW)) {
                Log.d(logTag, "REQUEST_IGNORE_BATTERY_OPTIMIZATIONS or SYSTEM_ALERT_WINDOW is not granted")
            }
            VantarisEngine.ensureRunning(context)
            if (MainService.isStart) {
                Log.d(logTag, "el servicio ya estaba en marcha")
                return
            }

            val it = Intent(context, MainService::class.java).apply {
                action = ACT_INIT_MEDIA_PROJECTION_AND_SERVICE
                putExtra(EXT_INIT_FROM_BOOT, true)
            }
            Toast.makeText(context, "Vantaris Soporte activo", Toast.LENGTH_LONG).show()
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(it)
                } else {
                    context.startService(it)
                }
            } catch (e: Exception) {
                // Android 12+ no deja arrancar un servicio en primer plano desde segundo plano salvo
                // excepciones (arranque, actualización, permiso de ventana flotante).
                Log.w(logTag, "no se pudo arrancar el servicio: $e")
            }
        }
    }
}
