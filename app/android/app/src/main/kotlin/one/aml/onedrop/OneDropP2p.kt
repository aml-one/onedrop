package one.aml.onedrop

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.pm.PackageManager
import android.content.pm.PermissionInfo
import android.location.LocationManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.util.Base64
import android.util.Log
import androidx.core.app.ActivityCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.net.Inet4Address
import java.net.NetworkInterface
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * BLE discovery plus a short-lived local Wi-Fi AP for One Drop when there is
 * no shared LAN. Receiver hosts [WifiManager.startLocalOnlyHotspot]; sender
 * joins with [WifiNetworkSpecifier] and binds HTTP to that network.
 */
object OneDropP2p {
    const val CHANNEL = "one.aml.onedrop/p2p"
    const val EVENTS = "one.aml.onedrop/p2p-peers"
    const val PERMISSION_REQUEST = 81
    private const val TAG = "OneDropP2p"
    private const val COMPANY = 0x0A11
    private const val COMPANY_NAME = 0x0A12
    private const val PREF_PEER = "beaconPeerId"
    private const val PREF_NAME = "beaconName"
    private const val PREF_PORT = "beaconPort"
    private const val PREF_BEACON = "beaconB64"
    private const val PREF_NAME_BYTES = "nameB64"

    private val SERVICE_UUID: UUID = UUID.fromString("a11d0d01-6d65-4f6e-6472-6f70426c6531")
    private val INFO_UUID: UUID = UUID.fromString("a11d0d01-6d65-4f6e-6472-6f70426c6532")
    private val LINK_UUID: UUID = UUID.fromString("a11d0d01-6d65-4f6e-6472-6f70426c6533")
    private val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

    private val main = Handler(Looper.getMainLooper())
    private var app: Context? = null
    private var methods: MethodChannel? = null
    private var sink: EventChannel.EventSink? = null
    private var running = false
    private var dartSession = false
    private var peerId = ""
    private var displayName = "Gallery"
    private var httpPort = 0
    private var beacon = ByteArray(0)
    private var nameBytes = ByteArray(0)
    private var scanHard = false
    private var scanAppliedHard = false
    private var advertisedKey = ""
    // Honor / MagicOS often fails the extra scan-response manufacturer field.
    // Fall back to name bytes after the 22-byte OD core in the same 0x0A11 blob.
    private var advertiseCompact = false
    private val pendingSightings = ArrayList<Map<String, Any>>(8)

    private var advertiser: BluetoothLeAdvertiser? = null
    private var scanner: BluetoothLeScanner? = null
    private var gattServer: BluetoothGattServer? = null
    private var infoChar: BluetoothGattCharacteristic? = null
    private var linkChar: BluetoothGattCharacteristic? = null
    private var hotspot: WifiManager.LocalOnlyHotspotReservation? = null
    private var joinCallback: ConnectivityManager.NetworkCallback? = null
    private var boundNetwork: Network? = null

    private val devices = ConcurrentHashMap<String, BluetoothDevice>()
    private var pendingConnect: MethodChannel.Result? = null
    private var connectGen = 0
    private var activeGatt: BluetoothGatt? = null
    private var advertiseStarted = false
    private var scanStarted = false
    private var lastSkip = ""
    private var lastAdvertiseError: Int? = null
    private var lastScanError: Int? = null
    private var multicastLock: WifiManager.MulticastLock? = null
    @Volatile
    private var radioHeldForCamera = false

