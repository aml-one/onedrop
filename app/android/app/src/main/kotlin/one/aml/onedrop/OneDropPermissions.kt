package one.aml.onedrop

import android.Manifest
import android.bluetooth.BluetoothManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.wifi.WifiManager
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.core.app.ActivityCompat
import java.util.LinkedHashSet

/**
 * Settings → Permissions. First-run still asks once; this path can ask again
 * and open system Settings when ColorOS / MIUI has permanently denied a grant.
 */
object OneDropPermissions {
    const val REQUEST = 83

    fun rows(activity: MainActivity): ArrayList<HashMap<String, Any?>> {
        val out = ArrayList<HashMap<String, Any?>>()
        val asked = activity.runtimeAlreadyAsked()
        out.add(
            runtimeRow(
                activity,
                id = "nearby",
                title = "Nearby devices",
                names = OneDropP2p.blePermissions(),
                asked = asked,
                grantedSubtitle = if (Build.VERSION.SDK_INT >= 31) {
                    "Bluetooth scan and advertise"
                } else {
                    "Location — required for Bluetooth on this Android"
                },
                missingSubtitle = if (Build.VERSION.SDK_INT >= 31) {
                    "Needed to find phones and PCs"
                } else {
                    "Android 11 uses Location for Nearby Bluetooth"
                },
            ),
        )
        out.add(
            toggleRow(
                id = "location",
                title = "Location services",
                granted = locationOn(activity),
                grantedSubtitle = "On — Bluetooth Nearby can scan",
                missingSubtitle = "Turn on Location so Nearby can see devices",
            ),
        )
        out.add(
            toggleRow(
                id = "bluetooth",
                title = "Bluetooth",
                granted = bluetoothOn(activity),
                grantedSubtitle = "On",
                missingSubtitle = "Turn on Bluetooth",
            ),
        )
        out.add(
            runtimeRow(
                activity,
                id = "camera",
                title = "Camera",
                names = arrayOf(Manifest.permission.CAMERA),
                asked = asked,
                grantedSubtitle = "AirGrab and catch",
                missingSubtitle = "Needed for AirGrab",
            ),
        )
        out.add(
            runtimeRow(
                activity,
                id = "photos",
                title = "Photos and videos",
                names = photoPermissions(),
                asked = asked,
                grantedSubtitle = "Can pick what to send",
                missingSubtitle = "Needed to send from this device",
            ),
        )
        if (Build.VERSION.SDK_INT >= 33) {
            out.add(
                runtimeRow(
                    activity,
                    id = "notifications",
                    title = "Notifications",
                    names = arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                    asked = asked,
                    grantedSubtitle = "Incoming drops while the app is closed",
                    missingSubtitle = "Needed for incoming drops in the background",
                ),
            )
        }
        val overlayOn = Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
            Settings.canDrawOverlays(activity)
        out.add(
            toggleRow(
                id = "overlay",
                title = "Display over other apps",
                granted = overlayOn,
                grantedSubtitle = "AirGrab glow can sit on top",
                missingSubtitle = "Needed so AirGrab can catch from other apps",
            ),
        )
        val battery = (activity.getSystemService(Context.POWER_SERVICE) as? PowerManager)
            ?.isIgnoringBatteryOptimizations(activity.packageName) == true
        out.add(
            toggleRow(
                id = "battery",
                title = "Unrestricted battery",
                granted = battery,
                grantedSubtitle = "ColorOS / MIUI will not freeze Nearby",
                missingSubtitle = "Let OneDrop run in the background",
            ),
        )
        return out
    }

    fun namesFor(id: String): Array<String> {
        return when (id) {
            "nearby" -> OneDropP2p.blePermissions()
            "camera" -> arrayOf(Manifest.permission.CAMERA)
            "photos" -> photoPermissions()
            "notifications" ->
                if (Build.VERSION.SDK_INT >= 33) {
                    arrayOf(Manifest.permission.POST_NOTIFICATIONS)
                } else {
                    emptyArray()
                }
            "all" -> {
                val out = LinkedHashSet<String>()
                out.addAll(OneDropP2p.blePermissions())
                out.add(Manifest.permission.CAMERA)
                out.addAll(photoPermissions())
                if (Build.VERSION.SDK_INT >= 33) {
                    out.add(Manifest.permission.POST_NOTIFICATIONS)
                }
                out.toTypedArray()
            }
            else -> emptyArray()
        }
    }

