package one.aml.onedrop

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Matrix
import android.graphics.SurfaceTexture
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.util.Log
import android.util.Size
import android.view.Surface
import android.view.WindowManager
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import com.google.common.util.concurrent.ListenableFuture
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.core.Delegate
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.facelandmarker.FaceLandmarker
import com.google.mediapipe.tasks.vision.handlandmarker.HandLandmarker
import io.flutter.embedding.engine.FlutterEngine
import kotlin.math.abs
import kotlin.math.atan2
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

/**
 * Front-camera analysis on a background executor. Frames are never saved.
 * Hands are MediaPipe Hand Landmarker (21 joints). Dart classifies palm vs fist.
 *
 * Bound to [GrabLife], not [MainActivity], so a permission dialog or Flutter
 * pause does not unbind analysis while Dart still wants frames.
 */
object AirGrabTracker : EventChannel.StreamHandler {
    private const val TAG = "AirGrab"
    private const val METHODS = "one.aml.onedrop/air_grab"
    private const val EVENTS = "one.aml.onedrop/air_grab/frames"
    private const val HAND_MODEL = "hand_landmarker.task"
    private const val FACE_MODEL = "face_landmarker.task"
    const val CAMERA_REQUEST = 75

    private val main = Handler(Looper.getMainLooper())
    private val analysis = Executors.newSingleThreadExecutor { runnable ->
        Thread({
            Process.setThreadPriority(Process.THREAD_PRIORITY_BACKGROUND)
            runnable.run()
        }, "airgrab-analysis")
    }
    private val running = AtomicBoolean(false)
    private val busy = AtomicBoolean(false)
    private val wantGaze = AtomicBoolean(false)
    private val bindGeneration = AtomicInteger(0)
    private val bindingInFlight = AtomicBoolean(false)
    private val grabLife = GrabLife()
    private var app: Context? = null
    private var sink: EventChannel.EventSink? = null
    private var boundProvider: ProcessCameraProvider? = null
    private var pendingStart: MethodChannel.Result? = null
    private var landmarker: HandLandmarker? = null
    private var faces: FaceLandmarker? = null
    private var dummyTexture: SurfaceTexture? = null
    private var dummySurface: Surface? = null
    private var overlayPreview: PreviewView? = null
    private var boundWithOverlay = false
    private var skip = 0
    private var lastTs = 0L
    private val pendingEvent = AtomicReference<Map<String, Any>?>(null)
    private val emitPosted = AtomicBoolean(false)

