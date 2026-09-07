package one.aml.onedrop

import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.net.Uri
import androidx.core.content.FileProvider
import android.os.Build
import android.os.Handler
import android.provider.Settings
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.Surface
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.FlutterJNI
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.embedding.engine.loader.FlutterLoader
import io.flutter.FlutterInjector
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant
import java.io.File
import java.lang.ref.WeakReference
import java.nio.ByteBuffer
import java.util.concurrent.Executors

object OneDropEngine {
    const val ID = "onedrop"
    private const val TAG = "OneDropEngine"
    private const val RECOVER_MS = 2500L
    private val main = Handler(Looper.getMainLooper())
    private var lastRecoverAt = 0L

    @Synchronized
    fun get(context: Context): FlutterEngine {
        val cache = FlutterEngineCache.getInstance()
        cache.get(ID)?.let { existing ->
            if (nativeAlive(existing)) return existing
            Log.w(TAG, "cached engine JNI is gone — replacing")
            drop(existing)
        }
        val app = context.applicationContext
        val loader: FlutterLoader = FlutterInjector.instance().flutterLoader()
        if (!loader.initialized()) {
            loader.startInitialization(app)
            loader.ensureInitializationComplete(app, null)
        }
        val engine = FlutterEngine(app, loader, GuardedFlutterJni())
        engine.addEngineLifecycleListener(
            object : FlutterEngine.EngineLifecycleListener {
                override fun onPreEngineRestart() {}
                override fun onEngineWillDestroy() {
                    cache.remove(ID)
                }
            },
        )
        GeneratedPluginRegistrant.registerWith(engine)
        DeviceBridge.attach(engine, app)
        AirGrabTracker.attach(engine, app)
        OneDropP2p.attach(engine, app)
        if (!engine.dartExecutor.isExecutingDart) {
            engine.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint.createDefault(),
            )
        }
        cache.put(ID, engine)
        return engine
    }

    @Synchronized
    fun discard() {
        drop(FlutterEngineCache.getInstance().get(ID) ?: return)
    }

    fun noteDetached() {
        val cached = FlutterEngineCache.getInstance().get(ID) ?: return
        Log.w(TAG, "JNI detached while a FlutterView still thought it was attached")
        drop(cached)
        val activity = DeviceBridge.activity() ?: return
        if (activity.isFinishing || activity.isDestroyed) return
        val now = SystemClock.uptimeMillis()
        if (now - lastRecoverAt < RECOVER_MS) return
        lastRecoverAt = now
        main.post {
            if (!activity.isFinishing && !activity.isDestroyed) {
                activity.recreate()
            }
        }
    }

    private fun drop(engine: FlutterEngine) {
        FlutterEngineCache.getInstance().remove(ID)
        try {
            engine.destroy()
        } catch (error: Exception) {
            Log.w(TAG, "engine.destroy after JNI detach", error)
        }
    }

    private fun nativeAlive(engine: FlutterEngine): Boolean {
        return try {
            val field = FlutterEngine::class.java.getDeclaredField("flutterJNI")
            field.isAccessible = true
            val jni = field.get(engine) as FlutterJNI
            jni.isAttached
        } catch (_: Exception) {
            engine.dartExecutor.isExecutingDart
        }
    }
}

/**
 * USB unplug on HyperOS resizes the window after native has already detached.
 * FlutterView still thinks it is attached and [FlutterJNI.setViewportMetrics]
 * throws. Skip those calls instead of crashing.
 */
private class GuardedFlutterJni : FlutterJNI() {
    override fun setViewportMetrics(
        devicePixelRatio: Float,
        physicalWidth: Int,
        physicalHeight: Int,
        physicalPaddingTop: Int,
        physicalPaddingRight: Int,
        physicalPaddingBottom: Int,
        physicalPaddingLeft: Int,
        physicalViewInsetTop: Int,
        physicalViewInsetRight: Int,
        physicalViewInsetBottom: Int,
        physicalViewInsetLeft: Int,
        systemGestureInsetTop: Int,
        systemGestureInsetRight: Int,
        systemGestureInsetBottom: Int,
        systemGestureInsetLeft: Int,
        physicalTouchSlop: Int,
        displayFeaturesBounds: IntArray,
        displayFeaturesType: IntArray,
        displayFeaturesState: IntArray,
        minWidth: Int,
        maxWidth: Int,
        minHeight: Int,
        maxHeight: Int,
    ) {
        ifAlive("viewport") {
            super.setViewportMetrics(
                devicePixelRatio,
                physicalWidth,
                physicalHeight,
                physicalPaddingTop,
                physicalPaddingRight,
                physicalPaddingBottom,
                physicalPaddingLeft,
                physicalViewInsetTop,
                physicalViewInsetRight,
                physicalViewInsetBottom,
                physicalViewInsetLeft,
                systemGestureInsetTop,
                systemGestureInsetRight,
                systemGestureInsetBottom,
                systemGestureInsetLeft,
                physicalTouchSlop,
                displayFeaturesBounds,
                displayFeaturesType,
                displayFeaturesState,
                minWidth,
                maxWidth,
                minHeight,
                maxHeight,
            )
        }
    }

