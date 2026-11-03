package com.carriez.flutter_hbb

// Vantaris Cobertura (lib/vantaris/cobertura): lecturas de radio para el mapa de cobertura del local.
//
// Órdenes (JSON {"orden": ...}) por el canal «mChannel», método «vantaris_cobertura»; contesta JSON:
//   tiene_movil · wifi · movil · redes · router · permisos · ajustes
//   guardar {nombre, mime, datos(base64)} → Descargas/Vantaris · compartir {uri, mime}
// Solo lee; lo único que escribe es el archivo que pide guardar el usuario.

import android.Manifest
import android.annotation.SuppressLint
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.Settings
import android.telephony.CellInfoGsm
import android.telephony.CellInfoLte
import android.telephony.CellInfoNr
import android.telephony.CellInfoWcdma
import android.telephony.TelephonyManager
import android.util.Base64
import androidx.core.content.FileProvider
import com.hjq.permissions.XXPermissions
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

object VantarisCobertura {

    fun handle(ctx: Context, args: String, result: MethodChannel.Result) {
        val a = try { JSONObject(args) } catch (e: Exception) { JSONObject() }
        val orden = a.optString("orden")
        // Lo que abre pantallas va en el hilo principal y con la Activity.
        when (orden) {
            "permisos" -> { pedirPermisos(ctx); result.success("{}"); return }
            "ajustes" -> { abrirAjustes(ctx); result.success("{}"); return }
            "compartir" -> { result.success(compartir(ctx, a).toString()); return }
        }
        val app = ctx.applicationContext
        Thread {
            val r = try {
                run(app, orden, a)
            } catch (e: Exception) {
                JSONObject().put("error", "Fallo en el equipo: ${e.message}")
            }
            Handler(Looper.getMainLooper()).post { result.success(r.toString()) }
        }.start()
    }

    private fun run(ctx: Context, orden: String, a: JSONObject): JSONObject = when (orden) {
        "tiene_movil" -> JSONObject().put("si", tieneMovil(ctx))
        "wifi" -> wifi(ctx)
        "movil" -> JSONObject().put("movil", movil(ctx) ?: JSONObject.NULL)
        "redes" -> redes(ctx)
        "router" -> JSONObject().put("ip", router(ctx) ?: JSONObject.NULL)
        "guardar" -> guardar(ctx, a)
        else -> JSONObject().put("error", "Orden desconocida: $orden")
    }

    private fun conUbicacion(ctx: Context) =
        ctx.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED

    private fun tieneMovil(ctx: Context): Boolean {
        val tm = ctx.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager ?: return false
        return tm.phoneType != TelephonyManager.PHONE_TYPE_NONE && tm.simState == TelephonyManager.SIM_STATE_READY
    }

    private fun canal(mhz: Int): Int? = when {
        mhz == 2484 -> 14
        mhz in 2412..2472 -> (mhz - 2407) / 5
        mhz in 5000..5900 -> (mhz - 5000) / 5
        mhz in 5925..7125 -> (mhz - 5950) / 5
        else -> null
    }

    @Suppress("DEPRECATION")
    @SuppressLint("MissingPermission")
    private fun wifi(ctx: Context): JSONObject {
        val wm = ctx.getSystemService(Context.WIFI_SERVICE) as WifiManager
        if (!wm.isWifiEnabled) return JSONObject().put("error", "La WiFi del equipo está apagada.")
        val i = wm.connectionInfo ?: return JSONObject()
        if (i.networkId == -1 && i.rssi <= -120) return JSONObject().put("error", "El equipo no está conectado a ninguna WiFi.")
        val ssid = i.ssid?.trim('"')?.takeUnless { it == "<unknown ssid>" || it.isBlank() }
        val r = JSONObject()
        if (ssid == null && !conUbicacion(ctx)) {
            r.put("error", "Da permiso de ubicación a Vantaris Soporte para ver la WiFi (Android lo exige).")
        }
        val w = JSONObject()
            .put("ssid", ssid ?: "(red sin nombre)")
            .put("bssid", i.bssid?.takeUnless { it == "02:00:00:00:00:00" } ?: JSONObject.NULL)
            .put("rssi", i.rssi)
            .put("frecuenciaMhz", i.frequency)
            .put("canal", canal(i.frequency) ?: JSONObject.NULL)
            .put("velocidadMbps", i.linkSpeed.toDouble())
        if (Build.VERSION.SDK_INT >= 30) {
            when (i.wifiStandard) {
                4 -> "802.11n"; 5 -> "802.11ac"; 6 -> "802.11ax"; 8 -> "802.11be"; else -> null
            }?.let { w.put("estandar", it) }
        }
        return r.put("wifi", w)
    }

    private fun lecturaMovil(tipo: String?, dbm: Int?, nivel: Int?, operador: String?) = JSONObject()
        .put("tipo", tipo ?: JSONObject.NULL)
        .put("dbm", dbm?.takeIf { it in -150..-20 } ?: JSONObject.NULL)
        .put("nivel", nivel ?: JSONObject.NULL)
        .put("operador", operador ?: JSONObject.NULL)