    fun openSystem(activity: MainActivity, id: String): Boolean {
        val intent = when (id) {
            "location" -> Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS)
            "bluetooth" -> Intent(Settings.ACTION_BLUETOOTH_SETTINGS)
            "overlay" ->
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    Intent(
                        Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                        android.net.Uri.parse("package:${activity.packageName}"),
                    )
                } else {
                    appSettings(activity)
                }
            "battery" -> Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
            else -> appSettings(activity)
        }
        return try {
            activity.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            true
        } catch (_: Exception) {
            try {
                activity.startActivity(appSettings(activity).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                true
            } catch (_: Exception) {
                false
            }
        }
    }

    fun appSettings(activity: MainActivity): Intent {
        return Intent(
            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            android.net.Uri.parse("package:${activity.packageName}"),
        )
    }

    fun extras(activity: MainActivity): HashMap<String, Any?> {
        val cm = activity.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
        val caps = cm?.activeNetwork?.let { cm.getNetworkCapabilities(it) }
        val wifi = activity.getSystemService(Context.WIFI_SERVICE) as? WifiManager
        val pm = activity.getSystemService(Context.POWER_SERVICE) as? PowerManager
        val airplane = try {
            Settings.Global.getInt(activity.contentResolver, Settings.Global.AIRPLANE_MODE_ON, 0) == 1
        } catch (_: Exception) {
            false
        }
        return hashMapOf(
            "airplane" to airplane,
            "wifiEnabled" to (wifi?.isWifiEnabled == true),
            "wifiTransport" to (caps?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true),
            "cellTransport" to (caps?.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) == true),
            "overlay" to (
                Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
                    Settings.canDrawOverlays(activity)
                ),
            "batteryUnrestricted" to (
                pm?.isIgnoringBatteryOptimizations(activity.packageName) == true
                ),
            "firstRunAsked" to activity.runtimeAlreadyAsked(),
            "locationOn" to locationOn(activity),
            "bluetoothOn" to bluetoothOn(activity),
        )
    }

    fun scanErrorName(code: Int?): String? {
        return when (code) {
            null -> null
            1 -> "SCAN_FAILED_ALREADY_STARTED"
            2 -> "SCAN_FAILED_APPLICATION_REGISTRATION_FAILED"
            3 -> "SCAN_FAILED_INTERNAL_ERROR"
            4 -> "SCAN_FAILED_FEATURE_UNSUPPORTED"
            5 -> "SCAN_FAILED_OUT_OF_HARDWARE_RESOURCES"
            6 -> "SCAN_FAILED_SCANNING_TOO_FREQUENTLY"
            else -> "scan_failed_$code"
        }
    }

    fun advertiseErrorName(code: Int?): String? {
        return when (code) {
            null -> null
            1 -> "ADVERTISE_FAILED_DATA_TOO_LARGE"
            2 -> "ADVERTISE_FAILED_TOO_MANY_ADVERTISERS"
            3 -> "ADVERTISE_FAILED_ALREADY_STARTED"
            4 -> "ADVERTISE_FAILED_INTERNAL_ERROR"
            5 -> "ADVERTISE_FAILED_FEATURE_UNSUPPORTED"
            else -> "advertise_failed_$code"
        }
    }

    private fun photoPermissions(): Array<String> {
        return if (Build.VERSION.SDK_INT >= 33) {
            arrayOf(
                Manifest.permission.READ_MEDIA_IMAGES,
                Manifest.permission.READ_MEDIA_VIDEO,
            )
        } else {
            arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
        }
    }

    private fun runtimeRow(
        activity: MainActivity,
        id: String,
        title: String,
        names: Array<String>,
        asked: Boolean,
        grantedSubtitle: String,
        missingSubtitle: String,
    ): HashMap<String, Any?> {
        val missing = names.filter { name ->
            ActivityCompat.checkSelfPermission(activity, name) !=
                PackageManager.PERMISSION_GRANTED
        }
        val granted = missing.isEmpty()
        val rationale = missing.any { name ->
            ActivityCompat.shouldShowRequestPermissionRationale(activity, name)
        }
        val canAsk = !granted && (rationale || !asked)
        val needsSettings = !granted && !canAsk
        val action = when {
            granted -> "none"
            canAsk -> "ask"
            else -> "settings"
        }
        val subtitle = if (granted) grantedSubtitle else missingSubtitle
        return hashMapOf(
            "id" to id,
            "title" to title,
            "subtitle" to subtitle,
            "granted" to granted,
            "canAsk" to canAsk,
            "needsSettings" to needsSettings,
            "action" to action,
            "missing" to ArrayList(missing),
        )
    }

    private fun toggleRow(
        id: String,
        title: String,
        granted: Boolean,
        grantedSubtitle: String,
        missingSubtitle: String,
    ): HashMap<String, Any?> {
        return hashMapOf(
            "id" to id,
            "title" to title,
            "subtitle" to if (granted) grantedSubtitle else missingSubtitle,
            "granted" to granted,
            "canAsk" to false,
            "needsSettings" to !granted,
            "action" to if (granted) "none" else "settings",
            "missing" to ArrayList<String>(),
        )
    }

    private fun locationOn(context: Context): Boolean {
        val lm = context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager
            ?: return true
        return if (Build.VERSION.SDK_INT >= 28) {
            lm.isLocationEnabled
        } else {
            @Suppress("DEPRECATION")
            Settings.Secure.getInt(
                context.contentResolver,
                Settings.Secure.LOCATION_MODE,
                Settings.Secure.LOCATION_MODE_OFF,
            ) != Settings.Secure.LOCATION_MODE_OFF
        }
    }

    private fun bluetoothOn(context: Context): Boolean {
        val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        return manager?.adapter?.isEnabled == true
    }
}
