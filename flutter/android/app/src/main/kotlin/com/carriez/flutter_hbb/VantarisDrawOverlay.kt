package com.carriez.flutter_hbb

// Vantaris: capa transparente donde se pinta la pizarra del técnico (lápiz, formas, números,
// texto, foco y láser). Llega por el chat de la sesión (ver flutter/lib/vantaris/draw.dart) y se
// pinta encima de todo sin capturar toques: el usuario del equipo sigue usando la pantalla.
//
// Protocolo y reglas de dibujo: flutter/lib/vantaris/draw.dart y scene.dart (el técnico ve lo
// mismo con VantarisScene). Si se cambia algo del dibujo, cambiarlo también allí y en
// windows/runner/vantaris_overlay.cpp.

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PixelFormat
import android.graphics.RectF
import android.graphics.Typeface
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.text.Layout
import android.text.StaticLayout
import android.text.TextPaint
import android.util.Base64
import android.util.Log
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.view.WindowManager.LayoutParams.*
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

object VantarisDrawOverlay {
    private const val TAG = "VantarisDraw"
    private const val HOLD_MS = 6000L      // tiempo visible tras terminar (trazos y formas)
    private const val HOLD_MARK_MS = 20000L // números y textos
    private const val FADE_MS = 1200L
    private const val IDLE_REMOVE_MS = 15000L
    private const val LASER_MS = 1500L     // el láser se apaga solo si deja de llegar posición
    private const val TRAIL_MS = 450L

    private enum class Kind { STROKE, SHAPE, NUMBER, TEXT }

    private class Item(val kind: Kind, var color: Int, var widthPermille: Int) {
        val xs = ArrayList<Float>()
        val ys = ArrayList<Float>()
        var shape = 'I'
        var label = ""
        var endedAt = 0L
        var holdMs = HOLD_MS
    }

    private val items = LinkedHashMap<String, Item>()
    private val handler = Handler(Looper.getMainLooper())
    private var view: DrawView? = null
    private var windowManager: WindowManager? = null
    private var params: WindowManager.LayoutParams? = null
    private var lastActivity = 0L
    private var laserX = -1f
    private var laserY = -1f
    private var laserAt = 0L
    private val trail = ArrayList<FloatArray>() // [t, x, y]
    private var focus: RectF? = null