    fun attach(engine: FlutterEngine, app: Context) {
        this.app = app.applicationContext
        MethodChannel(engine.dartExecutor.binaryMessenger, METHODS)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasCamera" -> result.success(hasFrontCamera())
                    "setWantGaze" -> {
                        setWantGaze(call.arguments == true)
                        result.success(true)
                    }
                    "start" -> start(result)
                    "stop" -> {
                        stop()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
        EventChannel(engine.dartExecutor.binaryMessenger, EVENTS).setStreamHandler(this)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        Log.i(TAG, "event sink listening")
    }

    override fun onCancel(arguments: Any?) {
        sink = null
        Log.i(TAG, "event sink cancelled")
    }

    private fun emit(event: Any) {
        try {
            sink?.success(event)
        } catch (error: RuntimeException) {
            if (error.message?.contains("not attached to native") == true) {
                Log.w(TAG, "frame skipped: event sink not attached")
                return
            }
            throw error
        }
    }

    fun onPermission(granted: Boolean) {
        val result = pendingStart
        pendingStart = null
        Log.i(TAG, "camera permission granted=$granted")
        if (result == null) return
        if (!granted) {
            OneDropP2p.releaseRadioForCamera()
            result.success(false)
            return
        }
        if (!bindingInFlight.compareAndSet(false, true)) {
            result.success(true)
            return
        }
        val gen = bindGeneration.incrementAndGet()
        bindCamera(result, gen)
    }

    private fun hasFrontCamera(): Boolean {
        val ctx = app ?: return false
        val pm = ctx.packageManager
        return pm.hasSystemFeature(PackageManager.FEATURE_CAMERA_FRONT)
    }

    fun attachOverlayPreview(preview: PreviewView?) {
        if (overlayPreview === preview) return
        overlayPreview = preview
        if (preview != null) {
            Log.i(TAG, "overlay preview attached ${preview.width}x${preview.height}")
        }
    }

    fun onOverlayPreview(preview: PreviewView?) {
        attachOverlayPreview(preview)
        if (preview != null) {
            preview.post { ensureRunning() }
        }
    }

    /// Call on the main thread before the overlay PreviewView is removed.
    fun unbindOverlayPreview() {
        overlayPreview = null
        if (!boundWithOverlay) return
        bindGeneration.incrementAndGet()
        bindingInFlight.set(false)
        boundProvider?.unbindAll()
        boundProvider = null
        boundWithOverlay = false
        releaseDummyPreview()
        if (running.get()) {
            Log.i(TAG, "overlay preview gone; rebind dummy")
            ensureRunning()
        }
    }

    fun cameraBusy(): Boolean = pendingStart != null || running.get()

    private fun isXiaomiFamily(): Boolean {
        val maker = android.os.Build.MANUFACTURER.orEmpty().lowercase()
        val brand = android.os.Build.BRAND.orEmpty().lowercase()
        return maker.contains("xiaomi") || maker.contains("redmi") ||
            brand.contains("xiaomi") || brand.contains("redmi") ||
            brand.contains("poco")
    }

    /// Snapdragon 888 / 870 / 765: GPU MediaPipe ANRs, CPU MediaPipe
    /// saturates Recents unless frames stay tiny. Catch never loads
    /// Face Landmarker â€” a fist does not need a face.
    private fun liteInference(): Boolean {
        if (isXiaomiFamily()) return true
        val hw = android.os.Build.HARDWARE.orEmpty().lowercase()
        return hw.contains("lahaina") || hw.contains("kona") || hw.contains("lito")
    }

    private fun allowGpuDelegate(): Boolean {
        return !liteInference()
    }

    private fun analysisSize(): Size {
        return if (liteInference()) Size(320, 240) else Size(640, 480)
    }

    fun setWantGaze(on: Boolean) {
        val was = wantGaze.getAndSet(on)
        if (on) {
            val ctx = app ?: return
            analysis.execute { ensureLandmarker(ctx) }
            return
        }
        if (!was) return
        analysis.execute {
            try {
                faces?.close()
            } catch (e: Throwable) {
                Log.w(TAG, "face close", e)
            }
            faces = null
        }
    }

    /// Honor / MagicOS starve ImageAnalysis unless Preview is a real view.
    /// Xiaomi HyperOS is fine with a dummy SurfaceTexture â€” attaching a
    /// PreviewView and then calling [ensureRunning] used to bump
    /// [bindGeneration] and abort the Dart start that was still binding.
    fun needsOnScreenPreview(): Boolean {
        val maker = android.os.Build.MANUFACTURER.orEmpty().lowercase()
        return maker.contains("honor") || maker.contains("huawei")
    }

    fun ensureRunning() {
        if (bindingInFlight.get() || pendingStart != null) {
            Log.i(TAG, "ensureRunning: bind already in flight")
            return
        }
        if (running.get() && boundProvider != null) {
            if (overlayPreview != null && !boundWithOverlay && needsOnScreenPreview()) {
                Log.i(TAG, "ensureRunning: upgrade dummy to overlay")
                start(NoopResult)
            }
            return
        }
        if (overlayPreview != null || needsOnScreenPreview()) {
            Log.i(TAG, "ensureRunning: start from overlay")
            start(NoopResult)
            return
        }
        Log.i(TAG, "ensureRunning: nothing to bind")
    }

    private fun start(result: MethodChannel.Result) {
        val host = DeviceBridge.activity()
        val ctx = host ?: app
        if (ctx == null || !hasFrontCamera()) {
            Log.w(TAG, "start refused: ctx=${ctx != null} front=${hasFrontCamera()}")
            result.success(false)
            return
        }
        if (ContextCompat.checkSelfPermission(ctx, Manifest.permission.CAMERA) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            if (host == null) {
                Log.w(TAG, "start: no activity for CAMERA permission")
                result.success(false)
                return
            }
            Log.i(TAG, "start: requesting CAMERA")
            pendingStart = result
            OneDropP2p.holdRadioForCamera()
            host.requestCameraPermission()
            return
        }
        OneDropListenService.setCameraWatch(ctx, true)
        val honorPreview = needsOnScreenPreview()
        if (honorPreview && overlayPreview == null) {
            AirGrabGlowOverlay.prepareCameraPreview(ctx)
        }
        val wantOverlay = honorPreview && overlayPreview != null
        if (running.get() && boundProvider != null && boundWithOverlay == wantOverlay) {
            Log.i(TAG, "start: already bound overlay=$wantOverlay")
            OneDropP2p.releaseRadioForCamera()
            result.success(true)
            return
        }
        if (!bindingInFlight.compareAndSet(false, true)) {
            Log.i(TAG, "start: bind already in flight")
            result.success(true)
            return
        }
        val gen = bindGeneration.incrementAndGet()
        OneDropP2p.holdRadioForCamera()
        if (honorPreview) {
            waitForOverlayThenBind(result, gen, 0)
            return
        }
        bindCamera(result, gen)
    }

    private fun waitForOverlayThenBind(
        result: MethodChannel.Result,
        gen: Int,
        attempt: Int,
    ) {
        if (gen != bindGeneration.get()) {
            Log.i(TAG, "overlay wait skipped stale gen=$gen")
            result.success(false)
            return
        }
        val overlay = overlayPreview
        if (overlay != null && overlay.width >= 16 && overlay.height >= 16) {
            bindCamera(result, gen)
            return
        }
        if (attempt >= 12) {
            Log.w(
                TAG,
                "overlay never sized w=${overlay?.width ?: 0} h=${overlay?.height ?: 0}; bind anyway",
            )
            bindCamera(result, gen)
            return
        }
        if (attempt == 0) {
            Log.i(TAG, "start: waiting for overlay preview to layout")
        }
        main.postDelayed({ waitForOverlayThenBind(result, gen, attempt + 1) }, 50)
    }

    private fun noteBindDone(gen: Int) {
        if (gen == bindGeneration.get()) bindingInFlight.set(false)
    }

    private fun bindCamera(result: MethodChannel.Result, gen: Int) {
        val ctx = app
        if (ctx == null) {
            Log.e(TAG, "bind: no app context")
            noteBindDone(gen)
            OneDropP2p.releaseRadioForCamera()
            result.success(false)
            return
        }
        if (gen != bindGeneration.get()) {
            Log.i(TAG, "bind skipped stale gen=$gen")
            result.success(false)
            return
        }
        OneDropListenService.setCameraWatch(ctx, true)
        val alreadyOverlay = overlayPreview != null
        if (running.get() && boundProvider != null && boundWithOverlay == alreadyOverlay) {
            Log.i(TAG, "start: already bound overlay=$alreadyOverlay")
            noteBindDone(gen)
            OneDropP2p.releaseRadioForCamera()
            result.success(true)
            return
        }
        val future: ListenableFuture<ProcessCameraProvider> =
            ProcessCameraProvider.getInstance(ctx)
        future.addListener(
            {
                try {
                    if (gen != bindGeneration.get()) {
                        Log.i(TAG, "bind listener skipped stale gen=$gen")
                        result.success(false)
                        return@addListener
                    }
                    val cameraProvider = future.get()
                    cameraProvider.unbindAll()
                    if (gen != bindGeneration.get()) {
                        Log.i(TAG, "bind aborted after unbind stale gen=$gen")
                        result.success(false)
                        return@addListener
                    }
                    grabLife.markResumed()
                    val rotation = screenRotation(ctx)
                    val analysisUseCase = ImageAnalysis.Builder()
                        .setTargetRotation(rotation)
                        .setResolutionSelector(
                            ResolutionSelector.Builder()
                                .setResolutionStrategy(
                                    ResolutionStrategy(
                                        analysisSize(),
                                        ResolutionStrategy.FALLBACK_RULE_CLOSEST_LOWER_THEN_HIGHER,
                                    ),
                                )
                                .build(),
                        )
                        .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                        .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_YUV_420_888)
                        .build()
                    analysisUseCase.setAnalyzer(analysis, ::analyze)
                    val preview = livePreview(ctx)
                    cameraProvider.bindToLifecycle(
                        grabLife,
                        CameraSelector.DEFAULT_FRONT_CAMERA,
                        preview,
                        analysisUseCase,
                    )
                    if (gen != bindGeneration.get()) {
                        Log.i(TAG, "bind discarded after attach stale gen=$gen")
                        cameraProvider.unbindAll()
                        result.success(false)
                        return@addListener
                    }
                    boundProvider = cameraProvider
                    boundWithOverlay = overlayPreview != null
                    running.set(true)
                    skip = 0
                    analysis.execute { ensureLandmarker(ctx) }
                    val bound = analysisUseCase.resolutionInfo?.resolution
                    val overlay = overlayPreview
                    Log.i(
                        TAG,
                        "bound front camera analysis=$bound overlay=$boundWithOverlay " +
                            "preview=${overlay?.width ?: 0}x${overlay?.height ?: 0}",
                    )
                    OneDropP2p.releaseRadioForCamera()
                    noteBindDone(gen)
                    result.success(true)
                } catch (e: Exception) {
                    Log.e(TAG, "bind failed", e)
                    if (gen == bindGeneration.get()) {
                        running.set(false)
                        releaseDummyPreview()
                        OneDropListenService.setCameraWatch(ctx, false)
                        OneDropP2p.releaseRadioForCamera()
                        bindingInFlight.set(false)
                    }
                    result.success(false)
                }
            },
            ContextCompat.getMainExecutor(ctx),
        )
    }