    @SuppressLint("MissingPermission")
    private fun movil(ctx: Context): JSONObject? {
        val t = ctx.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager ?: return null
        val operador = t.networkOperatorName?.takeIf { it.isNotBlank() }
        try {
            if (conUbicacion(ctx)) {
                for (c in t.allCellInfo.orEmpty().filter { it.isRegistered }) {
                    if (Build.VERSION.SDK_INT >= 29 && c is CellInfoNr) {
                        val s = c.cellSignalStrength
                        return lecturaMovil("5G", s.dbm, s.level, operador)
                    }
                    when (c) {
                        is CellInfoLte -> return lecturaMovil("4G", c.cellSignalStrength.dbm, c.cellSignalStrength.level, operador)
                        is CellInfoWcdma -> return lecturaMovil("3G", c.cellSignalStrength.dbm, c.cellSignalStrength.level, operador)
                        is CellInfoGsm -> return lecturaMovil("2G", c.cellSignalStrength.dbm, c.cellSignalStrength.level, operador)
                    }
                }
            }
            if (Build.VERSION.SDK_INT >= 28) {
                val s = t.signalStrength?.cellSignalStrengths?.firstOrNull()
                if (s != null) return lecturaMovil(null, s.dbm, s.level, operador)
            }
        } catch (e: SecurityException) {
            // sin permiso: solo operador
        }
        return operador?.let { lecturaMovil(null, null, null, it) }
    }

    @Suppress("DEPRECATION")
    @SuppressLint("MissingPermission")
    private fun redes(ctx: Context): JSONObject {
        if (!conUbicacion(ctx)) return JSONObject().put("error", "Da permiso de ubicación para buscar redes WiFi.")
        val wm = ctx.getSystemService(Context.WIFI_SERVICE) as WifiManager
        if (!wm.isWifiEnabled) return JSONObject().put("error", "Activa la WiFi del equipo para buscar redes.")
        runCatching { wm.startScan() }
        Thread.sleep(2500)
        val lista = try { wm.scanResults.orEmpty() } catch (e: SecurityException) { emptyList() }
        val arr = JSONArray()
        for (s in lista) {
            val ssid = if (Build.VERSION.SDK_INT >= 33) s.wifiSsid?.toString()?.trim('"') else s.SSID
            arr.put(
                JSONObject()
                    .put("ssid", ssid?.ifBlank { null } ?: "(oculta)")
                    .put("bssid", s.BSSID ?: "")
                    .put("rssi", s.level)
                    .put("frecuenciaMhz", s.frequency)
                    .put("canal", canal(s.frequency) ?: JSONObject.NULL),
            )
        }
        return JSONObject().put("redes", arr)
    }

    private fun router(ctx: Context): String? = runCatching {
        val cm = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val lp = cm.getLinkProperties(cm.activeNetwork) ?: return@runCatching null
        lp.routes.firstOrNull { it.isDefaultRoute && it.gateway != null && it.gateway!!.address.size == 4 }
            ?.gateway?.hostAddress
    }.getOrNull()

    private fun pedirPermisos(ctx: Context) {
        if (conUbicacion(ctx)) return
        runCatching {
            XXPermissions.with(ctx)
                .permission(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION)
                .request { _, _ -> }
        }
    }

    private fun abrirAjustes(ctx: Context) {
        val i = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", ctx.packageName, null))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        runCatching { ctx.startActivity(i) }
    }

    /** Guarda en Descargas/Vantaris. Devuelve {ok, ruta, uri}. */
    private fun guardar(ctx: Context, a: JSONObject): JSONObject {
        val nombre = a.optString("nombre").replace(Regex("[\\\\/:*?\"<>|]"), "_").ifBlank { "cobertura" }
        val mime = a.optString("mime").ifBlank { "application/octet-stream" }
        val datos = Base64.decode(a.optString("datos"), Base64.DEFAULT)
        if (Build.VERSION.SDK_INT >= 29) {
            val cr = ctx.contentResolver
            val v = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, nombre)
                put(MediaStore.Downloads.MIME_TYPE, mime)
                put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/Vantaris")
            }
            val uri = cr.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, v)
                ?: return JSONObject().put("error", "No se pudo crear el archivo")
            cr.openOutputStream(uri)?.use { it.write(datos) } ?: return JSONObject().put("error", "Sin acceso al archivo")
            return JSONObject().put("ok", true).put("ruta", "Descargas/Vantaris/$nombre").put("uri", uri.toString())
        }
        // Android 9 o anterior: carpeta propia de la app (no pide permiso de almacenamiento).
        val dir = File(ctx.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS), "Vantaris").apply { mkdirs() }
        val f = File(dir, nombre)
        f.writeBytes(datos)
        return JSONObject().put("ok", true).put("ruta", f.absolutePath).put("uri", Uri.fromFile(f).toString())
    }

    private fun compartir(ctx: Context, a: JSONObject): JSONObject {
        var uri = Uri.parse(a.optString("uri"))
        if (uri.scheme == "file") {
            uri = runCatching {
                FileProvider.getUriForFile(ctx, ctx.packageName + ".fileprovider", File(uri.path!!))
            }.getOrElse { return JSONObject().put("error", "No se puede compartir en este Android") }
        }
        val i = Intent(Intent.ACTION_SEND).apply {
            type = a.optString("mime").ifBlank { "application/octet-stream" }
            putExtra(Intent.EXTRA_STREAM, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        val elegir = Intent.createChooser(i, "Enviar informe").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return try {
            ctx.startActivity(elegir); JSONObject().put("ok", true)
        } catch (e: Exception) {
            JSONObject().put("error", "No hay ninguna app para compartir")
        }
    }
}