    /** Sin «Mostrar sobre otras apps» no se puede poner la capa (addView falla y no se ve nada). */
    fun puedeDibujar(context: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.M || Settings.canDrawOverlays(context)

    /** Pinta [payload]. Devuelve false si falta el permiso (Dart se lo dice al técnico). */
    fun handle(context: Context, payload: String): Boolean {
        val ok = puedeDibujar(context)
        if (!ok) Log.w(TAG, "sin permiso de capa (Mostrar sobre otras apps): no se pinta")
        handler.post {
            try {
                ensureView(context.applicationContext)
                for (line in payload.split('\n')) apply(line.trim())
                lastActivity = SystemClock.uptimeMillis()
                view?.invalidate()
                scheduleIdleCheck()
            } catch (e: Exception) {
                Log.e(TAG, "handle failed: $e")
            }
        }
        return ok
    }

    private fun point(tok: String?): FloatArray? {
        val xy = tok?.split(',') ?: return null
        if (xy.size != 2) return null
        val x = xy[0].toFloatOrNull() ?: return null
        val y = xy[1].toFloatOrNull() ?: return null
        return floatArrayOf(x / 10000f, y / 10000f)
    }

    private fun color(hex: String?): Int =
        hex?.toLongOrNull(16)?.toInt() ?: 0xFFE53935.toInt()

    private fun apply(line: String) {
        if (line.isEmpty()) return
        val parts = line.split(' ')
        val now = SystemClock.uptimeMillis()
        when (parts[0]) {
            "C" -> { items.clear(); focus = null; laserAt = 0L; trail.clear() }
            "Z" -> items.remove(parts.getOrNull(1))
            "E" -> items[parts.getOrNull(1)]?.let {
                it.endedAt = now
                parts.getOrNull(2)?.toLongOrNull()?.let { ms -> it.holdMs = ms }
            }
            "L" -> {
                val p = point(parts.getOrNull(1))
                if (p == null) { laserAt = 0L; trail.clear(); return }
                laserX = p[0]; laserY = p[1]; laserAt = now
                trail.add(floatArrayOf(now.toFloat(), p[0], p[1]))
            }
            "F" -> {
                val a = point(parts.getOrNull(1))
                val b = point(parts.getOrNull(2))
                focus = if (a != null && b != null)
                    RectF(min(a[0], b[0]), min(a[1], b[1]), max(a[0], b[0]), max(a[1], b[1]))
                else null
            }
            "P" -> {
                if (parts.size < 4) return
                val s = items.getOrPut(parts[1]) {
                    Item(Kind.STROKE, color(parts[2]), parts[3].toIntOrNull() ?: 6)
                }
                for (i in 4 until parts.size) {
                    val p = point(parts[i]) ?: continue
                    s.xs.add(p[0]); s.ys.add(p[1])
                }
            }
            "S" -> {
                if (parts.size < 7) return
                val a = point(parts[5]) ?: return
                val b = point(parts[6]) ?: return
                val s = items.getOrPut(parts[1]) { Item(Kind.SHAPE, color(parts[3]), 6) }
                s.shape = parts[2].firstOrNull() ?: 'I'
                s.color = color(parts[3])
                s.widthPermille = parts[4].toIntOrNull() ?: 6
                s.xs.clear(); s.ys.clear()
                s.xs.add(a[0]); s.ys.add(a[1]); s.xs.add(b[0]); s.ys.add(b[1])
            }
            "N" -> {
                if (parts.size < 5) return
                val p = point(parts[4]) ?: return
                items[parts[1]] = Item(Kind.NUMBER, color(parts[2]), 6).also {
                    it.label = parts[3]; it.holdMs = HOLD_MARK_MS
                    it.xs.add(p[0]); it.ys.add(p[1])
                }
            }
            "X" -> {
                if (parts.size < 5) return
                val p = point(parts[3]) ?: return
                val text = try {
                    String(Base64.decode(parts[4], Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP), Charsets.UTF_8)
                } catch (_: Exception) { return }
                items[parts[1]] = Item(Kind.TEXT, color(parts[2]), 6).also {
                    it.label = text; it.holdMs = HOLD_MARK_MS
                    it.xs.add(p[0]); it.ys.add(p[1])
                }
            }
        }
    }

    private fun ensureView(context: Context) {
        val wm = windowManager ?: (context.getSystemService(Context.WINDOW_SERVICE) as WindowManager)
            .also { windowManager = it }
        // Cubre la pantalla física entera (la que ve el técnico), también al girar el equipo.
        val (w, h) = getScreenSize(wm)
        if (view != null) {
            val p = params!!
            if (p.width != w || p.height != h) {
                p.width = w; p.height = h
                wm.updateViewLayout(view, p)
            }
            return
        }
        val p = WindowManager.LayoutParams(
            w, h,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) TYPE_APPLICATION_OVERLAY else TYPE_PHONE,
            FLAG_NOT_FOCUSABLE or FLAG_NOT_TOUCHABLE or FLAG_LAYOUT_IN_SCREEN or FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT
        )
        p.gravity = Gravity.TOP or Gravity.START
        p.x = 0; p.y = 0
        // Android 12+ bloquea los toques que atraviesan una capa de otra app si es más opaca de 0.8.
        p.alpha = 0.8f
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            p.layoutInDisplayCutoutMode = LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            p.fitInsetsTypes = 0
        }
        val v = DrawView(context)
        wm.addView(v, p)
        view = v
        params = p
        // El aviso de arriba y los mensajes del técnico no deben quedar tapados (foco).
        VantarisGuard.raise()
    }

    private fun scheduleIdleCheck() {
        handler.removeCallbacks(idleCheck)
        handler.postDelayed(idleCheck, IDLE_REMOVE_MS)
    }

    private val idleCheck = Runnable {
        if (items.isEmpty() && laserAt == 0L && focus == null &&
            SystemClock.uptimeMillis() - lastActivity >= IDLE_REMOVE_MS) {
            remove()
        } else {
            scheduleIdleCheck()
        }
    }

    fun remove() {
        handler.post {
            items.clear()
            focus = null
            laserAt = 0L
            view?.let { v -> try { windowManager?.removeView(v) } catch (_: Exception) {} }
            view = null
        }
    }

    private class DrawView(context: Context) : View(context) {
        private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeCap = Paint.Cap.ROUND
            strokeJoin = Paint.Join.ROUND
        }
        private val path = Path()
        private val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL }
        private val textPaint = TextPaint(Paint.ANTI_ALIAS_FLAG)
        private val rect = RectF()

        private fun withAlpha(c: Int, a: Float): Int =
            (((c ushr 24) and 0xff) * a).toInt().coerceIn(0, 255) shl 24 or (c and 0xffffff)

        override fun onDraw(canvas: Canvas) {
            val now = SystemClock.uptimeMillis()
            val w = width.toFloat()
            val h = height.toFloat()
            val shortSide = minOf(w, h)
            var animating = false

            focus?.let { f ->
                rect.set(f.left * w, f.top * h, f.right * w, f.bottom * h)
                path.reset()
                path.fillType = Path.FillType.EVEN_ODD
                path.addRect(0f, 0f, w, h, Path.Direction.CW)
                path.addRoundRect(rect, 8f, 8f, Path.Direction.CW)
                fill.color = 0x8C000000.toInt()
                canvas.drawPath(path, fill)
                path.fillType = Path.FillType.WINDING
                paint.color = 0xFF03B5A5.toInt()
                paint.strokeWidth = max(2f, shortSide * 0.004f)
                canvas.drawRoundRect(rect, 8f, 8f, paint)
            }

            val it = items.values.iterator()
            while (it.hasNext()) {
                val s = it.next()
                var alpha = 1f
                if (s.endedAt > 0) {
                    val age = now - s.endedAt
                    if (age > s.holdMs + FADE_MS) { it.remove(); continue }
                    if (age > s.holdMs) alpha = 1f - (age - s.holdMs).toFloat() / FADE_MS
                    animating = true
                }
                if (s.xs.isEmpty()) continue
                val c = withAlpha(s.color, alpha)
                val sw = max(2f, shortSide * s.widthPermille / 1000f)
                paint.color = c
                paint.strokeWidth = sw
                when (s.kind) {
                    Kind.STROKE -> {
                        path.reset()
                        path.moveTo(s.xs[0] * w, s.ys[0] * h)
                        if (s.xs.size == 1) path.lineTo(s.xs[0] * w + 0.1f, s.ys[0] * h)
                        for (i in 1 until s.xs.size) path.lineTo(s.xs[i] * w, s.ys[i] * h)
                        canvas.drawPath(path, paint)
                    }
                    Kind.SHAPE -> if (s.xs.size >= 2)
                        drawShape(canvas, s.shape, s.xs[0] * w, s.ys[0] * h, s.xs[1] * w, s.ys[1] * h, c, sw)
                    Kind.NUMBER -> drawNumber(canvas, s.xs[0] * w, s.ys[0] * h, s.label, s.color, alpha, shortSide)
                    Kind.TEXT -> drawText(canvas, s.xs[0] * w, s.ys[0] * h, s.label, s.color, alpha, shortSide)
                }
            }

            if (laserAt > 0) {
                if (now - laserAt >= LASER_MS) {
                    laserAt = 0L
                    trail.clear()
                } else {
                    trail.removeAll { now - it[0].toLong() > TRAIL_MS }
                    for (i in 1 until trail.size) {
                        val t = (1f - (now - trail[i][0].toLong()).toFloat() / TRAIL_MS).coerceIn(0f, 1f)
                        paint.color = Color.argb((0.55f * t * 255).toInt(), 255, 40, 40)
                        paint.strokeWidth = max(3f, shortSide * 0.008f) * max(0.3f, t)
                        canvas.drawLine(trail[i - 1][1] * w, trail[i - 1][2] * h, trail[i][1] * w, trail[i][2] * h, paint)
                    }
                    val cx = laserX * w
                    val cy = laserY * h
                    val r = maxOf(6f, shortSide * 0.009f)
                    fill.color = 0x46FF2828; canvas.drawCircle(cx, cy, r * 2.2f, fill)
                    fill.color = 0xEBFF1E1E.toInt(); canvas.drawCircle(cx, cy, r, fill)
                    fill.color = 0xFFFFDCDC.toInt(); canvas.drawCircle(cx, cy, r * 0.35f, fill)
                    animating = true
                }
            }
            // Mientras haya cosas caducando o el láser encendido, se sigue repintando.
            if (animating) postInvalidateDelayed(40)
        }

        private fun drawShape(canvas: Canvas, kind: Char, ax: Float, ay: Float, bx: Float, by: Float, c: Int, sw: Float) {
            rect.set(min(ax, bx), min(ay, by), max(ax, bx), max(ay, by))
            when (kind) {
                'R' -> canvas.drawRoundRect(rect, sw, sw, paint)
                'O' -> canvas.drawOval(rect, paint)
                'T' -> {
                    path.reset()
                    path.moveTo(rect.centerX(), rect.top)
                    path.lineTo(rect.right, rect.bottom)
                    path.lineTo(rect.left, rect.bottom)
                    path.close()
                    canvas.drawPath(path, paint)
                }
                'A' -> {
                    val dx = bx - ax
                    val dy = by - ay
                    val len = hypot(dx, dy)
                    if (len < 1f) return
                    val head = min(len * 0.6f, max(sw * 4f, 14f))
                    val ux = dx / len
                    val uy = dy / len
                    canvas.drawLine(ax, ay, bx - ux * head * 0.8f, by - uy * head * 0.8f, paint)
                    val ang = 0.5f
                    path.reset()
                    path.moveTo(bx, by)
                    for (s in floatArrayOf(1f, -1f)) {
                        path.lineTo(bx - head * (ux * cos(ang) - s * uy * sin(ang)),
                            by - head * (uy * cos(ang) + s * ux * sin(ang)))
                    }
                    path.close()
                    fill.color = c
                    canvas.drawPath(path, fill)
                }
                else -> canvas.drawLine(ax, ay, bx, by, paint)
            }
        }

        private fun drawNumber(canvas: Canvas, cx: Float, cy: Float, label: String, color: Int, alpha: Float, shortSide: Float) {
            val r = max(14f, shortSide * 0.022f)
            fill.color = withAlpha(0xF2FFFFFF.toInt(), alpha)
            canvas.drawCircle(cx, cy, r * 1.15f, fill)
            fill.color = withAlpha(color, alpha)
            canvas.drawCircle(cx, cy, r, fill)
            textPaint.color = withAlpha(if (luminance(color) > 0.5f) 0xFF111111.toInt() else Color.WHITE, alpha)
            textPaint.textSize = r * 1.15f
            textPaint.typeface = Typeface.DEFAULT_BOLD
            textPaint.textAlign = Paint.Align.CENTER
            val fm = textPaint.fontMetrics
            canvas.drawText(label, cx, cy - (fm.ascent + fm.descent) / 2f, textPaint)
        }

        private fun drawText(canvas: Canvas, x: Float, y: Float, label: String, color: Int, alpha: Float, shortSide: Float) {
            if (label.isEmpty()) return
            val size = max(14f, shortSide * 0.026f)
            textPaint.color = withAlpha(color, alpha)
            textPaint.textSize = size
            textPaint.typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            textPaint.textAlign = Paint.Align.LEFT
            val maxW = (shortSide * 0.9f).toInt()
            val natural = StaticLayout.getDesiredWidth(label, textPaint).toInt() + 1
            @Suppress("DEPRECATION")
            val layout = StaticLayout(label, textPaint, min(natural, maxW), Layout.Alignment.ALIGN_NORMAL, 1f, 0f, false)
            val pad = size * 0.4f
            rect.set(x, y - layout.height / 2f - pad, x + layout.width + pad * 2, y + layout.height / 2f + pad)
            fill.color = Color.argb((0.78f * alpha * 255).toInt(), 0, 0, 0)
            canvas.drawRoundRect(rect, pad, pad, fill)
            canvas.save()
            canvas.translate(x + pad, y - layout.height / 2f)
            layout.draw(canvas)
            canvas.restore()
        }

        private fun luminance(c: Int): Float {
            fun ch(v: Int): Float {
                val s = v / 255f
                return if (s <= 0.03928f) s / 12.92f else Math.pow(((s + 0.055f) / 1.055f).toDouble(), 2.4).toFloat()
            }
            return 0.2126f * ch((c shr 16) and 0xff) + 0.7152f * ch((c shr 8) and 0xff) + 0.0722f * ch(c and 0xff)
        }
    }
}
