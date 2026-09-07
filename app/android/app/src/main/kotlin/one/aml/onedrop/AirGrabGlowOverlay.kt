package one.aml.onedrop

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.BlendMode
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.RadialGradient
import android.graphics.Shader
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.view.animation.AccelerateDecelerateInterpolator
import android.widget.FrameLayout
import androidx.camera.view.PreviewView
import androidx.lifecycle.Lifecycle
import kotlin.math.min

/// Click-through yellow / red / green fog in the middle of the display.
/// Fog lives in its own overlay so CameraX cannot punch through it.
/// Honor / MagicOS starve ImageAnalysis unless Preview is a real on-screen
/// TextureView (not 1Ã—1 off-screen, not a dummy SurfaceTexture).
/// When Gallery is open the preview sits behind Flutter; on the home screen
/// it is a 24dp TextureView in the corner, covered so the fog stays clean.
object AirGrabGlowOverlay {
    private const val TAG = "AirGrab"
    private const val PREVIEW_DP = 24
    private val main = Handler(Looper.getMainLooper())
    private var fog: GlowView? = null
    private var previewHost: PreviewHost? = null
    private var fogOnActivity = false
    private var previewOnActivity = false

    fun show(context: Context, locked: Boolean = false) {
        val app = context.applicationContext
        main.post {
            val activity = DeviceBridge.activity()
            val wm = app.getSystemService(Context.WINDOW_SERVICE) as WindowManager
            ensureFog(app, wm, activity)
            fog?.setLocked(locked)
        }
    }

    /// Style only. Create the fog if the first show skipped it.
    fun setLocked(locked: Boolean) {
        main.post {
            val activity = DeviceBridge.activity()
            val app = activity?.applicationContext
            if (app != null) {
                val wm = app.getSystemService(Context.WINDOW_SERVICE) as WindowManager
                ensureFog(app, wm, activity)
            }
            fog?.setLocked(locked)
        }
    }

    /// Attach the CameraX PreviewView before [AirGrabTracker] binds, so Honor
    /// never starts on the dummy surface.
    fun prepareCameraPreview(context: Context) {
        val app = context.applicationContext
        if (Looper.myLooper() == Looper.getMainLooper()) {
            prepareNow(app)
        } else {
            main.post { prepareNow(app) }
        }
    }

    private fun prepareNow(app: Context) {
        val wm = app.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val activity = DeviceBridge.activity()
        ensurePreview(app, wm, activity)
    }

    fun hide(context: Context) {
        val app = context.applicationContext
        main.post {
            AirGrabTracker.unbindOverlayPreview()
            val activity = DeviceBridge.activity()
            val appWm = app.getSystemService(Context.WINDOW_SERVICE) as WindowManager
            val glow = fog
            fog = null
            glow?.release()
            if (glow != null) detach(glow, appWm, activity)
            fogOnActivity = false
            val preview = previewHost
            previewHost = null
            if (preview != null) detach(preview, appWm, activity)
            previewOnActivity = false
        }
    }