    /// Honor / MagicOS starve ImageAnalysis unless Preview is a real view in
    /// a visible window. Prefer the catch overlay; fall back to a dummy surface.
    private fun livePreview(ctx: Context): Preview {
        val overlay = overlayPreview
        if (overlay != null) {
            releaseDummyPreview()
            val rotation = screenRotation(ctx)
            return Preview.Builder()
                .setTargetRotation(rotation)
                .build()
                .also { preview ->
                    preview.setSurfaceProvider(overlay.surfaceProvider)
                }
        }
        return dummyPreview(ctx)
    }

    @Suppress("DEPRECATION")
    private fun screenRotation(ctx: Context): Int {
        val wm = ctx.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        return wm.defaultDisplay.rotation
    }

    private fun dummyPreview(ctx: Context): Preview {
        releaseDummyPreview()
        @Suppress("DEPRECATION")
        val texture = SurfaceTexture(0)
        val size = analysisSize()
        texture.setDefaultBufferSize(size.width, size.height)
        val surface = Surface(texture)
        dummyTexture = texture
        dummySurface = surface
        return Preview.Builder().build().also { preview ->
            preview.setSurfaceProvider { request ->
                val out = dummySurface
                if (out == null || !out.isValid) {
                    request.willNotProvideSurface()
                    return@setSurfaceProvider
                }
                request.provideSurface(out, ContextCompat.getMainExecutor(ctx)) { }
            }
        }
    }

