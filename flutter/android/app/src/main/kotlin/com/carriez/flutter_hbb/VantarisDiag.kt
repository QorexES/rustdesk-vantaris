package com.carriez.flutter_hbb

// Vantaris: diagnóstico del equipo y acciones rápidas del técnico (lib/vantaris/diag.dart).
//
// Datos del sistema (Android, modelo, batería, espacio, memoria, red, si llega al servidor de
// Vantaris) los saca esta app; lo del TPV (versión, impresoras, conexión con el servidor, registros)
// y las acciones (ticket de prueba, cajón, reiniciar) se piden al TPV por su ContentProvider
// «<paquete>.soporte», que solo atiende a esta app firmada con la clave de Vantaris.
// Lista cerrada: aquí no hay nada que ejecute otra cosa.

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.util.Base64
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.Inet4Address
import java.net.URL

object VantarisDiag {

    /** Paquetes de la app TPV (Play pública y la de EEM para terminales Dojo). */
    private val TPV_PAQUETES = listOf("es.vantaris.app.tpv", "es.vantaris.eem.tpv")

    fun handle(ctx: Context, args: String, result: MethodChannel.Result) {
        val app = ctx.applicationContext
        Thread {
            val r = try {
                val a = JSONObject(args)
                run(app, a.getString("orden"), a.optString("arg").ifEmpty { null })
            } catch (e: Exception) {
                fallo("Fallo en el equipo: ${e.message}")
            }
            Handler(Looper.getMainLooper()).post { result.success(r.toString()) }
        }.start()
    }

    private fun run(ctx: Context, orden: String, arg: String?): JSONObject = when (orden) {
        "estado" -> JSONObject()
            .put("ok", true)
            .put("plataforma", "android")
            .put("equipo", equipo(ctx))
            .put("servidor", servidor())
            .put("tpv", tpvEstado(ctx))
        "registros" -> registros(ctx)
        "prueba" -> if (arg?.all { it.isDigit() } == true) tpvCall(ctx, "prueba", arg) else fallo("Falta la impresora.")
        "cajon" -> tpvCall(ctx, "cajon", null)
        "reiniciar" -> reiniciar(ctx)
        else -> fallo("Orden no permitida.")
    }

    // ---------------------------------------------------------------- sistema