    fun attach(engine: FlutterEngine, context: Context) {
        app = context.applicationContext
        methods = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        methods?.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    applyIdentity(
                        call.argument<String>("peerId").orEmpty(),
                        call.argument<String>("name").orEmpty().ifBlank { "Gallery" },
                        call.argument<Int>("port") ?: 0,
                        call.argument<ByteArray>("beacon") ?: ByteArray(0),
                        call.argument<ByteArray>("nameBytes") ?: ByteArray(0),
                    )
                    dartSession = true
                    scanHard = true
                    start(result)
                }
                "stop" -> {
                    stopDartSession()
                    result.success(true)
                }
                "setScanHard" -> {
                    setScanHard(call.argument<Boolean>("hard") == true)
                    result.success(true)
                }
                "connect" -> connect(call.argument<String>("peerId").orEmpty(), result)
                "teardown" -> {
                    teardownClient()
                    result.success(true)
                }
                "debugStatus" -> result.success(debugStatus())
                else -> result.notImplemented()
            }
        }
        EventChannel(engine.dartExecutor.binaryMessenger, EVENTS).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    sink = events
                    if (events == null) return
                    for (row in pendingSightings) {
                        try {
                            events.success(row)
                        } catch (_: Exception) {
                        }
                    }
                    pendingSightings.clear()
                }

                override fun onCancel(arguments: Any?) {
                    sink = null
                }
            },
        )
    }

    fun neededPermissions(): Array<String> = blePermissions()

    /// Runtime BLE permissions only. Install-time BLUETOOTH / BLUETOOTH_ADMIN
    /// are not requested — ColorOS and MIUI flash the status bar and then
    /// kill the app when those show up in a runtime sheet. Nearby Wi‑Fi is
    /// the hotspot path, not discovery, so it is not a Nearby blocker.
    fun blePermissions(): Array<String> {
        return if (Build.VERSION.SDK_INT >= 31) {
            arrayOf(
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_ADVERTISE,
                Manifest.permission.BLUETOOTH_CONNECT,
            )
        } else {
            arrayOf(
                Manifest.permission.ACCESS_FINE_LOCATION,
                Manifest.permission.ACCESS_COARSE_LOCATION,
            )
        }
    }

    fun requiredBlePermissions(): Array<String> {
        return if (Build.VERSION.SDK_INT >= 31) {
            arrayOf(
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_ADVERTISE,
                Manifest.permission.BLUETOOTH_CONNECT,
            )
        } else {
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }
    }

    fun hasPermissions(context: Context): Boolean = hasBlePermissions(context)

    fun hasBlePermissions(context: Context): Boolean {
        return requiredBlePermissions().all {
            context.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED
        }
    }

    fun missingBlePermissions(context: Context): List<String> {
        return requiredBlePermissions().filter {
            context.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED
        }
    }

    fun requestPermissions(activity: MainActivity) {
        if (activity.firstRunBusy()) return
        if (activity.runtimeAlreadyAsked()) return
        val missing = runtimeDangerous(activity, blePermissions())
        if (missing.isEmpty()) return
        ActivityCompat.requestPermissions(
            activity,
            missing,
            PERMISSION_REQUEST,
        )
    }

    fun runtimeDangerous(context: Context, names: Array<String>): Array<String> {
        return names.filter { name ->
            isDangerousRuntime(context, name) &&
                context.checkSelfPermission(name) != PackageManager.PERMISSION_GRANTED
        }.toTypedArray()
    }

    fun isDangerousRuntime(context: Context, permission: String): Boolean {
        return try {
            val info = context.packageManager.getPermissionInfo(permission, 0)
            val level = info.protectionLevel and PermissionInfo.PROTECTION_MASK_BASE
            level == PermissionInfo.PROTECTION_DANGEROUS
        } catch (_: Exception) {
            false
        }
    }

    fun onPermissionResult() {
        if (!running) return
        val ctx = app ?: return
        if (hasBlePermissions(ctx)) {
            startRadio()
        }
    }

    fun onActivityResumed(activity: MainActivity) {
        if (!running) return
        if (radioHeldForCamera) return
        if (hasBlePermissions(activity)) {
            startRadio()
            return
        }
        // Asking again on every resume is what blinked the Redmi status
        // bar until MIUI killed OneDrop. First-run owns the one prompt.
        if (activity.firstRunBusy() || activity.runtimeAlreadyAsked()) return
        requestPermissions(activity)
    }

    /// BLE id from the listen service, even before Dart binds HTTP.
    fun ensurePresence(context: Context) {
        app = context.applicationContext
        if (!loadIdentity(context)) return
        running = true
        startRadio()
    }

    fun onListenServiceStopped() {
        if (dartSession) return
        stopFully()
    }

    fun setScanHard(hard: Boolean) {
        if (scanHard == hard) return
        scanHard = hard
        if (!running || radioHeldForCamera) return
        val ctx = app ?: return
        if (!hasBlePermissions(ctx)) return
        val adapter = bluetoothAdapter() ?: return
        startScan(adapter)
    }

    private fun applyIdentity(
        id: String,
        name: String,
        port: Int,
        beaconBytes: ByteArray,
        nameRaw: ByteArray,
    ) {
        peerId = id
        displayName = name
        httpPort = port
        beacon = beaconBytes
        nameBytes = nameRaw
        app?.let { persistIdentity(it) }
    }

    private fun persistIdentity(context: Context) {
        if (peerId.isEmpty() || beacon.isEmpty()) return
        context.applicationContext
            .getSharedPreferences(DeviceBridge.PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(PREF_PEER, peerId)
            .putString(PREF_NAME, displayName)
            .putInt(PREF_PORT, httpPort)
            .putString(PREF_BEACON, Base64.encodeToString(beacon, Base64.NO_WRAP))
            .putString(PREF_NAME_BYTES, Base64.encodeToString(nameBytes, Base64.NO_WRAP))
            .apply()
    }

    private fun loadIdentity(context: Context): Boolean {
        if (beacon.isNotEmpty() && peerId.isNotEmpty()) return true
        val prefs = context.applicationContext
            .getSharedPreferences(DeviceBridge.PREFS, Context.MODE_PRIVATE)
        val id = prefs.getString(PREF_PEER, "").orEmpty()
        val raw = prefs.getString(PREF_BEACON, "").orEmpty()
        if (id.isEmpty() || raw.isEmpty()) return false
        peerId = id
        displayName = prefs.getString(PREF_NAME, "").orEmpty().ifBlank { "Gallery" }
        httpPort = prefs.getInt(PREF_PORT, 0)
        beacon = runCatching { Base64.decode(raw, Base64.NO_WRAP) }.getOrNull() ?: return false
        val nameRaw = prefs.getString(PREF_NAME_BYTES, "").orEmpty()
        nameBytes = if (nameRaw.isEmpty()) {
            ByteArray(0)
        } else {
            runCatching { Base64.decode(nameRaw, Base64.NO_WRAP) }.getOrDefault(ByteArray(0))
        }
        return beacon.isNotEmpty()
    }

    /// Pause BLE only while CameraX is binding. Advertise and scan resume
    /// as soon as the camera is up so holding beacons still reach catchers.
    fun holdRadioForCamera() {
        if (radioHeldForCamera) return
        radioHeldForCamera = true
        pauseDiscovery()
        Log.i(TAG, "BLE discovery paused for AirGrab camera")
    }

    fun releaseRadioForCamera() {
        if (!radioHeldForCamera) return
        radioHeldForCamera = false
        Log.i(TAG, "BLE discovery resumed after AirGrab camera")
        if (running) startRadio()
    }

    private fun start(result: MethodChannel.Result) {
        val ctx = app
        if (ctx == null) {
            lastSkip = "no_context"
            result.error("no_context", "OneDrop is not open", null)
            return
        }
        persistIdentity(ctx)
        running = true
        if (!hasBlePermissions(ctx)) {
            lastSkip = "missing_permissions"
            Log.i(TAG, "start: BLE perms missing")
            result.success(false)
            return
        }
        startRadio()
        result.success(true)
    }

    @SuppressLint("MissingPermission")
    private fun startRadio() {
        val ctx = app ?: run {
            lastSkip = "no_context"
            return
        }
        if (!hasBlePermissions(ctx)) {
            lastSkip = "missing_permissions"
            return
        }
        holdMulticast()
        lastScanError = null
        lastAdvertiseError = null
        lastSkip = ""
        val manager = ctx.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager ?: run {
            lastSkip = "no_bt_manager"
            return
        }
        val adapter = manager.adapter ?: run {
            lastSkip = "no_adapter"
            return
        }
        if (!adapter.isEnabled) {
            lastSkip = "bluetooth_off"
            return
        }
        openGattServer(manager)
        if (radioHeldForCamera) {
            lastSkip = "held_for_camera"
            Log.i(TAG, "radio held for AirGrab camera")
            return
        }
        lastSkip = ""
        if (!locationEnabled(ctx)) {
            lastSkip = "location_off"
            Log.w(TAG, "Location is off — BLE scan is empty on most phones")
        }
        startAdvertise(adapter)
        startScan(adapter)
    }

    private fun debugStatus(): HashMap<String, Any?> {
        val ctx = app
        val adapter = bluetoothAdapter()
        return hashMapOf(
            "platform" to "android",
            "model" to Build.MODEL,
            "manufacturer" to Build.MANUFACTURER,
            "sdk" to Build.VERSION.SDK_INT,
            "running" to running,
            "dartSession" to dartSession,
            "advertiseStarted" to advertiseStarted,
            "scanStarted" to scanStarted,
            "bluetoothOn" to (adapter?.isEnabled == true),
            "hasAdvertiser" to (adapter?.bluetoothLeAdvertiser != null),
            "leFeature" to (ctx?.packageManager?.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE) == true),
            "hasPermissions" to (ctx != null && hasPermissions(ctx)),
            "hasBlePermissions" to (ctx != null && hasBlePermissions(ctx)),
            "missing" to ArrayList(ctx?.let { missingBlePermissions(it) } ?: emptyList()),
            "locationOn" to (ctx != null && locationEnabled(ctx)),
            "multicastHeld" to (multicastLock?.isHeld == true),
            "skip" to lastSkip,
            "advertiseError" to lastAdvertiseError,
            "advertiseErrorName" to OneDropPermissions.advertiseErrorName(lastAdvertiseError),
            "scanError" to lastScanError,
            "scanErrorName" to OneDropPermissions.scanErrorName(lastScanError),
            "peerId" to peerId,
            "httpPort" to httpPort,
            "radioHeldForCamera" to radioHeldForCamera,
        )
    }

    private fun bluetoothAdapter(): BluetoothAdapter? {
        val ctx = app ?: return null
        val manager = ctx.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager ?: return null
        return manager.adapter
    }

    private fun locationEnabled(context: Context): Boolean {
        val lm = context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager ?: return true
        return if (Build.VERSION.SDK_INT >= 28) {
            lm.isLocationEnabled
        } else {
            @Suppress("DEPRECATION")
            android.provider.Settings.Secure.getInt(
                context.contentResolver,
                android.provider.Settings.Secure.LOCATION_MODE,
                android.provider.Settings.Secure.LOCATION_MODE_OFF,
            ) != android.provider.Settings.Secure.LOCATION_MODE_OFF
        }
    }

    private fun holdMulticast() {
        val ctx = app ?: return
        if (multicastLock?.isHeld == true) return
        try {
            val wifi = ctx.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
                ?: return
            multicastLock = wifi.createMulticastLock("onedrop:p2p").apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (_: Exception) {
        }
    }

    private fun releaseMulticast() {
        try {
            if (multicastLock?.isHeld == true) multicastLock?.release()
        } catch (_: Exception) {
        }
        multicastLock = null
    }

    @SuppressLint("MissingPermission")
    private fun pauseDiscovery() {
        try {
            if (scanStarted) scanner?.stopScan(scanCallback)
        } catch (_: Exception) {
        }
        scanStarted = false
        scanAppliedHard = false
        try {
            if (advertiseStarted) advertiser?.stopAdvertising(advertiseCallback)
        } catch (_: Exception) {
        }
        advertiseStarted = false
        advertisedKey = ""
        advertiseCompact = false
    }

    @SuppressLint("MissingPermission")
    private fun openGattServer(manager: BluetoothManager) {
        val ctx = app ?: return
        if (gattServer != null) return
        gattServer = manager.openGattServer(ctx, gattServerCallback)
        val service = BluetoothGattService(SERVICE_UUID, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        infoChar = BluetoothGattCharacteristic(
            INFO_UUID,
            BluetoothGattCharacteristic.PROPERTY_READ,
            BluetoothGattCharacteristic.PERMISSION_READ,
        )
        linkChar = BluetoothGattCharacteristic(
            LINK_UUID,
            BluetoothGattCharacteristic.PROPERTY_WRITE or
                BluetoothGattCharacteristic.PROPERTY_NOTIFY,
            BluetoothGattCharacteristic.PERMISSION_WRITE,
        )
        linkChar?.addDescriptor(
            BluetoothGattDescriptor(
                CCCD_UUID,
                BluetoothGattDescriptor.PERMISSION_READ or
                    BluetoothGattDescriptor.PERMISSION_WRITE,
            ),
        )
        service.addCharacteristic(infoChar)
        service.addCharacteristic(linkChar)
        gattServer?.addService(service)
    }

    @SuppressLint("MissingPermission")
    private fun startAdvertise(adapter: BluetoothAdapter) {
        if (beacon.isEmpty()) {
            lastSkip = "empty_beacon"
            return
        }
        val advertiseMode = if (dartSession) {
            AdvertiseSettings.ADVERTISE_MODE_BALANCED
        } else {
            AdvertiseSettings.ADVERTISE_MODE_LOW_POWER
        }
        val key =
            "$peerId|$httpPort|$advertiseMode|$advertiseCompact|${beacon.contentHashCode()}|${nameBytes.contentHashCode()}"
        if (advertiseStarted && advertisedKey == key) return
        if (advertiseStarted) {
            try {
                advertiser?.stopAdvertising(advertiseCallback)
            } catch (_: Exception) {
            }
            advertiseStarted = false
        }
        advertiser = adapter.bluetoothLeAdvertiser ?: run {
            lastSkip = "no_le_advertiser"
            return
        }
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(advertiseMode)
            .setTxPowerLevel(
                if (dartSession) {
                    AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM
                } else {
                    AdvertiseSettings.ADVERTISE_TX_POWER_LOW
                },
            )
            .setConnectable(true)
            .setTimeout(0)
            .build()
        val payload = if (advertiseCompact && nameBytes.isNotEmpty()) {
            beacon + nameBytes
        } else {
            beacon
        }
        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .addManufacturerData(COMPANY, payload)
            .build()
        val scan = if (!advertiseCompact && nameBytes.isNotEmpty()) {
            AdvertiseData.Builder()
                .setIncludeDeviceName(false)
                .addManufacturerData(COMPANY_NAME, nameBytes)
                .build()
        } else {
            null
        }
        try {
            if (scan != null) {
                advertiser?.startAdvertising(settings, data, scan, advertiseCallback)
            } else {
                advertiser?.startAdvertising(settings, data, advertiseCallback)
            }
            advertiseStarted = true
            advertisedKey = key
        } catch (error: Exception) {
            if (!advertiseCompact) {
                advertiseCompact = true
                advertisedKey = ""
                startAdvertise(adapter)
                return
            }
            lastSkip = "advertise_exception"
            Log.w(TAG, "advertise", error)
        }
    }

    @SuppressLint("MissingPermission")
    private fun startScan(adapter: BluetoothAdapter) {
        if (scanStarted && scanAppliedHard == scanHard) return
        if (scanStarted) {
            try {
                scanner?.stopScan(scanCallback)
            } catch (_: Exception) {
            }
            scanStarted = false
        }
        scanner = adapter.bluetoothLeScanner ?: return
        // HyperOS manufacturer ScanFilters often drop Honor tablets and
        // Windows extended ads. Filter in software while the radar is open.
        val filters: List<ScanFilter>? = if (scanHard) {
            null
        } else {
            listOf(
                ScanFilter.Builder().setManufacturerData(COMPANY, byteArrayOf(0x4F, 0x44)).build(),
            )
        }
        val mode = if (scanHard) {
            ScanSettings.SCAN_MODE_LOW_LATENCY
        } else {
            ScanSettings.SCAN_MODE_LOW_POWER
        }
        val builder = ScanSettings.Builder()
            .setScanMode(mode)
            .setCallbackType(ScanSettings.CALLBACK_TYPE_ALL_MATCHES)
            .setMatchMode(ScanSettings.MATCH_MODE_AGGRESSIVE)
            .setNumOfMatches(ScanSettings.MATCH_NUM_MAX_ADVERTISEMENT)
            .setReportDelay(0)
        // Default setLegacy(true) receives classic 4.2 ads from Android
        // startAdvertising(). setLegacy(false) is extended-only on HyperOS
        // / ColorOS, so three phones next to each other see nobody.
        val settings = builder.build()
        try {
            scanner?.startScan(filters, settings, scanCallback)
            scanStarted = true
            scanAppliedHard = scanHard
        } catch (error: Exception) {
            Log.w(TAG, "scan", error)
        }
    }

    @SuppressLint("MissingPermission")
    private fun stopDartSession() {
        dartSession = false
        scanHard = false
        teardownClient()
        stopHotspot()
        if (OneDropListenService.isRunning()) {
            val adapter = bluetoothAdapter()
            if (adapter != null && !radioHeldForCamera) startScan(adapter)
            return
        }
        stopFully()
    }

    @SuppressLint("MissingPermission")
    private fun stopFully() {
        running = false
        dartSession = false
        scanHard = false
        radioHeldForCamera = false
        teardownClient()
        stopHotspot()
        pauseDiscovery()
        releaseMulticast()
        try {
            gattServer?.close()
        } catch (_: Exception) {
        }
        gattServer = null
        devices.clear()
        pendingSightings.clear()
    }

    @SuppressLint("MissingPermission")
    private fun connect(id: String, result: MethodChannel.Result) {
        if (pendingConnect != null) {
            result.error("busy", "Already opening a nearby link", null)
            return
        }
        val device = devices[id]
        if (device == null) {
            result.error("missing", "That device is no longer nearby", null)
            return
        }
        val ctx = app
        if (ctx == null) {
            result.error("no_context", "Gallery is not open", null)
            return
        }
        pendingConnect = result
        val gen = ++connectGen
        main.postDelayed({
            if (gen == connectGen) failConnect("Could not reach them nearby")
        }, 25_000)
        try {
            activeGatt = if (Build.VERSION.SDK_INT >= 23) {
                device.connectGatt(ctx, false, gattClientCallback, BluetoothDevice.TRANSPORT_LE)
            } else {
                @Suppress("DEPRECATION")
                device.connectGatt(ctx, false, gattClientCallback)
            }
        } catch (error: Exception) {
            failConnect(error.message ?: "Bluetooth failed")
        }
    }

    @SuppressLint("MissingPermission")
    private fun failConnect(message: String) {
        val pending = pendingConnect ?: return
        connectGen++
        pendingConnect = null
        try {
            activeGatt?.close()
        } catch (_: Exception) {
        }
        activeGatt = null
        try {
            pending.error("link", message, null)
        } catch (_: Exception) {
        }
    }

    @SuppressLint("MissingPermission")
    private fun succeedConnect(host: String, port: Int) {
        val pending = pendingConnect ?: return
        connectGen++
        pendingConnect = null
        try {
            pending.success(mapOf("host" to host, "port" to port))
        } catch (_: Exception) {
        }
    }

    @SuppressLint("MissingPermission")
    private fun teardownClient() {
        val gatt = activeGatt
        if (gatt != null) {
            try {
                val link = gatt.getService(SERVICE_UUID)?.getCharacteristic(LINK_UUID)
                if (link != null) {
                    val payload = JSONObject().put("t", "done").toString().toByteArray(Charsets.UTF_8)
                    if (Build.VERSION.SDK_INT >= 33) {
                        gatt.writeCharacteristic(
                            link,
                            payload,
                            BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT,
                        )
                    } else {
                        @Suppress("DEPRECATION")
                        link.value = payload
                        @Suppress("DEPRECATION")
                        gatt.writeCharacteristic(link)
                    }
                }
            } catch (_: Exception) {
            }
            main.postDelayed({
                try {
                    gatt.close()
                } catch (_: Exception) {
                }
            }, 400)
        }
        activeGatt = null
        val ctx = app
        val cm = ctx?.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
        try {
            cm?.bindProcessToNetwork(null)
        } catch (_: Exception) {
        }
        boundNetwork = null
        val callback = joinCallback
        joinCallback = null
        if (callback != null) {
            try {
                cm?.unregisterNetworkCallback(callback)
            } catch (_: Exception) {
            }
        }
        try {
            activeGatt?.close()
        } catch (_: Exception) {
        }
        activeGatt = null
    }

    private fun stopHotspot() {
        try {
            hotspot?.close()
        } catch (_: Exception) {
        }
        hotspot = null
    }

    @SuppressLint("MissingPermission")
    private fun handleHostRequest(device: BluetoothDevice) {
        val ctx = app ?: return
        val wifi = ctx.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        if (hotspot != null) {
            notifyAp(device)
            return
        }
        try {
            wifi.startLocalOnlyHotspot(
                object : WifiManager.LocalOnlyHotspotCallback() {
                    override fun onStarted(reservation: WifiManager.LocalOnlyHotspotReservation) {
                        hotspot = reservation
                        main.postDelayed({ notifyAp(device) }, 400)
                    }

                    override fun onFailed(reason: Int) {
                        notifyLink(device, JSONObject().put("t", "err").put("m", "wifi").toString())
                    }
                },
                main,
            )
        } catch (error: Exception) {
            Log.w(TAG, "hotspot", error)
            notifyLink(device, JSONObject().put("t", "err").put("m", "wifi").toString())
        }
    }

    @SuppressLint("MissingPermission")
    private fun notifyAp(device: BluetoothDevice) {
        val reservation = hotspot ?: return
        var ssid = ""
        var psk = ""
        try {
            if (Build.VERSION.SDK_INT >= 30) {
                val conf = reservation.softApConfiguration
                ssid = conf.ssid?.trim('"').orEmpty()
                psk = conf.passphrase.orEmpty()
            }
        } catch (_: Exception) {
        }
        if (ssid.isEmpty()) {
            @Suppress("DEPRECATION")
            val conf = reservation.wifiConfiguration
            ssid = conf?.SSID?.trim('"').orEmpty()
            psk = conf?.preSharedKey.orEmpty()
        }
        val ip = hotspotGateway()
        val json = JSONObject()
            .put("t", "ap")
            .put("ssid", ssid)
            .put("psk", psk)
            .put("ip", ip)
            .put("port", httpPort)
        notifyLink(device, json.toString())
    }

    @SuppressLint("MissingPermission")
    private fun notifyLink(device: BluetoothDevice, json: String) {
        val characteristic = linkChar ?: return
        val bytes = json.toByteArray(Charsets.UTF_8)
        characteristic.value = bytes
        if (Build.VERSION.SDK_INT >= 33) {
            gattServer?.notifyCharacteristicChanged(device, characteristic, false, bytes)
        } else {
            @Suppress("DEPRECATION")
            gattServer?.notifyCharacteristicChanged(device, characteristic, false)
        }
    }

    private fun hotspotGateway(): String {
        var apNamed = ""
        try {
            val ifaces = NetworkInterface.getNetworkInterfaces() ?: return "192.168.49.1"
            for (iface in ifaces) {
                val name = iface.name.lowercase()
                val addrs = iface.inetAddresses ?: continue
                for (addr in addrs) {
                    if (addr !is Inet4Address || addr.isLoopbackAddress) continue
                    val ip = addr.hostAddress ?: continue
                    if (ip.startsWith("192.168.49.")) return ip
                    val hosted = name.contains("ap") ||
                        name.contains("swlan") ||
                        name.contains("p2p") ||
                        name.contains("wlan1")
                    if (hosted && ip.startsWith("192.168.") && apNamed.isEmpty()) {
                        apNamed = ip
                    }
                }
            }
        } catch (_: Exception) {
        }
        return apNamed.ifEmpty { "192.168.49.1" }
    }

    private fun joinAp(ssid: String, psk: String, ip: String, port: Int) {
        val ctx = app ?: return failConnect("Gallery is not open")
        if (ssid.isEmpty() || psk.isEmpty()) {
            failConnect("The other device could not open Wi-Fi")
            return
        }
        if (Build.VERSION.SDK_INT < 29) {
            failConnect("Nearby Wi-Fi needs Android 10+")
            return
        }
        val cm = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val specifier = WifiNetworkSpecifier.Builder()
            .setSsid(ssid)
            .setWpa2Passphrase(psk)
            .build()
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .setNetworkSpecifier(specifier)
            .build()
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                boundNetwork = network
                try {
                    cm.bindProcessToNetwork(network)
                } catch (_: Exception) {
                }
                main.post { succeedConnect(ip, port) }
            }

            override fun onUnavailable() {
                main.post { failConnect("Could not join the private Wi-Fi") }
            }
        }
        joinCallback = callback
        try {
            cm.requestNetwork(request, callback, 20_000)
        } catch (error: Exception) {
            failConnect(error.message ?: "Wi-Fi join failed")
        }
    }

    private fun emitPeer(
        id: String,
        name: String,
        port: Int,
        role: String,
        os: String,
        files: Boolean,
    ) {
        val row = mapOf(
            "peerId" to id,
            "name" to name,
            "port" to port,
            "role" to role,
            "os" to os,
            "files" to files,
        )
        main.post {
            val events = sink
            if (events == null) {
                if (pendingSightings.size >= 16) pendingSightings.removeAt(0)
                pendingSightings.add(row)
                return@post
            }
            try {
                events.success(row)
            } catch (_: Exception) {
            }
        }
    }

    private fun parseBeacon(data: ByteArray?, nameRaw: ByteArray?): Sighting? {
        if (data == null || data.size < 22) return null
        if (data[0] != 0x4F.toByte() || data[1] != 0x44.toByte()) return null
        if (data[2].toInt() != 1) return null
        val port = ((data[4].toInt() and 0xFF) shl 8) or (data[5].toInt() and 0xFF)
        if (port <= 0) return null
        var end = 22
        while (end > 6 && data[end - 1] == 0.toByte()) end--
        val id = String(data, 6, end - 6, Charsets.UTF_8).trim()
        if (id.isEmpty() || id == peerId) return null
        val flags = data[3].toInt() and 0xFF
        val role = when (flags and 0x03) {
            1 -> "desktop"
            2 -> "tablet"
            else -> "phone"
        }
        val os = when ((flags shr 2) and 0x07) {
            1 -> "android"
            2 -> "windows"
            3 -> "linux"
            4 -> "macos"
            else -> "other"
        }
        val embedded = if (data.size > 22) {
            String(data, 22, data.size - 22, Charsets.UTF_8).trim()
        } else {
            ""
        }
        val fromScan = if (nameRaw != null && nameRaw.isNotEmpty()) {
            String(nameRaw, Charsets.UTF_8).trim()
        } else {
            ""
        }
        val name = embedded.ifBlank { fromScan }.ifBlank { "One Drop" }
        val files = (flags and 0x20) != 0
        return Sighting(id, name, port, role, os, files)
    }

    private data class Sighting(
        val id: String,
        val name: String,
        val port: Int,
        val role: String,
        val os: String,
        val files: Boolean,
    )

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartFailure(errorCode: Int) {
            advertiseStarted = false
            advertisedKey = ""
            lastAdvertiseError = errorCode
            if (!advertiseCompact &&
                (errorCode == ADVERTISE_FAILED_DATA_TOO_LARGE ||
                    errorCode == ADVERTISE_FAILED_INTERNAL_ERROR)
            ) {
                advertiseCompact = true
                bluetoothAdapter()?.let { startAdvertise(it) }
                return
            }
            lastSkip = "advertise_failed_$errorCode"
            Log.w(TAG, "advertise failed $errorCode")
        }
    }

    private fun ingestScan(result: ScanResult) {
        val record = result.scanRecord ?: return
        val beacon = record.getManufacturerSpecificData(COMPANY)
        val name = record.getManufacturerSpecificData(COMPANY_NAME)
            ?: record.deviceName?.toByteArray(Charsets.UTF_8)
        val sighting = parseBeacon(beacon, name) ?: return
        devices[sighting.id] = result.device
        emitPeer(
            sighting.id,
            sighting.name,
            sighting.port,
            sighting.role,
            sighting.os,
            sighting.files,
        )
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            ingestScan(result)
        }

        override fun onBatchScanResults(results: MutableList<ScanResult>) {
            for (row in results) ingestScan(row)
        }

        override fun onScanFailed(errorCode: Int) {
            lastScanError = errorCode
            lastSkip = "scan_failed_$errorCode"
            scanStarted = false
            scanAppliedHard = false
            Log.w(TAG, "scan failed $errorCode")
        }
    }

    private val gattServerCallback = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            // AP stays up until the sender writes "done" or One Drop stops.
        }

        override fun onCharacteristicReadRequest(
            device: BluetoothDevice,
            requestId: Int,
            offset: Int,
            characteristic: BluetoothGattCharacteristic,
        ) {
            if (characteristic.uuid != INFO_UUID) {
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_FAILURE, 0, null)
                return
            }
            val json = JSONObject()
                .put("v", 1)
                .put("peerId", peerId)
                .put("name", displayName)
                .put("port", httpPort)
                .toString()
                .toByteArray(Charsets.UTF_8)
            val slice = if (offset >= json.size) ByteArray(0) else json.copyOfRange(offset, json.size)
            gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, slice)
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray?,
        ) {
            if (responseNeeded) {
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value)
            }
            if (characteristic.uuid != LINK_UUID || value == null) return
            val text = String(value, Charsets.UTF_8)
            val type = runCatching { JSONObject(text).optString("t") }.getOrDefault("")
            when (type) {
                "host" -> main.post { handleHostRequest(device) }
                "done" -> main.post { stopHotspot() }
            }
        }

        override fun onDescriptorWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray?,
        ) {
            if (value != null) {
                descriptor.value = value
            }
            if (responseNeeded) {
                gattServer?.sendResponse(
                    device,
                    requestId,
                    BluetoothGatt.GATT_SUCCESS,
                    offset,
                    value,
                )
            }
        }

        override fun onDescriptorReadRequest(
            device: BluetoothDevice,
            requestId: Int,
            offset: Int,
            descriptor: BluetoothGattDescriptor,
        ) {
            val raw = descriptor.value ?: BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
            val slice = if (offset >= raw.size) ByteArray(0) else raw.copyOfRange(offset, raw.size)
            gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, slice)
        }
    }

    private val gattClientCallback = object : BluetoothGattCallback() {
        @SuppressLint("MissingPermission")
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                gatt.discoverServices()
                return
            }
            if (newState == BluetoothProfile.STATE_DISCONNECTED && pendingConnect != null) {
                main.post { failConnect("Bluetooth dropped") }
            }
        }

        @SuppressLint("MissingPermission")
        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            val service = gatt.getService(SERVICE_UUID)
            val link = service?.getCharacteristic(LINK_UUID)
            if (link == null) {
                main.post { failConnect("That device is not ready for One Drop") }
                return
            }
            gatt.setCharacteristicNotification(link, true)
            val cccd = link.getDescriptor(CCCD_UUID)
            if (cccd != null) {
                val enabled = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                val wrote = if (Build.VERSION.SDK_INT >= 33) {
                    gatt.writeDescriptor(cccd, enabled) == BluetoothGatt.GATT_SUCCESS
                } else {
                    @Suppress("DEPRECATION")
                    cccd.value = enabled
                    @Suppress("DEPRECATION")
                    gatt.writeDescriptor(cccd)
                }
                if (wrote) return
            }
            writeHost(gatt, link)
        }

        @SuppressLint("MissingPermission")
        override fun onDescriptorWrite(
            gatt: BluetoothGatt,
            descriptor: BluetoothGattDescriptor,
            status: Int,
        ) {
            val link = gatt.getService(SERVICE_UUID)?.getCharacteristic(LINK_UUID) ?: return
            writeHost(gatt, link)
        }

        @SuppressLint("MissingPermission")
        private fun writeHost(gatt: BluetoothGatt, link: BluetoothGattCharacteristic) {
            val payload = JSONObject().put("t", "host").toString().toByteArray(Charsets.UTF_8)
            if (Build.VERSION.SDK_INT >= 33) {
                gatt.writeCharacteristic(
                    link,
                    payload,
                    BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT,
                )
            } else {
                @Suppress("DEPRECATION")
                link.value = payload
                @Suppress("DEPRECATION")
                gatt.writeCharacteristic(link)
            }
        }

        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
        ) {
            onLinkNotify(value)
        }

        @Deprecated("Older Android")
        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
        ) {
            @Suppress("DEPRECATION")
            onLinkNotify(characteristic.value ?: return)
        }

        private fun onLinkNotify(value: ByteArray) {
            val json = runCatching { JSONObject(String(value, Charsets.UTF_8)) }.getOrNull() ?: return
            when (json.optString("t")) {
                "ap" -> main.post {
                    joinAp(
                        json.optString("ssid"),
                        json.optString("psk"),
                        json.optString("ip").ifBlank { "192.168.49.1" },
                        json.optInt("port", httpPort),
                    )
                }
                "err" -> main.post {
                    failConnect("The other device could not open Wi-Fi")
                }
            }
        }
    }
}