    private fun releaseDummyPreview() {
        dummySurface?.release()
        dummyTexture?.release()
        dummySurface = null
        dummyTexture = null
    }

    fun stop() {
        val gen = bindGeneration.incrementAndGet()
        bindingInFlight.set(false)
        running.set(false)
        skip = 0
        val cameraProvider = boundProvider
        boundProvider = null
        boundWithOverlay = false
        val ctx = app
        val unbind = Runnable {
            if (gen != bindGeneration.get()) {
                Log.i(TAG, "stop unbind skipped stale gen=$gen")
                return@Runnable
            }
            grabLife.markCreated()
            cameraProvider?.unbindAll()
            releaseDummyPreview()
            if (ctx != null) OneDropListenService.setCameraWatch(ctx, false)
            OneDropP2p.releaseRadioForCamera()
            analysis.execute { closeLandmarker() }
            Log.i(TAG, "stop unbound")
        }
        if (Looper.myLooper() == Looper.getMainLooper()) {
            unbind.run()
        } else {
            main.post(unbind)
        }
    }

    private fun emitLatest(event: Map<String, Any>) {
        pendingEvent.set(event)
        if (!emitPosted.compareAndSet(false, true)) return
        main.post {
            emitPosted.set(false)
            val next = pendingEvent.getAndSet(null) ?: return@post
            emit(next)
        }
    }

