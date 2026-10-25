package com.carriez.flutter_hbb

// Vantaris: «alta del equipo» para el acceso desatendido (el técnico entra con la contraseña del
// equipo, sin que nadie pulse «Aceptar»).
//
// Dos caminos, los dos acaban en flutter/lib/vantaris/alta.dart, que es quien fija de verdad la
// contraseña permanente y el modo «solo contraseña» en la config de RustDesk:
//
// 1. En pantalla: tarjeta «Dar de alta (instalador)» de la pestaña Compartir pantalla.
// 2. Por cable, desde scripts/provisionar-android.ps1 (repo RemoteControl):
//      adb shell content call --uri content://<paquete>.vantaris.alta --method alta --arg <contraseña>
//    El proveedor SOLO acepta llamadas de adb (uid shell/root): ninguna app del equipo puede
//    cambiar la contraseña por aquí. Deja la contraseña pendiente en las preferencias privadas de
//    la app y activa «Iniciar al arrancar»; al abrir la app, Dart la aplica y la borra en el acto.
//      --method estado  ->  "hecha" | "pendiente" | "baja-pendiente" | "sin-alta"
//      --method baja    ->  al abrir la app se quita el alta (vuelve a pedir «Aceptar»; equipo retirado)

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.os.Binder
import android.os.Bundle
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import org.json.JSONObject

object VantarisAlta {
    private const val TAG = "VantarisAlta"
    private const val KEY_PENDIENTE = "VANTARIS_ALTA_PENDIENTE"
    private const val KEY_HECHA = "VANTARIS_ALTA_HECHA"
    private const val KEY_BAJA = "VANTARIS_BAJA_PENDIENTE"
    private val VALIDA = Regex("^[\\x21-\\x7E]{8,64}$") // ASCII visible, sin espacios

    private fun prefs(ctx: Context) =
        ctx.getSharedPreferences(KEY_SHARED_PREFERENCES, FlutterActivity.MODE_PRIVATE)

    fun esValida(pwd: String) = VALIDA.matches(pwd)

    /** Método "vantaris_alta" del canal de Flutter. Devuelve JSON. */
    fun handle(ctx: Context, args: String): String {
        val a = JSONObject(args)
        val p = prefs(ctx)
        return when (a.optString("op")) {
            // Contraseña que ha dejado el script por cable (o "" si no hay).
            "pendiente" -> JSONObject().put("password", p.getString(KEY_PENDIENTE, "") ?: "")
                .put("baja", p.getBoolean(KEY_BAJA, false)).toString()
            // Dart ya la ha aplicado: se borra y se recuerda que el equipo está dado de alta.
            "hecha" -> {
                p.edit().remove(KEY_PENDIENTE).putBoolean(KEY_HECHA, true)
                    .putBoolean(KEY_START_ON_BOOT_OPT, a.optBoolean("arranque", true)).apply()
                Log.i(TAG, "alta aplicada")
                "{}"
            }
            "baja-hecha" -> {
                p.edit().remove(KEY_PENDIENTE).remove(KEY_BAJA).putBoolean(KEY_HECHA, false)
                    .putBoolean(KEY_START_ON_BOOT_OPT, false).apply()
                Log.i(TAG, "baja aplicada")
                "{}"
            }
            else -> "{}"
        }
    }

    fun estado(ctx: Context): String {
        val p = prefs(ctx)
        return when {
            p.getBoolean(KEY_BAJA, false) -> "baja-pendiente"
            !p.getString(KEY_PENDIENTE, "").isNullOrEmpty() -> "pendiente"
            p.getBoolean(KEY_HECHA, false) -> "hecha"
            else -> "sin-alta"
        }
    }

    fun dejarPendiente(ctx: Context, pwd: String) {
        prefs(ctx).edit().putString(KEY_PENDIENTE, pwd).remove(KEY_BAJA).putBoolean(KEY_START_ON_BOOT_OPT, true).apply()
        Log.i(TAG, "alta pendiente (por adb)")
    }

    fun dejarBaja(ctx: Context) {
        prefs(ctx).edit().remove(KEY_PENDIENTE).putBoolean(KEY_BAJA, true).apply()
        Log.i(TAG, "baja pendiente (por adb)")
    }
}

/** Solo para adb (ver arriba). No expone datos: query/insert/... no hacen nada. */
class VantarisAltaProvider : ContentProvider() {
    override fun onCreate() = true

    override fun call(method: String, arg: String?, extras: Bundle?): Bundle {
        val uid = Binder.getCallingUid()
        if (uid != 2000 && uid != 0) { // shell (adb) o root
            throw SecurityException("Solo por adb")
        }
        val ctx = context ?: throw IllegalStateException("sin contexto")
        val out = Bundle()
        when (method) {
            "alta" -> {
                val pwd = arg ?: ""
                if (!VantarisAlta.esValida(pwd)) {
                    out.putString("resultado", "error: la contraseña debe tener 8-64 caracteres, sin espacios")
                } else {
                    VantarisAlta.dejarPendiente(ctx, pwd)
                    out.putString("resultado", "pendiente: abre la app para aplicarla")
                }
            }
            "estado" -> out.putString("resultado", VantarisAlta.estado(ctx))
            "baja" -> {
                VantarisAlta.dejarBaja(ctx)
                out.putString("resultado", "baja-pendiente: abre la app para aplicarla")
            }
            else -> out.putString("resultado", "error: método desconocido")
        }
        return out
    }

    override fun query(u: Uri, p: Array<out String>?, s: String?, a: Array<out String>?, o: String?): Cursor? = null
    override fun getType(uri: Uri): String? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, s: String?, a: Array<out String>?) = 0
    override fun update(uri: Uri, v: ContentValues?, s: String?, a: Array<out String>?) = 0
}
