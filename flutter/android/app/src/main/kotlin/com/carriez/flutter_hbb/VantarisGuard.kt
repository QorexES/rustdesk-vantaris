package com.carriez.flutter_hbb

// Vantaris: aviso de «técnico conectado» y modo «no tocar» en el Android controlado.
// Lo maneja Dart (flutter/lib/vantaris/guard.dart) con el método "vantaris_guard" y un JSON:
//   {"session": true, "name": "…"} / {"session": false}   aviso arriba con nombre, tiempo y colgar
//   {"block": true} / {"block": false}                   capa que se traga los toques del usuario
//   {"message": "…", "name": "…"}                       mensaje de chat del técnico: tarjeta arriba
//
// La tarjeta del mensaje sale por encima de todo (la app de la tienda, la pizarra, el foco y la
// capa de «no tocar»), porque el chat de RustDesk solo se ve dentro de su app. «Vale» la quita;
// «Responder» abre el chat de la app (no sale con «no tocar» puesto: no se podría escribir).
//
// Mientras bloquea, los gestos que inyecta el técnico (InputService) tienen que atravesar la capa:
// antes de cada tanda la capa se vuelve «no tocable» un momento y después vuelve a bloquear.
// Si el técnico deja de confirmar el bloqueo (20 s sin «B 1»), se quita solo.

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.view.WindowManager.LayoutParams.*
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import org.json.JSONObject
import java.util.ArrayDeque

object VantarisGuard {
    private const val TAG = "VantarisGuard"
    private const val TEAL = 0xFF03B5A5.toInt()
    private const val WATCHDOG_MS = 20000L
    private const val PASS_DELAY_MS = 80L     // lo que tarda en aplicarse «no tocable»
    private const val RESTORE_MS = 1500L      // sin gestos del técnico, vuelve a bloquear

    private val handler = Handler(Looper.getMainLooper())
    private var wm: WindowManager? = null
    private var appContext: Context? = null

    // Aviso
    private var pill: View? = null
    private var pillText: TextView? = null
    private var pillButton: Button? = null
    private var sessionName = ""
    private var sessionSince = 0L
    private var confirmHangup = false
    private var recordingBeat = 0L // último «R 1»; 0 = no se graba

    // Mensaje del técnico
    private var message: View? = null
    private var messageCount = 0
    private const val MESSAGE_MS = 120000L // se quita solo a los 2 min

    // Bloqueo
    @Volatile var blocking = false
        private set
    private var blocker: View? = null
    private var blockerParams: WindowManager.LayoutParams? = null
    private var lastBeat = 0L
    private var passThrough = false
    private var waiting = false
    private var inFlight = 0
    private val queue = ArrayDeque<Pair<AccessibilityService, GestureDescription>>()

    fun handle(context: Context, json: String) {
        handler.post {
            try {
                appContext = context.applicationContext
                wm = wm ?: context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
                val o = JSONObject(json)
                if (o.has("session")) {
                    if (o.getBoolean("session")) showSession(o.optString("name")) else endSession()
                }
                if (o.has("recording")) {
                    recordingBeat = if (o.getBoolean("recording")) SystemClock.elapsedRealtime() else 0L
                    updatePill()
                }
                if (o.has("block")) {
                    if (o.getBoolean("block")) block() else unblock(notify = false)
                }
                if (o.has("message")) showMessage(o.optString("name"), o.getString("message"))
            } catch (e: Exception) {
                Log.e(TAG, "handle failed: $e")
            }
        }
    }

    private fun dp(v: Float): Int = TypedValue.applyDimension(
        TypedValue.COMPLEX_UNIT_DIP, v, appContext!!.resources.displayMetrics).toInt()

