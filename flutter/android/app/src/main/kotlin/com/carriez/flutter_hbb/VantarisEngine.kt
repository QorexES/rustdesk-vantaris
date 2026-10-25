package com.carriez.flutter_hbb

// Vantaris: la parte Flutter (Dart) sigue viva aunque Android cierre la pantalla de la app.
//
// La pizarra, el aviso de «técnico conectado» y el «no tocar» llegan por el chat de la sesión, y
// la librería Rust oficial (1.4.9) solo entrega el chat a Dart (evento «chat_server_mode» del
// flujo global), nunca al lado Kotlin. En RustDesk normal el motor Flutter muere con la actividad:
// si el cliente sale con «Atrás», la quita de recientes o el sistema la cierra, el servicio sigue
// compartiendo pantalla pero ya nadie procesa las órdenes y las capas desaparecen.
//
// Solución sin tocar Rust: un único motor Flutter guardado aquí, que la actividad reutiliza y NO
// destruye al cerrarse (MainActivity.provideFlutterEngine / shouldDestroyEngineWithHost). Mientras
// viva el proceso (lo mantiene el servicio en primer plano), Dart sigue recibiendo el chat y pinta
// con VantarisDrawOverlay / VantarisGuard, que son capas del sistema (TYPE_APPLICATION_OVERLAY)
// y no necesitan la actividad.
//
// Sin actividad nadie atiende el canal «mChannel»: se deja puesto un manejador mínimo que solo
// sabe hacer lo que Dart pide en segundo plano (pintar, aviso, traer la app al frente).
//
// Si el proceso arranca sin actividad (encendido del equipo con «arrancar al inicio») y entra un
// técnico, MainService llama a ensureRunning() y el motor arranca sin pantalla.

import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.hjq.permissions.XXPermissions
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

object VantarisEngine {
    private const val TAG = "VantarisEngine"
    private const val CHANNEL = "mChannel" // el mismo que MainActivity

    private var engine: FlutterEngine? = null

    /** El motor de la app; lo crea la primera vez (sin arrancar Dart: eso lo hace la actividad). */
    fun get(context: Context): FlutterEngine {
        engine?.let { return it }
        Log.i(TAG, "nuevo motor Flutter compartido")
        val e = FlutterEngine(context.applicationContext) // registra los plugins solo
        engine = e
        return e
    }

    /** Hay motor y está ejecutando Dart. */
    val isRunning: Boolean
        get() = engine?.dartExecutor?.isExecutingDart == true

    /**
     * Entra una conexión y no hay Dart vivo (el proceso lo arrancó el servicio): arrancar el
     * motor sin pantalla para que las órdenes del técnico se procesen igualmente.
     */
    fun ensureRunning(context: Context) {
        Handler(Looper.getMainLooper()).post {
            try {
                if (isRunning) return@post
                val e = get(context)
                installBackgroundHandler(context)
                Log.i(TAG, "arrancando Dart sin pantalla (no hay actividad)")
                e.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
            } catch (ex: Exception) {
                Log.e(TAG, "ensureRunning failed: $ex")
            }
        }
    }

    /**
     * Manejador del canal para cuando no hay actividad (se ha cerrado o nunca se abrió).
     * La actividad pone el suyo al volver (MainActivity.configureFlutterEngine).
     */
    fun installBackgroundHandler(context: Context) {
        val e = engine ?: return
        val app = context.applicationContext
        val channel = MethodChannel(e.dartExecutor.binaryMessenger, CHANNEL)
        MainActivity.flutterMethodChannel = channel
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "vantaris_draw" -> {
                        result.success(VantarisDrawOverlay.handle(app, call.arguments as String))
                    }
                    "vantaris_guard" -> {
                        VantarisGuard.handle(app, call.arguments as String)
                        result.success(null)
                    }
                    "vantaris_front" -> {
                        bringToFront(app)
                        result.success(null)
                    }
                    "check_permission" -> result.success(
                        call.arguments is String && XXPermissions.isGranted(app, call.arguments as String))
                    "check_service" -> {
                        channel.invokeMethod("on_state_changed",
                            mapOf("name" to "input", "value" to InputService.isOpen.toString()))
                        channel.invokeMethod("on_state_changed",
                            mapOf("name" to "media", "value" to MainService.isReady.toString()))
                        result.success(true)
                    }
                    "try_sync_clipboard" -> {
                        MainActivity.rdClipboardManager?.syncClipboard(true)
                        result.success(true)
                    }
                    GET_VALUE -> result.success(
                        if (call.arguments == KEY_IS_SUPPORT_VOICE_CALL) isSupportVoiceCall() else null)
                    // Lo demás necesita la pantalla de la app (permisos, captura...): no se hace.
                    else -> {
                        Log.d(TAG, "sin actividad, se ignora: ${call.method}")
                        result.success(false)
                    }
                }
            } catch (ex: Exception) {
                Log.e(TAG, "${call.method} failed: $ex")
                result.success(false)
            }
        }
    }

    /** Trae la app al frente (videollamada entrante) sin depender de una actividad viva. */
    fun bringToFront(context: Context) {
        val i = Intent(context.applicationContext, MainActivity::class.java)
        i.addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or Intent.FLAG_ACTIVITY_NEW_TASK)
        context.applicationContext.startActivity(i)
    }
}