    private fun analyze(image: ImageProxy) {
        try {
            if (!running.get()) return
            if (!busy.compareAndSet(false, true)) return
            try {
                skip++
                val stride = if (liteInference()) 8 else 1
                if (skip % stride != 0) return
                val event = classify(image)
                if (skip % 40 == 0) {
                    Log.d(
                        TAG,
                        "frame ${image.width}x${image.height} " +
                            "hands=${if (event["points"] != null) 1 else 0} " +
                            "gaze=${wantGaze.get()} look=${event["looking"]} " +
                            "in=${event["inFrame"]}",
                    )
                }
                emitLatest(event)
            } finally {
                busy.set(false)
            }
        } catch (e: Throwable) {
            Log.e(TAG, "analyze failed", e)
            emitLatest(hashMapOf<String, Any>("shape" to "none", "inFrame" to false))
        } finally {
            image.close()
        }
    }

    private fun classify(image: ImageProxy): Map<String, Any> {
        val event = hashMapOf<String, Any>(
            "shape" to "none",
            "inFrame" to false,
        )
        val marker = landmarker
        val bitmap = inferBitmap(image)
        val mpImage = BitmapImageBuilder(bitmap).build()
        val ts = nextTimestamp(image)
        try {
            if (wantGaze.get()) putGaze(event, mpImage, ts)
            if (marker == null) return event
            val result = marker.detectForVideo(mpImage, ts)
            val hands = result.landmarks()
            if (hands.isEmpty() || hands[0].size < 21) return event
            val pts = ArrayList<Any>(21)
            for (i in 0 until 21) {
                val lm = hands[0][i]
                pts.add(listOf(lm.x().toDouble(), lm.y().toDouble()))
            }
            event["points"] = pts
            event["inFrame"] = true
            return event
        } finally {
            mpImage.close()
            if (!bitmap.isRecycled) bitmap.recycle()
        }
    }

    private fun putGaze(event: HashMap<String, Any>, mpImage: com.google.mediapipe.framework.image.MPImage, ts: Long) {
        val marker = faces ?: return
        try {
            val result = marker.detectForVideo(mpImage, ts)
            val faces = result.faceLandmarks()
            event["gaze"] = true
            if (faces.isEmpty()) {
                event["face"] = false
                event["looking"] = false
                event["attention"] = 0.0
                event["yaw"] = 0.0
                event["pitch"] = 0.0
                return
            }
            var yaw = 0.0
            var pitch = 0.0
            val matricesOpt = result.facialTransformationMatrixes()
            if (matricesOpt.isPresent) {
                val matrices = matricesOpt.get()
                if (matrices.isNotEmpty() && matrices[0].size >= 16) {
                    val m = matrices[0]
                    yaw = atan2(m[8].toDouble(), m[0].toDouble())
                    pitch = atan2(-m[9].toDouble(), m[10].toDouble())
                }
            }
            val yScore = (1.0 - (abs(yaw) / 0.70).coerceIn(0.0, 1.0))
            val pScore = (1.0 - (abs(pitch) / 0.55).coerceIn(0.0, 1.0))
            val attention = yScore * pScore
            event["face"] = true
            event["yaw"] = yaw
            event["pitch"] = pitch
            event["attention"] = attention
            event["looking"] = attention >= 0.38
        } catch (e: Throwable) {
            Log.w(TAG, "face detect", e)
        }
    }

    private fun inferBitmap(image: ImageProxy): Bitmap {
        val upright = uprightBitmap(image)
        if (!liteInference()) return upright
        val maxEdge = 256
        val w = upright.width
        val h = upright.height
        if (w <= maxEdge && h <= maxEdge) return upright
        val scale = maxEdge.toFloat() / maxOf(w, h)
        val nw = (w * scale).toInt().coerceAtLeast(64)
        val nh = (h * scale).toInt().coerceAtLeast(64)
        val out = Bitmap.createScaledBitmap(upright, nw, nh, false)
        if (out != upright && !upright.isRecycled) upright.recycle()
        return out
    }

    private fun uprightBitmap(image: ImageProxy): Bitmap {
        val src = image.toBitmap()
        val deg = image.imageInfo.rotationDegrees
        if (deg == 0) return src
        val matrix = Matrix()
        matrix.postRotate(deg.toFloat())
        val out = Bitmap.createBitmap(src, 0, 0, src.width, src.height, matrix, false)
        if (out != src && !src.isRecycled) src.recycle()
        return out
    }