    private fun overlayType() =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) TYPE_APPLICATION_OVERLAY else TYPE_PHONE

    // ---------------------------------------------------------------- aviso

    private fun showSession(name: String) {
        if (pill == null) sessionSince = SystemClock.elapsedRealtime()
        sessionName = name
        if (pill == null) addPill()
        updatePill()
    }

    private fun endSession() {
        recordingBeat = 0L
        hideMessage()
        unblock(notify = false)
        removeView(pill)
        pill = null
        handler.removeCallbacks(tick)
    }

    @SuppressLint("SetTextI18n")
    private fun addPill() {
        val ctx = appContext ?: return
        val row = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(12f), dp(4f), dp(4f), dp(4f))
            background = GradientDrawable().apply {
                cornerRadius = dp(20f).toFloat()
                setColor(0xE6151B26.toInt())
                setStroke(dp(1.5f), TEAL)
            }
        }
        val dot = View(ctx).apply {
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(TEAL)
            }
        }
        row.addView(dot, LinearLayout.LayoutParams(dp(8f), dp(8f)).apply { rightMargin = dp(8f) })
        val label = TextView(ctx).apply {
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            maxLines = 1
            // En teléfono no cabe todo a lo ancho: se recorta la etiqueta, nunca el botón.
            isSingleLine = true
            ellipsize = android.text.TextUtils.TruncateAt.END
            maxWidth = ctx.resources.displayMetrics.widthPixels - dp(150f)
        }
        row.addView(label)
        val button = Button(ctx).apply {
            text = "Colgar"
            isAllCaps = false
            isSingleLine = true
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            typeface = Typeface.DEFAULT_BOLD
            minWidth = 0; minHeight = 0; minimumWidth = 0; minimumHeight = 0
            setPadding(dp(12f), dp(6f), dp(12f), dp(6f))
            background = GradientDrawable().apply {
                cornerRadius = dp(16f).toFloat()
                setColor(0xFFE53935.toInt())
            }
            setOnClickListener { onHangupPressed() }
        }
        row.addView(button, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
            leftMargin = dp(10f)
        })
        val p = WindowManager.LayoutParams(
            WRAP_CONTENT, WRAP_CONTENT, overlayType(),
            FLAG_NOT_FOCUSABLE or FLAG_NOT_TOUCH_MODAL,
            PixelFormat.TRANSLUCENT
        )
        p.gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
        p.y = dp(6f)
        wm?.addView(row, p)
        pill = row
        pillText = label
        pillButton = button
        handler.removeCallbacks(tick)
        handler.post(tick)
    }

    private val tick = object : Runnable {
        override fun run() {
            if (pill == null) return
            updatePill()
            handler.postDelayed(this, 1000)
        }
    }

    @SuppressLint("SetTextI18n")
    private fun updatePill() {
        val secs = (SystemClock.elapsedRealtime() - sessionSince) / 1000
        val time = if (secs >= 3600) "%d:%02d:%02d".format(secs / 3600, secs / 60 % 60, secs % 60)
        else "%02d:%02d".format(secs / 60, secs % 60)
        val who = sessionName.ifBlank { "Un técnico" }
        if (recordingBeat > 0 && SystemClock.elapsedRealtime() - recordingBeat > WATCHDOG_MS) {
            recordingBeat = 0L
        }
        val rec = if (recordingBeat > 0) " · ● Grabando audio" else ""
        pillText?.text = "Técnico Vantaris conectado · $who · $time$rec"
    }

    // Doble toque para colgar: el primero pregunta, el segundo cuelga.
    @SuppressLint("SetTextI18n")
    private fun onHangupPressed() {
        if (!confirmHangup) {
            confirmHangup = true
            pillButton?.text = "¿Colgar?"
            handler.postDelayed({
                confirmHangup = false
                pillButton?.text = "Colgar"
            }, 3000)
            return
        }
        confirmHangup = false
        pillButton?.text = "Colgar"
        unblock(notify = false)
        MainActivity.flutterMethodChannel?.invokeMethod("vantaris_hangup", null)
    }

    // ---------------------------------------------------------------- bloqueo

    private fun block() {
        lastBeat = SystemClock.elapsedRealtime()
        if (blocking) return
        val ctx = appContext ?: return
        val root = FrameLayout(ctx)
        val card = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(18f), dp(14f), dp(18f), dp(14f))
            background = GradientDrawable().apply {
                cornerRadius = dp(16f).toFloat()
                setColor(0xF0151B26.toInt())
                setStroke(dp(2f), TEAL)
            }
        }
        card.addView(TextView(ctx).apply {
            text = "Un técnico de Vantaris está trabajando en este equipo"
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
            typeface = Typeface.DEFAULT_BOLD
            gravity = Gravity.CENTER
        })
        card.addView(TextView(ctx).apply {
            text = "Por favor, no toque la pantalla hasta que termine."
            setTextColor(0xFFCFD8DC.toInt())
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
            gravity = Gravity.CENTER
            setPadding(0, dp(4f), 0, dp(10f))
        })
        card.addView(Button(ctx).apply {
            text = "Necesito usar el equipo"
            isAllCaps = false
            setTextColor(Color.WHITE)
            background = GradientDrawable().apply {
                cornerRadius = dp(18f).toFloat()
                setColor(TEAL)
            }
            setPadding(dp(16f), dp(8f), dp(16f), dp(8f))
            setOnClickListener { unblock(notify = true) }
        })
        root.addView(card, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT,
            Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL).apply { bottomMargin = dp(48f) })
        // Transparente salvo la tarjeta: el técnico sigue viendo la pantalla tal cual.
        val (w, h) = getScreenSize(wm!!)
        val p = WindowManager.LayoutParams(
            w, h, overlayType(),
            FLAG_NOT_FOCUSABLE or FLAG_LAYOUT_IN_SCREEN or FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT
        )
        p.gravity = Gravity.TOP or Gravity.START
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            p.layoutInDisplayCutoutMode = LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) p.fitInsetsTypes = 0
        try {
            wm?.addView(root, p)
        } catch (e: Exception) {
            Log.e(TAG, "block failed: $e")
            return
        }
        blocker = root
        blockerParams = p
        blocking = true
        passThrough = false
        // El aviso con «Colgar» y el mensaje, siempre por encima de la capa.
        raiseNow()
        message?.let { updateMessageButtons() }
        handler.removeCallbacks(watchdog)
        handler.postDelayed(watchdog, 5000)
    }

    private val watchdog = object : Runnable {
        override fun run() {
            if (!blocking) return
            if (SystemClock.elapsedRealtime() - lastBeat > WATCHDOG_MS) {
                Log.i(TAG, "sin noticias del técnico: se quita el bloqueo")
                unblock(notify = false)
                return
            }
            handler.postDelayed(this, 5000)
        }
    }

    private fun unblock(notify: Boolean) {
        handler.removeCallbacks(watchdog)
        handler.removeCallbacks(restore)
        val wasBlocking = blocking
        blocking = false
        removeView(blocker)
        blocker = null
        blockerParams = null
        passThrough = false
        waiting = false
        // Los gestos que quedaran en cola salen ya.
        while (queue.isNotEmpty()) {
            val (svc, g) = queue.poll()!!
            svc.dispatchGesture(g, null, null)
        }
        if (notify && wasBlocking) {
            MainActivity.flutterMethodChannel?.invokeMethod("vantaris_unblock", null)
        }
        if (wasBlocking) updateMessageButtons()
    }

    private fun setTouchable(touchable: Boolean) {
        val v = blocker ?: return
        val p = blockerParams ?: return
        p.flags = if (touchable) p.flags and FLAG_NOT_TOUCHABLE.inv() else p.flags or FLAG_NOT_TOUCHABLE
        try { wm?.updateViewLayout(v, p) } catch (_: Exception) {}
    }

    /** Sustituye a dispatchGesture en InputService: sin bloqueo es exactamente lo mismo. */
    fun dispatch(svc: AccessibilityService, g: GestureDescription) {
        if (!blocking) {
            svc.dispatchGesture(g, null, null)
            return
        }
        handler.post {
            if (!blocking) {
                svc.dispatchGesture(g, null, null)
                return@post
            }
            queue.add(svc to g)
            handler.removeCallbacks(restore)
            if (!passThrough) {
                passThrough = true
                waiting = true
                setTouchable(false)
                handler.postDelayed(flush, PASS_DELAY_MS)
            } else if (!waiting) {
                flush.run()
            }
        }
    }

    private val flush = Runnable {
        waiting = false
        while (queue.isNotEmpty()) {
            val (svc, g) = queue.poll()!!
            inFlight++
            val ok = svc.dispatchGesture(g, object : AccessibilityService.GestureResultCallback() {
                override fun onCompleted(d: GestureDescription?) = done()
                override fun onCancelled(d: GestureDescription?) = done()
            }, handler)
            if (!ok) inFlight--
        }
        scheduleRestore()
    }

    private fun done() {
        if (inFlight > 0) inFlight--
        scheduleRestore()
    }

    private fun scheduleRestore() {
        if (inFlight > 0 || queue.isNotEmpty()) return
        handler.removeCallbacks(restore)
        handler.postDelayed(restore, RESTORE_MS)
    }

    private val restore = Runnable {
        if (!blocking || inFlight > 0 || queue.isNotEmpty()) return@Runnable
        passThrough = false
        setTouchable(true)
    }

    // ---------------------------------------------------------------- mensaje del técnico

    /** La pizarra acaba de crear su capa: el aviso y el mensaje vuelven a quedar encima. */
    fun raise() {
        handler.post { raiseNow() }
    }

    private fun raiseNow() {
        for (v in listOfNotNull(pill, message)) {
            val lp = v.layoutParams ?: continue
            removeView(v)
            try { wm?.addView(v, lp) } catch (e: Exception) { Log.e(TAG, "raise failed: $e") }
        }
    }

    private var replyButton: Button? = null
    private var messageText: TextView? = null
    private var messageTitle: TextView? = null

    @SuppressLint("SetTextI18n")
    private fun showMessage(name: String, text: String) {
        val ctx = appContext ?: return
        if (text.isBlank()) return
        if (message == null) {
            messageCount = 0
            val card = LinearLayout(ctx).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(dp(16f), dp(12f), dp(16f), dp(10f))
                background = GradientDrawable().apply {
                    cornerRadius = dp(16f).toFloat()
                    setColor(0xF2151B26.toInt())
                    setStroke(dp(2f), TEAL)
                }
                elevation = dp(6f).toFloat()
            }
            val title = TextView(ctx).apply {
                setTextColor(TEAL)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
                typeface = Typeface.DEFAULT_BOLD
            }
            card.addView(title)
            val body = TextView(ctx).apply {
                setTextColor(Color.WHITE)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 19f)
                setPadding(0, dp(4f), 0, dp(8f))
                maxLines = 6
            }
            card.addView(body)
            val buttons = LinearLayout(ctx).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.END
            }
            fun makeButton(label: String, color: Int, onClick: () -> Unit) = Button(ctx).apply {
                this.text = label
                isAllCaps = false
                setTextColor(Color.WHITE)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
                typeface = Typeface.DEFAULT_BOLD
                minWidth = 0; minHeight = 0; minimumWidth = 0; minimumHeight = 0
                setPadding(dp(18f), dp(8f), dp(18f), dp(8f))
                background = GradientDrawable().apply {
                    cornerRadius = dp(18f).toFloat()
                    setColor(color)
                }
                setOnClickListener { onClick() }
            }
            val reply = makeButton("Responder", 0xFF37474F.toInt()) {
                hideMessage()
                MainActivity.flutterMethodChannel?.invokeMethod("vantaris_reply", null)
            }
            buttons.addView(reply)
            buttons.addView(makeButton("Vale", TEAL) { hideMessage() },
                LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT
                ).apply { leftMargin = dp(10f) })
            card.addView(buttons)
            val (w, _) = getScreenSize(wm!!)
            val p = WindowManager.LayoutParams(
                minOf(w - dp(32f), dp(560f)), WRAP_CONTENT, overlayType(),
                FLAG_NOT_FOCUSABLE or FLAG_NOT_TOUCH_MODAL,
                PixelFormat.TRANSLUCENT
            )
            p.gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
            p.y = dp(56f) // debajo del aviso «Técnico conectado»
            try {
                wm?.addView(card, p)
            } catch (e: Exception) {
                Log.e(TAG, "message failed: $e")
                return
            }
            message = card
            messageTitle = title
            messageText = body
            replyButton = reply
        } else {
            raiseNow()
        }
        messageCount++
        val who = name.ifBlank { "el técnico" }
        messageTitle?.text = if (messageCount > 1) "Mensaje de $who ($messageCount)" else "Mensaje de $who"
        messageText?.text = text
        updateMessageButtons()
        handler.removeCallbacks(messageTimeout)
        handler.postDelayed(messageTimeout, MESSAGE_MS)
    }

    private fun updateMessageButtons() {
        replyButton?.visibility = if (blocking) View.GONE else View.VISIBLE
    }

    private val messageTimeout = Runnable { hideMessage() }

    private fun hideMessage() {
        handler.removeCallbacks(messageTimeout)
        removeView(message)
        message = null
        messageText = null
        messageTitle = null
        replyButton = null
        messageCount = 0
    }

    private fun removeView(v: View?) {
        v ?: return
        try { wm?.removeView(v) } catch (_: Exception) {}
    }
}