    override fun onSurfaceCreated(surface: Surface) {
        ifAlive("surfaceCreated") { super.onSurfaceCreated(surface) }
    }

    override fun onSurfaceWindowChanged(surface: Surface) {
        ifAlive("surfaceWindow") { super.onSurfaceWindowChanged(surface) }
    }

    override fun onSurfaceChanged(width: Int, height: Int) {
        ifAlive("surfaceChanged") { super.onSurfaceChanged(width, height) }
    }

    override fun onSurfaceDestroyed() {
        ifAlive("surfaceDestroyed") { super.onSurfaceDestroyed() }
    }

    override fun dispatchPointerDataPacket(buffer: ByteBuffer, position: Int) {
        ifAlive("pointer") { super.dispatchPointerDataPacket(buffer, position) }
    }

    private fun ifAlive(what: String, block: () -> Unit) {
        if (!isAttached) {
            Log.w("OneDropEngine", "skip $what: FlutterJNI not attached")
            OneDropEngine.noteDetached()
            return
        }
        try {
            block()
        } catch (error: RuntimeException) {
            if (error.message?.contains("not attached to native") == true) {
                Log.w("OneDropEngine", "skip $what after JNI detach", error)
                OneDropEngine.noteDetached()
                return
            }
            throw error
        }
    }
}

object DeviceBridge {
    const val CHANNEL = "one.aml.onedrop/device"
    const val PREFS = "onedrop_listen"
    const val PREF_ENABLED = "enabled"

    private var activity: WeakReference<MainActivity>? = null
    private var app: Context? = null
    private var channel: MethodChannel? = null
    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()
    @Volatile
    private var peerCache: List<Map<String, Any>> = emptyList()

    fun deviceName(ctx: Context?): String {
        if (ctx == null) return Build.MODEL?.trim().orEmpty()
        val resolver = ctx.contentResolver
        val fromGlobal = try {
            Settings.Global.getString(resolver, Settings.Global.DEVICE_NAME)
        } catch (_: Exception) {
            null
        }
        val fromBluetooth = try {
            Settings.Secure.getString(resolver, "bluetooth_name")
        } catch (_: Exception) {
            null
        }
        val candidates = listOfNotNull(
            fromGlobal,
            fromBluetooth,
            Build.MODEL,
            Build.MANUFACTURER,
        )
        return candidates
            .map { it.trim() }
            .firstOrNull { it.isNotEmpty() && !it.equals("localhost", ignoreCase = true) }
            .orEmpty()
    }

    fun cachedPeers(): List<Map<String, Any>> = peerCache

    @Suppress("UNCHECKED_CAST")
    fun cachePeers(raw: Any?) {
        val list = raw as? List<*> ?: emptyList<Any>()
        peerCache = list.mapNotNull { row ->
            val map = row as? Map<*, *> ?: return@mapNotNull null
            val id = (map["id"] as? String)?.trim().orEmpty()
            val host = (map["host"] as? String)?.trim().orEmpty()
            val port = (map["port"] as? Number)?.toInt() ?: 0
            if (id.isEmpty() || host.isEmpty() || port <= 0) return@mapNotNull null
            mapOf(
                "id" to id,
                "name" to ((map["name"] as? String) ?: ""),
                "host" to host,
                "port" to port,
            )
        }
    }