    private fun ensureLandmarker(ctx: Context) {
        if (landmarker == null) {
            // GPU MediaPipe wedges CameraX on Snapdragon 888 (Mi 11 Ultra).
            landmarker = createLandmarker(ctx, Delegate.CPU)
            if (landmarker == null && allowGpuDelegate()) {
                landmarker = createLandmarker(ctx, Delegate.GPU)
            }
            if (landmarker == null) {
                Log.e(TAG, "hand landmarker failed to load")
            } else {
                Log.i(TAG, "hand landmarker ready")
            }
        }
        if (wantGaze.get() && faces == null) {
            faces = createFaceLandmarker(ctx, Delegate.CPU)
            if (faces == null && allowGpuDelegate()) {
                faces = createFaceLandmarker(ctx, Delegate.GPU)
            }
            if (faces == null) {
                Log.w(TAG, "face landmarker failed to load")
            } else {
                Log.i(TAG, "face landmarker ready")
            }
        }
    }

    private fun createLandmarker(ctx: Context, delegate: Delegate): HandLandmarker? {
        return try {
            val options = HandLandmarker.HandLandmarkerOptions.builder()
                .setBaseOptions(
                    BaseOptions.builder()
                        .setModelAssetPath(HAND_MODEL)
                        .setDelegate(delegate)
                        .build(),
                )
                .setRunningMode(RunningMode.VIDEO)
                .setNumHands(1)
                .setMinHandDetectionConfidence(0.5f)
                .setMinHandPresenceConfidence(0.5f)
                .setMinTrackingConfidence(0.5f)
                .build()
            HandLandmarker.createFromOptions(ctx, options)
        } catch (e: Throwable) {
            Log.w(TAG, "landmarker delegate=$delegate failed", e)
            null
        }
    }

    private fun createFaceLandmarker(ctx: Context, delegate: Delegate): FaceLandmarker? {
        return try {
            val options = FaceLandmarker.FaceLandmarkerOptions.builder()
                .setBaseOptions(
                    BaseOptions.builder()
                        .setModelAssetPath(FACE_MODEL)
                        .setDelegate(delegate)
                        .build(),
                )
                .setRunningMode(RunningMode.VIDEO)
                .setNumFaces(1)
                .setMinFaceDetectionConfidence(0.5f)
                .setMinFacePresenceConfidence(0.5f)
                .setMinTrackingConfidence(0.5f)
                .setOutputFacialTransformationMatrixes(true)
                .build()
            FaceLandmarker.createFromOptions(ctx, options)
        } catch (e: Throwable) {
            Log.w(TAG, "face landmarker delegate=$delegate failed", e)
            null
        }
    }

    private fun nextTimestamp(image: ImageProxy): Long {
        var ts = image.imageInfo.timestamp / 1_000_000L
        if (ts <= lastTs) ts = lastTs + 16
        lastTs = ts
        return ts
    }

    private fun closeLandmarker() {
        try {
            landmarker?.close()
        } catch (e: Throwable) {
            Log.w(TAG, "landmarker close", e)
        }
        try {
            faces?.close()
        } catch (e: Throwable) {
            Log.w(TAG, "face close", e)
        }
        landmarker = null
        faces = null
        lastTs = 0L
    }
}

/** Stays RESUMED until [AirGrabTracker.stop], independent of the Activity. */
private class GrabLife : LifecycleOwner {
    private val registry = LifecycleRegistry(this)

    init {
        registry.currentState = Lifecycle.State.INITIALIZED
        registry.currentState = Lifecycle.State.CREATED
    }

    fun markResumed() {
        if (registry.currentState == Lifecycle.State.DESTROYED) return
        if (!registry.currentState.isAtLeast(Lifecycle.State.STARTED)) {
            registry.currentState = Lifecycle.State.STARTED
        }
        registry.currentState = Lifecycle.State.RESUMED
    }

    fun markCreated() {
        if (registry.currentState == Lifecycle.State.DESTROYED) return
        if (registry.currentState.isAtLeast(Lifecycle.State.STARTED)) {
            registry.currentState = Lifecycle.State.CREATED
        }
    }

    override val lifecycle: Lifecycle
        get() = registry
}

private object NoopResult : MethodChannel.Result {
    override fun success(result: Any?) {}

    override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {}

    override fun notImplemented() {}
}

