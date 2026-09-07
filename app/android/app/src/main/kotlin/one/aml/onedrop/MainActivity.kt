package one.aml.onedrop

import android.Manifest
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.OpenableColumns
import android.provider.Settings
import androidx.core.app.ActivityCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.LinkedHashSet

class MainActivity : FlutterActivity() {
    private var firstRunInFlight = false
    private var pendingFirstRun: MethodChannel.Result? = null
    private val pendingShares = ArrayList<String>()

    override fun onCreate(savedInstanceState: Bundle?) {
        OneDropEngine.get(this)
        super.onCreate(savedInstanceState)
        collectShare(intent)
        DeviceBridge.setListenEnabled(this, true)
        OneDropListenService.start(this)
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        flutterEngine?.navigationChannel?.popRoute()
    }

    override fun getCachedEngineId(): String = OneDropEngine.ID

    override fun provideFlutterEngine(context: Context): FlutterEngine {
        return OneDropEngine.get(this)
    }

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        collectShare(intent)
    }

    override fun onResume() {
        super.onResume()
        ensureFirstRunPermissions()
        OneDropP2p.onActivityResumed(this)
    }

    fun firstRunBusy(): Boolean = firstRunInFlight

    fun ensureFirstRunPermissions(result: MethodChannel.Result? = null) {
        if (result != null) pendingFirstRun = result
        if (firstRunInFlight) return
        val missing = missingFirstRunRuntime()
        if (missing.isEmpty()) {
            maybeRequestOverlay()
            completeFirstRun()
            return
        }
        firstRunInFlight = true
        ActivityCompat.requestPermissions(this, missing, FIRST_RUN_REQUEST)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        DeviceBridge.bindActivity(this)
    }

    fun requestAirGrabOverlay(force: Boolean = false) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        if (Settings.canDrawOverlays(this)) {
            markOverlayAsked()
            return
        }
        if (!force && overlayAsked()) return
        markOverlayAsked()
        startActivity(
            Intent(
                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                Uri.parse("package:$packageName"),
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
    }

    fun requestCameraPermission() {
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.CAMERA),
            AirGrabTracker.CAMERA_REQUEST,
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == FIRST_RUN_REQUEST) {
            firstRunInFlight = false
            val cam = permissions.indexOf(Manifest.permission.CAMERA)
            if (cam >= 0) {
                AirGrabTracker.onPermission(
                    cam < grantResults.size &&
                        grantResults[cam] == PackageManager.PERMISSION_GRANTED,
                )
            }
            OneDropP2p.onPermissionResult()
            maybeRequestOverlay()
            completeFirstRun()
            return
        }
        if (requestCode == AirGrabTracker.CAMERA_REQUEST) {
            AirGrabTracker.onPermission(
                grantResults.isNotEmpty() &&
                    grantResults[0] == PackageManager.PERMISSION_GRANTED,
            )
        }
        if (requestCode == OneDropP2p.PERMISSION_REQUEST) {
            OneDropP2p.onPermissionResult()
        }
    }

    fun requestListenNotifications() {
        if (Build.VERSION.SDK_INT < 33) return
        if (
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            NOTIFY_REQUEST,
        )
    }

    internal fun deviceName(): String = DeviceBridge.deviceName(this)

    internal fun isPackageInstalled(id: String): Boolean {
        return DeviceBridge.isPackageInstalled(this, id)
    }

    internal fun copyContentUri(uriString: String, name: String): String? {
        if (uriString.isBlank()) return null
        return try {
            val uri = Uri.parse(uriString)
            val safe = name
                .ifBlank { "drop-${System.currentTimeMillis()}" }
                .replace(Regex("[\\\\/:*?\"<>|]"), "_")
            val out = File(cacheDir, "onedrop-src-$safe")
            contentResolver.openInputStream(uri)?.use { input ->
                out.outputStream().use { output -> input.copyTo(output) }
            } ?: return null
            if (!out.exists() || out.length() <= 0L) {
                out.delete()
                return null
            }
            out.absolutePath
        } catch (_: Exception) {
            null
        }
    }

    fun takePendingShares(): List<String> {
        val copy = pendingShares.toList()
        pendingShares.clear()
        return copy
    }

    private fun collectShare(intent: Intent?) {
        if (intent == null) return
        val action = intent.action
        val uris = ArrayList<Uri>()
        when (action) {
            Intent.ACTION_SEND -> {
                intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)?.let(uris::add)
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.let(uris::addAll)
            }
        }
        for (uri in uris) {
            val name = displayName(uri) ?: "shared-${System.currentTimeMillis()}"
            copyContentUri(uri.toString(), name)?.let(pendingShares::add)
        }
        if (pendingShares.isNotEmpty()) {
            DeviceBridge.openOneDrop(this)
        }
    }

    private fun displayName(uri: Uri): String? {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (index >= 0) return cursor.getString(index)
                }
            }
        return uri.lastPathSegment
    }

    private fun maybeRequestOverlay() {
        requestAirGrabOverlay(force = false)
    }

    private fun completeFirstRun() {
        firstRunInFlight = false
        val pending = pendingFirstRun
        pendingFirstRun = null
        pending?.success(true)
    }

    private fun overlayPrefs() =
        getSharedPreferences(DeviceBridge.PREFS, Context.MODE_PRIVATE)

    private fun overlayAsked(): Boolean =
        overlayPrefs().getBoolean(PREF_ASKED_OVERLAY, false)

    private fun markOverlayAsked() {
        overlayPrefs().edit().putBoolean(PREF_ASKED_OVERLAY, true).apply()
    }

    private fun missingFirstRunRuntime(): Array<String> {
        return firstRunRuntimePermissions().filter {
            checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED
        }.toTypedArray()
    }

    private fun firstRunRuntimePermissions(): List<String> {
        val out = LinkedHashSet<String>()
        out.add(Manifest.permission.CAMERA)
        out.addAll(OneDropP2p.neededPermissions())
        if (Build.VERSION.SDK_INT >= 33) {
            out.add(Manifest.permission.POST_NOTIFICATIONS)
            out.add(Manifest.permission.READ_MEDIA_IMAGES)
            out.add(Manifest.permission.READ_MEDIA_VIDEO)
        } else {
            out.add(Manifest.permission.READ_EXTERNAL_STORAGE)
        }
        return out.toList()
    }

    companion object {
        const val GALLERY = "one.aml.gallery"
        const val ACTION_GALLERY_IMPORT = "one.aml.gallery.action.DROP_IMPORT"
        const val EXTRA_PATHS = "paths"
        const val EXTRA_KINDS = "kinds"
        private const val NOTIFY_REQUEST = 72
        private const val FIRST_RUN_REQUEST = 77
        private const val PREF_ASKED_OVERLAY = "askedOverlay"
    }
}