    private fun activityForeground(activity: MainActivity?): Boolean {
        if (activity == null || activity.isFinishing || activity.isDestroyed) {
            return false
        }
        return activity.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)
    }

    private fun overlayType(): Int {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }
    }

    private fun baseFlags(): Int {
        return WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
            WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
            WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
            WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS
    }

    private fun fogParams(useOverlay: Boolean): WindowManager.LayoutParams {
        val type = if (useOverlay) {
            overlayType()
        } else {
            WindowManager.LayoutParams.TYPE_APPLICATION
        }
        return WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
            type,
            baseFlags(),
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.CENTER
            title = "AirGrab target"
        }
    }

    private fun previewSizePx(ctx: Context): Int {
        return (PREVIEW_DP * ctx.resources.displayMetrics.density).toInt().coerceAtLeast(16)
    }

    private fun previewParams(app: Context, useOverlay: Boolean): WindowManager.LayoutParams {
        val type = if (useOverlay) {
            overlayType()
        } else {
            WindowManager.LayoutParams.TYPE_APPLICATION
        }
        val size = previewSizePx(app)
        val flags = WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
            WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
            WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
            WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS
        return WindowManager.LayoutParams(
            size,
            size,
            type,
            flags,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = 0
            y = 0
            title = "AirGrab camera"
        }
    }

    private fun ensureFog(
        app: Context,
        appWm: WindowManager,
        activity: MainActivity?,
    ) {
        if (fog != null) return
        val glow = GlowView(app)
        if (addTo(appWm, glow, fogParams(true))) {
            fog = glow
            fogOnActivity = false
            Log.i(TAG, "fog on overlay")
            return
        }
        if (activity != null && attachFogToActivity(activity, glow)) {
            fog = glow
            fogOnActivity = true
            Log.i(TAG, "fog on activity")
            return
        }
        glow.release()
        Log.e(TAG, "fog overlay failed canDraw=${canOverlay(app)}")
    }

    private fun ensurePreview(
        app: Context,
        appWm: WindowManager,
        activity: MainActivity?,
    ) {
        val current = previewHost
        if (current != null) {
            AirGrabTracker.attachOverlayPreview(current.preview)
            return
        }
        val host = PreviewHost(app)
        val onActivity = activityForeground(activity)
        if (onActivity && activity != null && attachPreviewToActivity(activity, host)) {
            bindHost(host, onActivity = true)
            return
        }
        if (addTo(appWm, host, previewParams(app, true))) {
            bindHost(host, onActivity = false)
            return
        }
        if (activity != null && attachPreviewToActivity(activity, host)) {
            bindHost(host, onActivity = true)
            return
        }
        Log.w(TAG, "preview overlay failed canDraw=${canOverlay(app)}")
    }

    private fun bindHost(host: PreviewHost, onActivity: Boolean) {
        previewHost = host
        previewOnActivity = onActivity
        AirGrabTracker.attachOverlayPreview(host.preview)
        host.preview.post { AirGrabTracker.ensureRunning() }
        Log.i(TAG, "preview ${host.preview.width}x${host.preview.height} activity=$onActivity")
    }

    private fun canOverlay(app: Context): Boolean {
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
            Settings.canDrawOverlays(app)
    }

    private fun attachFogToActivity(activity: MainActivity, view: View): Boolean {
        val content = activity.findViewById<ViewGroup>(android.R.id.content) ?: return false
        val lp = FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.MATCH_PARENT,
            Gravity.CENTER,
        )
        return try {
            content.addView(view, lp)
            true
        } catch (error: Exception) {
            Log.w(TAG, "fog addView failed", error)
            false
        }
    }

    private fun attachPreviewToActivity(activity: MainActivity, view: View): Boolean {
        val content = activity.findViewById<ViewGroup>(android.R.id.content) ?: return false
        val size = previewSizePx(activity)
        val lp = FrameLayout.LayoutParams(size, size, Gravity.TOP or Gravity.START)
        return try {
            // Behind Flutter so the camera feed is never visible.
            content.addView(view, 0, lp)
            true
        } catch (error: Exception) {
            Log.w(TAG, "preview addView failed", error)
            false
        }
    }

    private fun addTo(
        wm: WindowManager,
        view: View,
        params: WindowManager.LayoutParams,
    ): Boolean {
        return try {
            wm.addView(view, params)
            true
        } catch (error: Exception) {
            Log.w(TAG, "addView failed type=${params.type}", error)
            false
        }
    }

    private fun detach(view: View, appWm: WindowManager, activity: MainActivity?) {
        val parent = view.parent as? ViewGroup
        if (parent != null) {
            try {
                parent.removeView(view)
                return
            } catch (_: Exception) {
            }
        }
        try {
            if (activity != null) activity.windowManager.removeView(view)
        } catch (_: Exception) {
        }
        try {
            appWm.removeView(view)
        } catch (_: Exception) {
        }
    }

    private class PreviewHost(context: Context) : FrameLayout(context) {
        val preview: PreviewView = PreviewView(context).apply {
            // TextureView stays in the view tree. SurfaceView (PERFORMANCE)
            // is a separate window MagicOS culls when it is 1px or off-screen.
            implementationMode = PreviewView.ImplementationMode.COMPATIBLE
            scaleType = PreviewView.ScaleType.FILL_CENTER
            layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT)
        }

        init {
            importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
            // MagicOS needs a real on-screen TextureView. Cover it so the
            // catch fog is only the yellow/red/green glow.
            alpha = 1f
            addView(preview)
        }
    }

    private class GlowView(context: Context) : View(context) {
        private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        private var breath = 0.45f
        private var locked = false
        private val pulse = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = 1800
            repeatCount = ValueAnimator.INFINITE
            repeatMode = ValueAnimator.REVERSE
            interpolator = AccelerateDecelerateInterpolator()
            addUpdateListener {
                breath = it.animatedValue as Float
                invalidate()
            }
            start()
        }

        fun setLocked(next: Boolean) {
            if (locked == next) return
            locked = next
            pulse.duration = if (next) 1200L else 1800L
            invalidate()
        }

        fun release() {
            pulse.cancel()
        }

        override fun onDraw(canvas: Canvas) {
            val cx = width / 2f
            val cy = height / 2f
            val span = min(width, height).toFloat()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                paint.blendMode = BlendMode.SRC_OVER
            }
            if (locked) {
                val radius = span * (0.30f + breath * 0.08f)
                val inner = (0.62f + breath * 0.14f).coerceIn(0f, 1f)
                val mid = (0.26f + breath * 0.10f).coerceIn(0f, 1f)
                blob(canvas, cx - radius * 0.04f, cy - radius * 0.03f, radius, 0xFFE14A, inner, mid)
                blob(canvas, cx + radius * 0.10f, cy + radius * 0.06f, radius * 0.72f, 0x5CCBB4, inner * 0.55f, mid * 0.55f)
                blob(canvas, cx - radius * 0.08f, cy + radius * 0.08f, radius * 0.68f, 0x6FB1F0, inner * 0.48f, mid * 0.48f)
                return
            }
            val radius = span * (0.18f + breath * 0.03f)
            val inner = (0.52f + breath * 0.08f).coerceIn(0f, 1f)
            val mid = (0.18f + breath * 0.05f).coerceIn(0f, 1f)
            blob(canvas, cx, cy, radius, 0xF4F7FF, inner, mid)
        }

        private fun blob(
            canvas: Canvas,
            x: Float,
            y: Float,
            radius: Float,
            rgb: Int,
            inner: Float,
            mid: Float,
        ) {
            paint.shader = RadialGradient(
                x,
                y,
                radius,
                intArrayOf(
                    argb(inner, rgb),
                    argb(mid, rgb),
                    argb(0f, rgb),
                ),
                floatArrayOf(0f, 0.40f, 1f),
                Shader.TileMode.CLAMP,
            )
            canvas.drawCircle(x, y, radius, paint)
        }

        private fun argb(alpha: Float, rgb: Int): Int {
            val a = (alpha * 255f).toInt().coerceIn(0, 255)
            return (a shl 24) or (rgb and 0x00FFFFFF)
        }
    }
}