    fun attach(engine: FlutterEngine, app: Context) {
        this.app = app.applicationContext
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        channel?.setMethodCallHandler { call, result ->
            val host = activity?.get()
            when (call.method) {
                "getSdkInt" -> result.success(Build.VERSION.SDK_INT)
                "getDeviceName" -> result.success(deviceName(this.app ?: host))
                "getManufacturer" ->
                    result.success(Build.MANUFACTURER?.trim().orEmpty())
                "isGalleryInstalled" ->
                    result.success(
                        isPackageInstalled(this.app ?: host, MainActivity.GALLERY),
                    )
                "takePendingShares" ->
                    result.success(host?.takePendingShares() ?: emptyList<String>())
                "copyContentUri" -> {
                    val uri = call.argument<String>("uri").orEmpty()
                    val name = call.argument<String>("name").orEmpty()
                    io.execute {
                        val path = host?.copyContentUri(uri, name)
                        main.post { result.success(path) }
                    }
                }
                "handoffMediaToGallery" -> {
                    val ctx = this.app ?: host
                    if (ctx == null) {
                        result.error("no_context", "Cannot hand off to Gallery", null)
                        return@setMethodCallHandler
                    }
                    val paths = strings(call.argument("paths"))
                    val kinds = strings(call.argument("kinds"))
                    result.success(handoffMediaToGallery(ctx, paths, kinds))
                }
                "scanMedia" -> {
                    val ctx = this.app ?: host
                    val path = call.argument<String>("path").orEmpty()
                    if (ctx == null || path.isEmpty()) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    MediaScannerConnection.scanFile(ctx, arrayOf(path), null, null)
                    result.success(true)
                }
                "publishPeers" -> {
                    cachePeers(call.argument("peers"))
                    result.success(true)
                }
                "startOneDropListen" -> {
                    val ctx = this.app ?: host
                    if (ctx == null) {
                        result.error("no_context", "Cannot start OneDrop listen", null)
                        return@setMethodCallHandler
                    }
                    setListenEnabled(ctx, true)
                    host?.requestListenNotifications()
                    OneDropListenService.start(ctx)
                    result.success(true)
                }
                "stopOneDropListen" -> {
                    val ctx = this.app ?: host
                    if (ctx != null) {
                        setListenEnabled(ctx, false)
                        OneDropListenService.stop(ctx)
                    }
                    result.success(true)
                }
                "notifyIncomingDrop" -> {
                    val ctx = this.app ?: host
                    if (ctx == null) {
                        result.error("no_context", "Cannot notify", null)
                        return@setMethodCallHandler
                    }
                    OneDropListenService.notifyIncoming(
                        ctx,
                        call.argument<String>("offerId").orEmpty(),
                        call.argument<String>("peerName").orEmpty(),
                        call.argument<String>("summary").orEmpty(),
                    )
                    result.success(true)
                }
                "cancelIncomingDrop" -> {
                    val ctx = this.app ?: host
                    if (ctx != null) {
                        OneDropListenService.cancelIncoming(
                            ctx,
                            call.argument<String>("offerId").orEmpty(),
                        )
                    }
                    result.success(true)
                }
                "notifyDropReceived" -> {
                    val ctx = this.app ?: host
                    if (ctx != null) {
                        OneDropListenService.notifyReceived(
                            ctx,
                            call.argument<String>("message").orEmpty(),
                        )
                    }
                    result.success(true)
                }
                "notifyAirGrabCatch" -> {
                    val ctx = this.app ?: host
                    if (ctx != null) {
                        OneDropListenService.notifyAirGrabCatch(
                            ctx,
                            call.argument<String>("message").orEmpty(),
                            call.argument<Boolean>("locked") ?: false,
                        )
                    }
                    result.success(true)
                }
                "setAirGrabCatchLocked" -> {
                    val ctx = this.app ?: host
                    if (ctx != null) {
                        OneDropListenService.setAirGrabCatchLocked(
                            ctx,
                            call.argument<Boolean>("locked") ?: false,
                        )
                    }
                    result.success(true)
                }
                "hideAirGrabCatch" -> {
                    val ctx = this.app ?: host
                    if (ctx != null) {
                        OneDropListenService.hideAirGrabCatch(ctx)
                    }
                    result.success(true)
                }
                "requestAirGrabOverlay" -> {
                    host?.requestAirGrabOverlay(
                        call.argument<Boolean>("force") ?: false,
                    )
                    result.success(true)
                }
                "ensureFirstRunPermissions" -> {
                    if (host == null) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    host.ensureFirstRunPermissions(result)
                }
                "listFavoriteSources" -> {
                    val ctx = this.app ?: host
                    if (ctx == null) {
                        result.error("no_context", "Cannot list favorites", null)
                        return@setMethodCallHandler
                    }
                    io.execute {
                        val payload = listFavoriteSources(ctx)
                        main.post { result.success(payload) }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    fun bindActivity(activity: MainActivity) {
        this.activity = WeakReference(activity)
    }

    fun activity(): MainActivity? = activity?.get()

    fun setListenEnabled(context: Context, enabled: Boolean) {
        context.applicationContext
            .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(PREF_ENABLED, enabled)
            .apply()
    }

    fun listenEnabled(context: Context): Boolean {
        return context.applicationContext
            .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getBoolean(PREF_ENABLED, false)
    }

    fun mediaStoreWriteFinished(ok: Boolean) {
        main.post {
            invoke("mediaStoreWriteFinished", ok)
        }
    }

    private fun strings(raw: Any?): List<String> {
        val list = raw as? List<*> ?: return emptyList()
        return list.mapNotNull { it as? String }
    }

    private fun bools(raw: Any?): List<Boolean> {
        val list = raw as? List<*> ?: return emptyList()
        return list.map { it == true }
    }

    fun decideDrop(offerId: String, accept: Boolean) {
        main.post {
            invoke(
                "decideDrop",
                mapOf("offerId" to offerId, "accept" to accept),
            )
        }
    }

    private fun invoke(method: String, arguments: Any?) {
        try {
            channel?.invokeMethod(method, arguments)
        } catch (error: RuntimeException) {
            if (error.message?.contains("not attached to native") == true) {
                OneDropEngine.noteDetached()
                return
            }
            throw error
        }
    }

    fun openOneDrop(context: Context) {
        val intent = Intent(context, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        context.startActivity(intent)
    }

    fun listFavoriteSources(context: Context): Map<String, List<String>> {
        val mediaStore = MediaStoreFavorites.ids(context)
        val galleryLoved = ArrayList<String>()
        val galleryUnloved = ArrayList<String>()
        try {
            context.contentResolver.query(
                GALLERY_FAVORITES_URI,
                arrayOf("id", "loved"),
                null,
                null,
                null,
            )?.use { cursor ->
                val idIdx = cursor.getColumnIndex("id")
                val lovedIdx = cursor.getColumnIndex("loved")
                if (idIdx < 0) return@use
                while (cursor.moveToNext()) {
                    val id = cursor.getString(idIdx)?.trim().orEmpty()
                    if (id.isEmpty()) continue
                    val loved = lovedIdx >= 0 && cursor.getInt(lovedIdx) == 1
                    if (loved) galleryLoved.add(id) else galleryUnloved.add(id)
                }
            }
        } catch (_: Exception) {
        }
        return mapOf(
            "mediaStore" to mediaStore,
            "galleryLoved" to galleryLoved,
            "galleryUnloved" to galleryUnloved,
        )
    }

    fun isPackageInstalled(context: Context?, id: String): Boolean {
        if (context == null) return false
        return try {
            context.packageManager.getPackageInfo(id, 0)
            true
        } catch (_: PackageManager.NameNotFoundException) {
            false
        }
    }

    fun handoffMediaToGallery(
        context: Context,
        paths: List<String>,
        kinds: List<String>,
    ): Boolean {
        if (!isPackageInstalled(context, MainActivity.GALLERY)) return false
        val files = paths.mapIndexed { index, path ->
            File(path) to (kinds.getOrElse(index) { "image" })
        }.filter { (file, _) -> file.exists() && file.length() > 0L }
        if (files.isEmpty()) return false
        val authority = "${context.packageName}.fileprovider"
        val uris = files.map { (file, _) ->
            FileProvider.getUriForFile(context, authority, file)
        }
        val intent = Intent(MainActivity.ACTION_GALLERY_IMPORT).apply {
            setPackage(MainActivity.GALLERY)
            putExtra(MainActivity.EXTRA_PATHS, files.map { it.first.absolutePath }.toTypedArray())
            putExtra(MainActivity.EXTRA_KINDS, files.map { it.second }.toTypedArray())
            putExtra(EXTRA_URIS, uris.map(Uri::toString).toTypedArray())
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            val clip = ClipData.newUri(context.contentResolver, "onedrop", uris.first())
            for (i in 1 until uris.size) {
                clip.addItem(ClipData.Item(uris[i]))
            }
            clipData = clip
        }
        for (uri in uris) {
            context.grantUriPermission(
                MainActivity.GALLERY,
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION,
            )
        }
        context.sendBroadcast(Intent(intent))
        return try {
            context.startActivity(
                Intent(intent).addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP,
                ),
            )
            true
        } catch (_: Exception) {
            true
        }
    }

    private const val EXTRA_URIS = "uris"
    private val GALLERY_FAVORITES_URI =
        Uri.parse("content://one.aml.gallery.favorites/loved")
}