    private fun equipo(ctx: Context): JSONObject {
        val o = JSONObject()
        o.put("so", "Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})")
        o.put("modelo", "${Build.MANUFACTURER} ${Build.MODEL}".trim())
        runCatching {
            val b = ctx.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            if (b != null && b.getBooleanExtra(BatteryManager.EXTRA_PRESENT, true)) {
                val level = b.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
                val scale = b.getIntExtra(BatteryManager.EXTRA_SCALE, 100)
                if (level >= 0 && scale > 0) o.put("bateria", level * 100 / scale)
                val status = b.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
                o.put("cargando", status == BatteryManager.BATTERY_STATUS_CHARGING ||
                    status == BatteryManager.BATTERY_STATUS_FULL)
                o.put("enchufado", b.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) != 0)
            } else {
                o.put("sinBateria", true)
            }
        }
        runCatching {
            val s = StatFs(Environment.getDataDirectory().path)
            o.put("discoLibreMb", s.availableBytes / (1024 * 1024))
            o.put("discoTotalMb", s.totalBytes / (1024 * 1024))
        }
        runCatching {
            val am = ctx.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            val mi = ActivityManager.MemoryInfo().also { am.getMemoryInfo(it) }
            o.put("memLibreMb", mi.availMem / (1024 * 1024))
            o.put("memTotalMb", mi.totalMem / (1024 * 1024))
        }
        runCatching { o.put("red", red(ctx)) }
        return o
    }

    private fun red(ctx: Context): JSONObject {
        val cm = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val n = cm.activeNetwork ?: return JSONObject().put("tipo", "sin red")
        val caps = cm.getNetworkCapabilities(n)
        val tipo = when {
            caps == null -> "desconocida"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "cable (ethernet)"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "datos móviles"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN) -> "VPN"
            else -> "otra"
        }
        val o = JSONObject().put("tipo", tipo)
        cm.getLinkProperties(n)?.linkAddresses
            ?.map { it.address }
            ?.firstOrNull { it is Inet4Address && !it.isLoopbackAddress }
            ?.let { o.put("ip", it.hostAddress) }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && caps != null &&
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
        ) {
            val s = caps.signalStrength
            if (s != Int.MIN_VALUE && s < 0) o.put("senal", s)
        }
        if (caps != null) o.put("internet", caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED))
        return o
    }

    /** ¿Llega el equipo al servidor de Vantaris? Cualquier respuesta HTTP vale. */
    private fun servidor(): JSONObject {
        val host = "api.vantaris.es"
        val t0 = System.currentTimeMillis()
        return try {
            val c = URL("https://$host/").openConnection() as HttpURLConnection
            c.requestMethod = "HEAD"
            c.connectTimeout = 6000
            c.readTimeout = 6000
            c.responseCode
            c.disconnect()
            JSONObject().put("llega", true).put("host", host).put("ms", System.currentTimeMillis() - t0)
        } catch (e: Exception) {
            JSONObject().put("llega", false).put("host", host).put("error", e.javaClass.simpleName)
        }
    }

    // ---------------------------------------------------------------- TPV

    private fun tpvPaquete(ctx: Context): Pair<String, String?>? {
        val pm = ctx.packageManager
        for (p in TPV_PAQUETES) {
            val info = runCatching { pm.getPackageInfo(p, 0) }.getOrNull() ?: continue
            return p to info.versionName
        }
        return null
    }

    private fun tpvEstado(ctx: Context): JSONObject {
        val (paquete, version) = tpvPaquete(ctx)
            ?: return JSONObject().put("instalado", false).put("ok", false)
                .put("motivo", "La app TPV Vantaris no está instalada en este equipo.")
        val r = tpvCall(ctx, "estado", null, paquete)
        r.put("instalado", true).put("paquete", paquete)
        if (version != null) r.put("versionInstalada", version)
        return r
    }

    private fun tpvCall(ctx: Context, metodo: String, arg: String?, paquete: String? = null): JSONObject {
        val p = paquete ?: tpvPaquete(ctx)?.first
            ?: return fallo("La app TPV Vantaris no está instalada en este equipo.")
        return try {
            val b = ctx.contentResolver.call(Uri.parse("content://$p.soporte"), metodo, arg, null)
            val s = b?.getString("json") ?: return fallo("El TPV no ha contestado.")
            JSONObject(s)
        } catch (e: IllegalArgumentException) {
            // «Unknown authority»: TPV de antes del diagnóstico remoto.
            fallo("La versión instalada del TPV no tiene todavía el diagnóstico remoto (hay que actualizarla).")
                .put("puerta", false)
        } catch (e: SecurityException) {
            fallo("El TPV no reconoce a este cliente de soporte (firma distinta).").put("puerta", false)
        } catch (e: Exception) {
            fallo("El TPV no ha podido contestar (${e.javaClass.simpleName}).")
        }
    }

    private fun registros(ctx: Context): JSONObject {
        val p = tpvPaquete(ctx)?.first ?: return fallo("La app TPV Vantaris no está instalada en este equipo.")
        val lista = tpvCall(ctx, "registros", null, p)
        if (!lista.optBoolean("ok")) return lista
        val out = JSONArray()
        val arr = lista.optJSONArray("arranques") ?: JSONArray()
        for (i in 0 until arr.length()) {
            val a = arr.getJSONObject(i)
            val bytes = runCatching {
                ctx.contentResolver.openInputStream(Uri.parse("content://$p.soporte/registros/${a.getString("id")}"))
                    ?.use { it.readBytes() }
            }.getOrNull() ?: continue
            a.put("gz", Base64.encodeToString(bytes, Base64.NO_WRAP))
            out.put(a)
        }
        return JSONObject().put("ok", true).put("arranques", out)
    }

    private fun reiniciar(ctx: Context): JSONObject {
        val p = tpvPaquete(ctx)?.first ?: return fallo("La app TPV Vantaris no está instalada en este equipo.")
        val r = tpvCall(ctx, "reiniciar", null, p)
        if (!r.optBoolean("ok")) return r
        // El TPV se cierra solo; lo vuelve a abrir esta app (tiene la ventana flotante, que es lo
        // que Android pide para abrir otra app desde segundo plano).
        Thread.sleep(2500)
        val i = ctx.packageManager.getLaunchIntentForPackage(p)
        val abierta = if (i != null) {
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
            runCatching { ctx.startActivity(i); true }.getOrDefault(false)
        } else {
            false
        }
        return JSONObject().put("ok", true).put(
            "mensaje",
            if (abierta) "La app TPV se ha cerrado y se está volviendo a abrir."
            else "La app TPV se ha cerrado, pero no se ha podido volver a abrir sola: que el cliente la abra."
        )
    }

    private fun fallo(motivo: String) = JSONObject().put("ok", false).put("motivo", motivo)
}
