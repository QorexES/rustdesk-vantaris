package com.carriez.flutter_hbb

// Vantaris: instala una actualización de la propia app con PackageInstaller.
//
// El APK ya viene descargado y comprobado (firma del manifiesto + SHA-256) desde Dart
// (lib/vantaris/update/updater.dart). Aquí solo se entrega a Android, que además exige que el APK
// esté firmado con el mismo certificado que la app instalada y que el versionCode no baje.
//
// Sin root ni Device Owner, Android SIEMPRE pide confirmación al usuario (y la primera vez, el permiso
// «Instalar aplicaciones desconocidas» para esta app). Si los equipos fueran dedicados y la app
// estuviera como Device Owner, el mismo commit instalaría sin preguntar (ver actualizaciones.md).

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log
import android.widget.Toast
import java.io.File

object VantarisUpdater {
    const val ACTION = "es.vantaris.ACTUALIZACION_ESTADO"
    private const val TAG = "VantarisUpdater"

    /** Devuelve "ok" (el sistema mostrará su pantalla de confirmación), "permiso" o "error: …". */
    fun install(activity: Activity, path: String): String {
        // Versión Google Play: las actualizaciones las da Play (y no hay permiso para instalar).
        if (BuildConfig.VANTARIS_PLAY) return "error: en la versión de Google Play se actualiza desde la tienda"
        val apk = File(path)
        if (!apk.isFile) return "error: no está el APK"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !activity.packageManager.canRequestPackageInstalls()
        ) {
            activity.startActivity(
                Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:" + activity.packageName)
                )
            )
            return "permiso"
        }
        return try {
            val installer = activity.packageManager.packageInstaller
            val params =
                PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
            params.setAppPackageName(activity.packageName) // solo se acepta un APK de esta misma app
            val id = installer.createSession(params)
            installer.openSession(id).use { session ->
                apk.inputStream().use { input ->
                    session.openWrite("vantaris.apk", 0, apk.length()).use { out ->
                        input.copyTo(out)
                        session.fsync(out)
                    }
                }
                val intent = Intent(activity, VantarisUpdateReceiver::class.java).setAction(ACTION)
                var flags = PendingIntent.FLAG_UPDATE_CURRENT
                // El sistema rellena el estado en el intent: tiene que ser mutable (Android 12+).
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) flags = flags or PendingIntent.FLAG_MUTABLE
                val pending = PendingIntent.getBroadcast(activity, id, intent, flags)
                session.commit(pending.intentSender)
            }
            "ok"
        } catch (e: Exception) {
            Log.e(TAG, "install", e)
            "error: ${e.message}"
        }
    }
}

class VantarisUpdateReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, -999)
        when (status) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                @Suppress("DEPRECATION")
                val confirm = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
                if (confirm != null) {
                    confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    context.startActivity(confirm)
                }
            }
            PackageInstaller.STATUS_SUCCESS -> Log.i("VantarisUpdater", "actualizada")
            else -> {
                val msg = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE) ?: "$status"
                Log.w("VantarisUpdater", "no se instaló: $msg")
                if (status != PackageInstaller.STATUS_FAILURE_ABORTED) {
                    Toast.makeText(context, "Vantaris: no se pudo actualizar ($msg)", Toast.LENGTH_LONG).show()
                }
            }
        }
    }
}
