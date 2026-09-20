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
import android.net.wifi.WifiConfiguration
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.net.wifi.WifiNetworkSuggestion
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
 *
 * Fire OS cannot read `/proc/net/arp` and cannot host a SoftAP. Same-Wi-Fi
 * sends read the peer's LAN IPv4 from the GATT INFO characteristic. If the
 * receiver cannot host, it asks the sender to host and then joins.
 */
object OneDropP2p {
    const val CHANNEL = "one.aml.onedrop/p2p"
    const val EVENTS = "one.aml.onedrop/p2p-peers"
    const val PERMISSION_REQUEST = 81
    private const val TAG = "OneDropP2p"
    /** Diagnostic Watch filter. Dart send/recv notes also use this tag. */
    private const val WATCH = "OneDrop"
    private const val DUTY_ADVERTISE_MS = 10_000L
    private const val DUTY_SCAN_MS = 1_500L
    private const val FRESH_SIGHTING_MS = 2_000L
    private const val WAIT_FOR_PEER_MS = 10_000L
    private const val INCOMING_GATT_MS = 45_000L
    private const val COMPANY = 0x0A11
    private const val COMPANY_NAME = 0x0A12
    // Beacon flag bit 6: peer has the send UI open. Idle listen stays
    // non-connectable so Windows Add-a-device does not list nameless Unknowns.
    private const val SESSION_FLAG = 0x40
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
    private var joinTargetSsid = ""
    private var joinTargetPsk = ""
    private var joinTargetIp = ""
    private var joinTargetPort = 0
    private var joinReadyTo: BluetoothDevice? = null
    private var joinUntil = 0L
    private var joinFinished = false
    private var amazonLegacyTried = false
    private val joinPoll = Runnable { pollJoinedAp() }

    private val devices = ConcurrentHashMap<String, BluetoothDevice>()
    private val deviceSeenAt = ConcurrentHashMap<String, Long>()
    private var pendingConnect: MethodChannel.Result? = null
    private var waitingConnectId: String? = null
    private var connectGen = 0
    private var connectDevice: BluetoothDevice? = null
    private var connectAttempt = 0
    private var gattLinked = false
    private var infoRead = false
    private var hostWritten = false
    private var boundForHotspot = false
    private var joinStarted = false
    private var swapStarted = false
    private var linkOffer: JSONObject? = null
    private var radioPausedForConnect = false
    private var gattServerHeldOff = false
    private var gattServiceRetry = false
    private var incomingGattUntil = 0L
    private val dropIncomingGatt = Runnable {
        if (!dartSession && running && !radioHeldForCamera && !radioPausedForConnect) {
            bluetoothAdapter()?.let { startAdvertise(it) }
        }
    }
    private var lastConnectNote = ""
    private var lastAdvertiseLog = ""
    private val lastPeerWatchAt = ConcurrentHashMap<String, Long>()
    private var lastGattStatus: Int? = null
    private var lastGattServerStatus: Int? = null
    private var activeGatt: BluetoothGatt? = null
    private var advertiseStarted = false
    private var scanStarted = false
    private var lastSkip = ""
    private var lastAdvertiseError: Int? = null
    private var lastScanError: Int? = null
    private var multicastLock: WifiManager.MulticastLock? = null
    @Volatile
    private var radioHeldForCamera = false
    private var dutyRunning = false
    private var dutyAdvertisePhase = true
    private val dutyTick = Runnable { tickDutyCycle() }
    private val offerPoll = Runnable { pollLinkOffer() }

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
                "log" -> {
                    val msg = call.argument<String>("message").orEmpty().trim()
                    if (msg.isNotEmpty()) Log.i(WATCH, msg.take(400))
                    result.success(true)
                }
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

    private fun watch(line: String) {
        val msg = line.trim()
        if (msg.isEmpty()) return
        Log.i(WATCH, msg.take(500))
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
        if (dutyRunning) return
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
            val missing = missingBlePermissions(ctx).joinToString(",")
            watch("start: BLE perms missing $missing")
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
            watch("radio start failed missing_permissions")
            return
        }
        holdMulticast()
        lastScanError = null
        lastAdvertiseError = null
        lastSkip = ""
        val manager = ctx.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager ?: run {
            lastSkip = "no_bt_manager"
            watch("radio start failed no_bt_manager")
            return
        }
        val adapter = manager.adapter ?: run {
            lastSkip = "no_adapter"
            watch("radio start failed no_adapter")
            return
        }
        if (!adapter.isEnabled) {
            lastSkip = "bluetooth_off"
            watch("radio start failed bluetooth_off")
            return
        }
        openGattServer(manager)
        if (radioHeldForCamera) {
            lastSkip = "held_for_camera"
            Log.i(TAG, "radio held for AirGrab camera")
            return
        }
        lastSkip = ""
        val locOn = locationEnabled(ctx)
        if (!locOn) {
            lastSkip = "location_off"
            watch("Location is off — BLE scan is empty on most phones")
            Log.w(TAG, "Location is off — BLE scan is empty on most phones")
        }
        watch(
            "radio start sdk=${Build.VERSION.SDK_INT} " +
                "model=${Build.MODEL} weak=${weakRadio()} " +
                "bt=${adapter.isEnabled} loc=$locOn " +
                "session=$dartSession advertiser=${adapter.bluetoothLeAdvertiser != null}",
        )
        if (weakRadio()) {
            startDutyCycle(adapter)
        } else {
            stopDutyCycle()
            startAdvertise(adapter)
            startScan(adapter)
        }
        watch(
            "radio skip=${lastSkip.ifEmpty { "ok" }} " +
                "advertise=$advertiseStarted scan=$scanStarted duty=$dutyRunning",
        )
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
            "advertiseConnectable" to wantsIncomingGatt(),
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
            "lastConnect" to lastConnectNote,
            "lastGattStatus" to lastGattStatus,
            "lastGattServer" to lastGattServerStatus,
            "gattServer" to (gattServer != null),
            "weakRadio" to weakRadio(),
            "amazonRadio" to amazonRadio(),
            "canHostHotspot" to !cannotHostHotspot(),
            "lanIpv4" to lanIpv4(),
            "dutyPhase" to when {
                !dutyRunning -> "off"
                dutyAdvertisePhase -> "advertise"
                else -> "scan"
            },
            "connectAttempt" to connectAttempt,
            "waitingConnect" to waitingConnectId,
        )
    }

    /// Fire OS, ColorOS, Xiaomi, and most API 30 radios cannot scan, advertise,
    /// and be a GATT central/peripheral at once. Time-slice discovery there.
    private fun weakRadio(): Boolean {
        if (amazonRadio()) return true
        val mfr = Build.MANUFACTURER.lowercase()
        val brand = Build.BRAND.lowercase()
        return Build.VERSION.SDK_INT < 31 ||
            mfr == "oppo" ||
            mfr == "oneplus" ||
            mfr == "realme" ||
            mfr.contains("oplus") ||
            mfr.contains("xiaomi") ||
            mfr == "redmi" ||
            mfr == "poco" ||
            brand.contains("xiaomi") ||
            brand == "redmi" ||
            brand == "poco"
    }

    /// Fire tablets ship without SoftAP / tethering. LocalOnlyHotspot fails
    /// immediately; they can still *join* a phone-hosted private AP.
    private fun amazonRadio(): Boolean {
        val mfr = Build.MANUFACTURER.lowercase()
        val brand = Build.BRAND.lowercase()
        val product = Build.PRODUCT.lowercase()
        val model = Build.MODEL.lowercase()
        return mfr == "amazon" ||
            brand == "amazon" ||
            product.contains("fire") ||
            model.startsWith("kf")
    }

    private fun cannotHostHotspot(): Boolean {
        return amazonRadio() || Build.VERSION.SDK_INT < 29
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
        stopDutyCycle()
        stopScanQuiet()
        stopAdvertiseQuiet()
    }

    @SuppressLint("MissingPermission")
    private fun stopScanQuiet() {
        try {
            if (scanStarted) scanner?.stopScan(scanCallback)
        } catch (_: Exception) {
        }
        scanStarted = false
        scanAppliedHard = false
    }

    @SuppressLint("MissingPermission")
    private fun stopAdvertiseQuiet() {
        try {
            if (advertiseStarted) advertiser?.stopAdvertising(advertiseCallback)
        } catch (_: Exception) {
        }
        advertiseStarted = false
        advertisedKey = ""
    }

    private fun stopDutyCycle() {
        dutyRunning = false
        main.removeCallbacks(dutyTick)
    }

    @SuppressLint("MissingPermission")
    private fun startDutyCycle(adapter: BluetoothAdapter) {
        stopDutyCycle()
        dutyRunning = true
        dutyAdvertisePhase = true
        watch(
            "duty cycle on advertise=${DUTY_ADVERTISE_MS}ms scan=${DUTY_SCAN_MS}ms",
        )
        applyDutyPhase(adapter)
    }

    @SuppressLint("MissingPermission")
    private fun applyDutyPhase(adapter: BluetoothAdapter) {
        if (!dutyRunning || radioPausedForConnect || radioHeldForCamera || !running) return
        if (dutyAdvertisePhase) {
            stopScanQuiet()
            startAdvertise(adapter)
            main.postDelayed(dutyTick, DUTY_ADVERTISE_MS)
        } else {
            stopAdvertiseQuiet()
            startScan(adapter)
            main.postDelayed(dutyTick, DUTY_SCAN_MS)
        }
    }

    @SuppressLint("MissingPermission")
    private fun tickDutyCycle() {
        if (!dutyRunning || radioPausedForConnect || radioHeldForCamera || !running) return
        dutyAdvertisePhase = !dutyAdvertisePhase
        val adapter = bluetoothAdapter() ?: return
        applyDutyPhase(adapter)
    }

    @SuppressLint("MissingPermission")
    private fun closeGattServer() {
        try {
            gattServer?.close()
        } catch (_: Exception) {
        }
        gattServer = null
        infoChar = null
        linkChar = null
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
                BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE or
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

    private fun wantsIncomingGatt(): Boolean {
        return dartSession || System.currentTimeMillis() < incomingGattUntil
    }

    private fun noteSenderSession() {
        val now = System.currentTimeMillis()
        val was = wantsIncomingGatt()
        incomingGattUntil = now + INCOMING_GATT_MS
        main.removeCallbacks(dropIncomingGatt)
        main.postDelayed(dropIncomingGatt, INCOMING_GATT_MS)
        if (was || radioPausedForConnect || radioHeldForCamera || !running) return
        bluetoothAdapter()?.let { startAdvertise(it) }
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
        val connectable = wantsIncomingGatt()
        val key =
            "$peerId|$httpPort|$advertiseMode|$connectable|$advertiseCompact|${beacon.contentHashCode()}|${nameBytes.contentHashCode()}"
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
            .setConnectable(connectable)
            .setTimeout(0)
            .build()
        val payload = if (advertiseCompact && nameBytes.isNotEmpty()) {
            beacon + nameBytes
        } else {
            beacon.copyOf()
        }
        if (dartSession && payload.size > 3) {
            payload[3] = (payload[3].toInt() or SESSION_FLAG).toByte()
        }
        val advertiseNote =
            "advertise connectable=$connectable session=$dartSession bytes=${payload.size}"
        if (advertiseNote != lastAdvertiseLog) {
            lastAdvertiseLog = advertiseNote
            watch(advertiseNote)
            Log.i(TAG, advertiseNote)
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
            watch("scan start hard=$scanHard")
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
            if (adapter != null && !radioHeldForCamera) {
                startAdvertise(adapter)
                startScan(adapter)
            }
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
        incomingGattUntil = 0L
        main.removeCallbacks(dropIncomingGatt)
        teardownClient()
        stopHotspot()
        pauseDiscovery()
        releaseMulticast()
        try {
            gattServer?.close()
        } catch (_: Exception) {
        }
        gattServer = null
        infoChar = null
        linkChar = null
        gattServiceRetry = false
        devices.clear()
        deviceSeenAt.clear()
        waitingConnectId = null
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
        connectDevice = device
        connectAttempt = 0
        gattLinked = false
        infoRead = false
        hostWritten = false
        boundForHotspot = false
        joinStarted = false
        swapStarted = false
        joinFinished = false
        amazonLegacyTried = false
        joinTargetSsid = ""
        joinReadyTo = null
        main.removeCallbacks(joinPoll)
        lastGattStatus = null
        val gen = ++connectGen
        main.postDelayed({
            if (gen == connectGen) {
                lastConnectNote = "timeout gatt=${lastGattStatus ?: "none"} try=$connectAttempt"
                failConnect("Could not reach them nearby")
            }
        }, if (amazonRadio()) 80_000 else 70_000)
        val age = System.currentTimeMillis() - (deviceSeenAt[id] ?: 0L)
        if (age in 0 until FRESH_SIGHTING_MS) {
            lastConnectNote = "fresh sighting ${age}ms — connecting ${device.address}"
            beginConnectNow(device, gen)
            return
        }
        waitForPeerThenConnect(id, device, gen)
    }

    @SuppressLint("MissingPermission")
    private fun waitForPeerThenConnect(id: String, device: BluetoothDevice, gen: Int) {
        waitingConnectId = id
        lastConnectNote = "waiting for $id"
        watch(lastConnectNote)
        Log.i(TAG, lastConnectNote)
        stopDutyCycle()
        stopAdvertiseQuiet()
        val adapter = bluetoothAdapter()
        try {
            adapter?.cancelDiscovery()
        } catch (_: Exception) {
        }
        if (adapter != null) startScan(adapter)
        main.postDelayed({
            if (gen != connectGen || pendingConnect == null) return@postDelayed
            if (waitingConnectId != id) return@postDelayed
            lastConnectNote = "stale wait — connecting anyway"
            beginConnectNow(connectDevice ?: device, gen)
        }, WAIT_FOR_PEER_MS)
    }

    @SuppressLint("MissingPermission")
    private fun beginConnectNow(device: BluetoothDevice, gen: Int) {
        if (gen != connectGen || pendingConnect == null) return
        if (radioPausedForConnect) return
        waitingConnectId = null
        connectDevice = device
        lastConnectNote = "connecting ${device.address}"
        watch(lastConnectNote)
        // Scan/advertise/GATT-server while connectGatt is the classic
        // Android hang — Fire OS, ColorOS, and HyperOS never fire a callback.
        pauseForConnect()
        main.postDelayed({
            if (gen != connectGen) return@postDelayed
            openGatt(device, 0)
        }, 400)
    }

    @SuppressLint("MissingPermission")
    private fun pauseForConnect() {
        radioPausedForConnect = true
        watch("radio pause for GATT connect")
        stopDutyCycle()
        stopScanQuiet()
        stopAdvertiseQuiet()
        closeGattServer()
        gattServerHeldOff = true
        try {
            bluetoothAdapter()?.cancelDiscovery()
        } catch (_: Exception) {
        }
    }

    @SuppressLint("MissingPermission")
    private fun resumeAfterConnect() {
        if (!radioPausedForConnect && !gattServerHeldOff) return
        radioPausedForConnect = false
        if (gattServerHeldOff) {
            gattServerHeldOff = false
            val ctx = app
            val manager = ctx?.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
            if (manager != null) openGattServer(manager)
        }
        if (!running || radioHeldForCamera) return
        val adapter = bluetoothAdapter() ?: return
        watch("radio resume after GATT")
        if (weakRadio()) {
            startDutyCycle(adapter)
        } else {
            startAdvertise(adapter)
            startScan(adapter)
        }
    }

    @SuppressLint("MissingPermission")
    private fun openGatt(device: BluetoothDevice, attempt: Int) {
        if (pendingConnect == null) return
        connectAttempt = attempt
        val autoConnect = attempt >= 1
        val transport = if (attempt >= 2 && Build.VERSION.SDK_INT >= 23) {
            BluetoothDevice.TRANSPORT_AUTO
        } else {
            BluetoothDevice.TRANSPORT_LE
        }
        lastConnectNote = "gatt try=$attempt auto=$autoConnect transport=$transport"
        watch(lastConnectNote)
        Log.i(TAG, lastConnectNote)
        try {
            activeGatt?.disconnect()
        } catch (_: Exception) {
        }
        try {
            activeGatt?.close()
        } catch (_: Exception) {
        }
        activeGatt = null
        val ctx = app ?: return failConnect("Gallery is not open")
        val gen = connectGen
        try {
            activeGatt = when {
                Build.VERSION.SDK_INT >= 26 -> device.connectGatt(
                    ctx,
                    autoConnect,
                    gattClientCallback,
                    transport,
                    BluetoothDevice.PHY_LE_1M,
                    main,
                )
                Build.VERSION.SDK_INT >= 23 ->
                    device.connectGatt(ctx, autoConnect, gattClientCallback, transport)
                else -> {
                    @Suppress("DEPRECATION")
                    device.connectGatt(ctx, autoConnect, gattClientCallback)
                }
            }
            if (activeGatt == null) {
                failConnect("Bluetooth failed")
                return
            }
            main.postDelayed({
                if (gen != connectGen || pendingConnect == null) return@postDelayed
                if (!gattLinked && connectAttempt == attempt && attempt < 2) {
                    lastConnectNote =
                        "hung gatt=${lastGattStatus ?: "none"} try=$attempt — retry"
                    watch(lastConnectNote)
            Log.w(TAG, lastConnectNote)
                    openGatt(device, attempt + 1)
                }
            }, 8_000)
        } catch (error: Exception) {
            failConnect(error.message ?: "Bluetooth failed")
        }
    }

    @SuppressLint("MissingPermission")
    private fun retryGattOrFail(gatt: BluetoothGatt, status: Int) {
        lastGattStatus = status
        lastConnectNote = "gatt dropped status=$status try=$connectAttempt"
        watch(lastConnectNote)
        Log.w(TAG, lastConnectNote)
        if (gattLinked) {
            failConnect("Bluetooth dropped")
            return
        }
        val device = connectDevice ?: gatt.device
        if (connectAttempt < 2 && pendingConnect != null) {
            main.postDelayed({
                if (pendingConnect == null) return@postDelayed
                openGatt(device, connectAttempt + 1)
            }, 400L * (connectAttempt + 1))
            return
        }
        failConnect("Could not reach them nearby")
    }

    @SuppressLint("MissingPermission")
    private fun failConnect(message: String) {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            main.post { failConnect(message) }
            return
        }
        val pending = pendingConnect ?: return
        connectGen++
        pendingConnect = null
        waitingConnectId = null
        connectDevice = null
        hostWritten = false
        infoRead = false
        main.removeCallbacks(offerPoll)
        main.removeCallbacks(joinPoll)
        watch("link fail $message last=$lastConnectNote")
        try {
            activeGatt?.close()
        } catch (_: Exception) {
        }
        activeGatt = null
        resumeAfterConnect()
        try {
            pending.error("link", message, null)
        } catch (_: Exception) {
        }
    }

    @SuppressLint("MissingPermission")
    private fun succeedConnect(host: String, port: Int) {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            main.post { succeedConnect(host, port) }
            return
        }
        val pending = pendingConnect ?: return
        connectGen++
        pendingConnect = null
        waitingConnectId = null
        connectDevice = null
        hostWritten = false
        infoRead = false
        main.removeCallbacks(offerPoll)
        main.removeCallbacks(joinPoll)
        lastConnectNote = "linked $host:$port"
        watch(lastConnectNote)
        if (!boundForHotspot) {
            try {
                activeGatt?.close()
            } catch (_: Exception) {
            }
            activeGatt = null
            resumeAfterConnect()
        }
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
        releaseJoin()
        try {
            activeGatt?.close()
        } catch (_: Exception) {
        }
        activeGatt = null
        resumeAfterConnect()
    }

    private fun releaseJoin() {
        main.removeCallbacks(joinPoll)
        joinFinished = false
        joinTargetSsid = ""
        joinReadyTo = null
        val ctx = app
        val cm = ctx?.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
        try {
            cm?.bindProcessToNetwork(null)
        } catch (_: Exception) {
        }
        boundNetwork = null
        boundForHotspot = false
        val callback = joinCallback
        joinCallback = null
        if (callback != null) {
            try {
                cm?.unregisterNetworkCallback(callback)
            } catch (_: Exception) {
            }
        }
    }

    private fun stopHotspot() {
        try {
            hotspot?.close()
        } catch (_: Exception) {
        }
        hotspot = null
        if (linkOffer?.optString("t") == "ap") {
            linkOffer = null
        }
    }

    @SuppressLint("MissingPermission")
    private fun handleHostRequest(device: BluetoothDevice) {
        if (cannotHostHotspot()) {
            lastConnectNote = "this device cannot host a private AP — asking peer"
            watch(lastConnectNote)
            offerSwap(device)
            return
        }
        val ctx = app ?: return
        val wifi = ctx.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        if (hotspot != null) {
            watch("hotspot already up — notify peer")
            notifyAp(device)
            return
        }
        watch("hotspot starting")
        try {
            wifi.startLocalOnlyHotspot(
                object : WifiManager.LocalOnlyHotspotCallback() {
                    override fun onStarted(reservation: WifiManager.LocalOnlyHotspotReservation) {
                        hotspot = reservation
                        watch("hotspot started ssidLen=${hotspotSsidLen(reservation)}")
                        main.postDelayed({ notifyAp(device) }, 400)
                    }

                    override fun onFailed(reason: Int) {
                        lastConnectNote = "hotspot failed reason=$reason — swap"
                        watch(lastConnectNote)
            Log.w(TAG, lastConnectNote)
                        offerSwap(device)
                    }
                },
                main,
            )
        } catch (error: Exception) {
            watch("hotspot threw ${error.javaClass.simpleName}")
            Log.w(TAG, "hotspot", error)
            offerSwap(device)
        }
    }

    private fun hotspotSsidLen(reservation: WifiManager.LocalOnlyHotspotReservation): Int {
        return try {
            if (Build.VERSION.SDK_INT >= 30) {
                reservation.softApConfiguration.ssid?.trim('"')?.length ?: 0
            } else {
                @Suppress("DEPRECATION")
                reservation.wifiConfiguration?.SSID?.trim('"')?.length ?: 0
            }
        } catch (_: Exception) {
            0
        }
    }

    private fun offerSwap(device: BluetoothDevice) {
        watch("offer swap — ask peer to host AP")
        val json = JSONObject().put("t", "swap")
        linkOffer = json
        notifyLink(device, json)
    }

    @SuppressLint("MissingPermission")
    private fun notifyAp(device: BluetoothDevice) {
        val json = apJson() ?: return
        linkOffer = json
        notifyLink(device, json)
    }

    private fun apJson(): JSONObject? {
        val reservation = hotspot ?: return null
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
        if (ssid.isEmpty() || psk.isEmpty()) return null
        return JSONObject()
            .put("t", "ap")
            .put("ssid", ssid)
            .put("psk", psk)
            .put("ip", hotspotGateway())
            .put("port", httpPort)
    }

    @SuppressLint("MissingPermission")
    private fun notifyLink(device: BluetoothDevice, json: JSONObject) {
        val characteristic = linkChar ?: return
        val bytes = linkJsonBytes(json)
        characteristic.value = bytes
        if (Build.VERSION.SDK_INT >= 33) {
            gattServer?.notifyCharacteristicChanged(device, characteristic, false, bytes)
        } else {
            @Suppress("DEPRECATION")
            gattServer?.notifyCharacteristicChanged(device, characteristic, false)
        }
    }

    /// ColorOS HID filter drops exactly 22-byte GATT notifies
    /// (`{"t":"err","m":"wifi"}`). Pad so the stack delivers them.
    private fun linkJsonBytes(json: JSONObject): ByteArray {
        var n = 0
        var bytes = json.toString().toByteArray(Charsets.UTF_8)
        while (bytes.size == 22 && n < 4) {
            json.put("z", n)
            bytes = json.toString().toByteArray(Charsets.UTF_8)
            n++
        }
        if (bytes.size < 24) {
            json.put("z", 1)
            bytes = json.toString().toByteArray(Charsets.UTF_8)
        }
        return bytes
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

    private fun lanIpv4(): String {
        try {
            val ifaces = NetworkInterface.getNetworkInterfaces() ?: return ""
            for (iface in ifaces) {
                val name = iface.name.lowercase()
                if (name.contains("rmnet") ||
                    name.contains("ccmni") ||
                    name.contains("wwan") ||
                    name.contains("dummy") ||
                    name.contains("ap") ||
                    name.contains("swlan") ||
                    name.contains("p2p") ||
                    name == "lo"
                ) {
                    continue
                }
                val addrs = iface.inetAddresses ?: continue
                for (addr in addrs) {
                    if (addr !is Inet4Address || addr.isLoopbackAddress) continue
                    val ip = addr.hostAddress ?: continue
                    if (ip.startsWith("169.254.")) continue
                    if (ip.startsWith("192.168.49.")) continue
                    if (ip.startsWith("192.168.43.")) continue
                    if (ip.startsWith("192.168.137.")) continue
                    if (ip.startsWith("192.168.173.")) continue
                    if (ip.startsWith("100.")) {
                        val b = ip.split('.')
                        val second = b.getOrNull(1)?.toIntOrNull() ?: 0
                        if (second in 64..127) continue
                    }
                    return ip
                }
            }
        } catch (_: Exception) {
        }
        return ""
    }

    private fun sameLan24(a: String, b: String): Boolean {
        if (a.isEmpty() || b.isEmpty()) return false
        val left = a.split('.')
        val right = b.split('.')
        if (left.size != 4 || right.size != 4) return false
        return left[0] == right[0] && left[1] == right[1] && left[2] == right[2]
    }

    private fun ipv4On(network: Network): String {
        val ctx = app ?: return ""
        val cm = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            ?: return ""
        val props = cm.getLinkProperties(network) ?: return ""
        for (addr in props.linkAddresses) {
            val inet = addr.address
            if (inet is Inet4Address && !inet.isLoopbackAddress) {
                return inet.hostAddress ?: continue
            }
        }
        return ""
    }

    private fun lanReachable(host: String, port: Int): Boolean {
        return try {
            java.net.Socket().use { socket ->
                socket.connect(java.net.InetSocketAddress(host, port), 900)
                true
            }
        } catch (_: Exception) {
            false
        }
    }

    private fun joinWaitMs(): Long = if (amazonRadio()) 45_000 else 25_000

    private fun joinAp(
        ssid: String,
        psk: String,
        ip: String,
        port: Int,
        readyTo: BluetoothDevice? = null,
    ) {
        val ctx = app ?: return failConnect("Gallery is not open")
        if (ssid.isEmpty() || psk.isEmpty()) {
            watch("join AP missing ssid=${ssid.isNotEmpty()} psk=${psk.isNotEmpty()}")
            failJoin("The other device could not open Wi-Fi")
            return
        }
        if (Build.VERSION.SDK_INT < 29) {
            watch("join AP blocked sdk=${Build.VERSION.SDK_INT}")
            failJoin("Nearby Wi-Fi needs Android 10+")
            return
        }
        joinTargetSsid = ssid
        joinTargetPsk = psk
        joinTargetIp = ip
        joinTargetPort = port
        joinReadyTo = readyTo
        joinFinished = false
        amazonLegacyTried = false
        joinUntil = System.currentTimeMillis() + joinWaitMs()
        val waitMs = joinWaitMs()
        watch("join AP ssidLen=${ssid.length} wait=${waitMs}ms amazon=${amazonRadio()}")
        if (amazonRadio()) {
            watch("wifi join: Fire may show a Connect prompt — keep One Drop open")
            suggestAmazonWifi(ctx, ssid, psk)
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
                watch("wifi join available")
                finishJoin(network)
            }

            override fun onUnavailable() {
                // Fire OS pops NetworkRequestDialogActivity then reports
                // unavailable / NetReassign[no changes] without binding.
                // Keep polling WifiInfo — the user may still tap Connect.
                watch("wifi join unavailable amazon=${amazonRadio()}")
                if (amazonRadio()) return
                main.post { failJoin("Could not join the private Wi-Fi") }
            }
        }
        joinCallback = callback
        try {
            if (amazonRadio()) {
                cm.requestNetwork(request, callback)
            } else {
                cm.requestNetwork(request, callback, waitMs.toInt())
            }
        } catch (error: Exception) {
            failJoin(error.message ?: "Wi-Fi join failed")
            return
        }
        main.removeCallbacks(joinPoll)
        main.postDelayed(joinPoll, 400)
    }

    private fun pollJoinedAp() {
        if (joinFinished || joinTargetSsid.isEmpty()) return
        if (System.currentTimeMillis() > joinUntil) {
            watch("wifi join timeout")
            failJoin("Could not join the private Wi-Fi")
            return
        }
        val ctx = app ?: return
        val cm = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            ?: return
        val matched = wifiNetworkForSsid(cm, joinTargetSsid)
        if (matched != null) {
            watch("wifi join poll matched")
            finishJoin(matched)
            return
        }
        val startedAgo = joinWaitMs() - (joinUntil - System.currentTimeMillis())
        if (amazonRadio() && !amazonLegacyTried && startedAgo >= 5_000) {
            nudgeAmazonWifi(joinTargetSsid, joinTargetPsk)
        }
        main.postDelayed(joinPoll, 500)
    }

    private fun finishJoin(network: Network) {
        if (joinFinished) return
        joinFinished = true
        main.removeCallbacks(joinPoll)
        val ctx = app ?: return
        val cm = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        boundNetwork = network
        boundForHotspot = true
        try {
            cm.bindProcessToNetwork(network)
        } catch (_: Exception) {
        }
        val readyTo = joinReadyTo
        val ip = joinTargetIp
        val port = joinTargetPort
        watch("wifi join bound")
        main.post {
            if (readyTo != null) {
                val mine = ipv4On(network).ifBlank { ip }
                watch("wifi join ready ipLen=${mine.length}")
                val json = JSONObject()
                    .put("t", "ready")
                    .put("ip", mine)
                    .put("port", httpPort)
                linkOffer = json
                notifyLink(readyTo, json)
                return@post
            }
            succeedConnect(ip, port)
        }
    }

    private fun failJoin(message: String) {
        main.removeCallbacks(joinPoll)
        val readyTo = joinReadyTo
        if (readyTo != null && pendingConnect == null) {
            watch("wifi join fail as peer $message")
            notifyLink(
                readyTo,
                JSONObject().put("t", "err").put("m", "wifi"),
            )
            return
        }
        failConnect(message)
    }

    @Suppress("DEPRECATION")
    private fun currentWifiSsid(): String {
        val ctx = app ?: return ""
        val wifi = ctx.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            ?: return ""
        return try {
            wifi.connectionInfo?.ssid.orEmpty().trim('"').replace("<unknown ssid>", "", true)
        } catch (_: Exception) {
            ""
        }
    }

    private fun wifiNetworkForSsid(cm: ConnectivityManager, ssid: String): Network? {
        if (ssid.isEmpty()) return null
        val current = currentWifiSsid()
        if (!ssid.equals(current, ignoreCase = true)) return null
        for (network in cm.allNetworks) {
            val caps = cm.getNetworkCapabilities(network) ?: continue
            if (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) return network
        }
        return null
    }

    @SuppressLint("MissingPermission")
    private fun suggestAmazonWifi(ctx: Context, ssid: String, psk: String) {
        if (Build.VERSION.SDK_INT < 29) return
        try {
            val suggestion = WifiNetworkSuggestion.Builder()
                .setSsid(ssid)
                .setWpa2Passphrase(psk)
                .setIsAppInteractionRequired(false)
                .build()
            val wifi = ctx.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            val code = wifi.addNetworkSuggestions(listOf(suggestion))
            watch("wifi join suggestion status=$code")
        } catch (error: Exception) {
            watch("wifi join suggestion ${error.javaClass.simpleName}")
        }
    }

    @Suppress("DEPRECATION")
    @SuppressLint("MissingPermission")
    private fun nudgeAmazonWifi(ssid: String, psk: String) {
        if (amazonLegacyTried) return
        amazonLegacyTried = true
        val ctx = app ?: return
        watch("wifi join nudge Fire addNetwork")
        try {
            val wifi = ctx.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            val conf = WifiConfiguration()
            conf.SSID = "\"$ssid\""
            conf.preSharedKey = "\"$psk\""
            conf.allowedKeyManagement.set(WifiConfiguration.KeyMgmt.WPA_PSK)
            val netId = wifi.addNetwork(conf)
            if (netId >= 0) {
                wifi.enableNetwork(netId, true)
                wifi.reconnect()
                watch("wifi join nudge netId=$netId")
            } else {
                watch("wifi join nudge addNetwork failed")
            }
        } catch (error: Exception) {
            watch("wifi join nudge ${error.javaClass.simpleName}")
        }
    }

    private fun privateIpv4(ip: String): Boolean {
        val parts = ip.split('.')
        if (parts.size != 4) return false
        val a = parts[0].toIntOrNull() ?: return false
        val b = parts[1].toIntOrNull() ?: return false
        return a == 10 || (a == 192 && b == 168) || (a == 172 && b in 16..31)
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
            watch("advertise failed $errorCode")
            Log.w(TAG, "advertise failed $errorCode")
        }
    }

    private fun ingestScan(result: ScanResult) {
        val record = result.scanRecord ?: return
        val beacon = record.getManufacturerSpecificData(COMPANY)
        val name = record.getManufacturerSpecificData(COMPANY_NAME)
            ?: record.deviceName?.toByteArray(Charsets.UTF_8)
        val sighting = parseBeacon(beacon, name) ?: return
        val now = System.currentTimeMillis()
        val lastAt = lastPeerWatchAt[sighting.id] ?: 0L
        if (lastAt == 0L || now - lastAt >= 1_000L) {
            lastPeerWatchAt[sighting.id] = now
            val session =
                beacon != null && beacon.size > 3 && (beacon[3].toInt() and SESSION_FLAG) != 0
            watch(
                "ble peer ${sighting.name} rssi=${result.rssi} " +
                    "os=${sighting.os} session=$session addr=${result.device.address}",
            )
        }
        if (beacon != null && beacon.size > 3 && (beacon[3].toInt() and SESSION_FLAG) != 0) {
            main.post { noteSenderSession() }
        }
        devices[sighting.id] = result.device
        deviceSeenAt[sighting.id] = System.currentTimeMillis()
        val waiting = waitingConnectId
        if (waiting == sighting.id && pendingConnect != null) {
            val gen = connectGen
            main.post { beginConnectNow(result.device, gen) }
        }
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
            watch("scan failed $errorCode")
            Log.w(TAG, "scan failed $errorCode")
        }
    }

    private val gattServerCallback = object : BluetoothGattServerCallback() {
        override fun onServiceAdded(status: Int, service: BluetoothGattService) {
            lastGattServerStatus = status
            lastConnectNote = "gatt service added status=$status"
            watch(lastConnectNote)
            Log.i(TAG, lastConnectNote)
            if (status != BluetoothGatt.GATT_SUCCESS && !gattServiceRetry) {
                gattServiceRetry = true
                main.post {
                    closeGattServer()
                    val ctx = app ?: return@post
                    val manager = ctx.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
                    if (manager != null) openGattServer(manager)
                }
            }
        }

        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            lastGattServerStatus = status
            lastConnectNote = "gatt server state=$newState status=$status"
            watch(lastConnectNote)
            Log.i(TAG, lastConnectNote)
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                // Incoming GATT needs the scanner off on cheap radios.
                stopDutyCycle()
                stopScanQuiet()
                return
            }
            if (newState == BluetoothProfile.STATE_DISCONNECTED &&
                dartSession &&
                weakRadio() &&
                !radioPausedForConnect &&
                running &&
                !radioHeldForCamera
            ) {
                bluetoothAdapter()?.let { startDutyCycle(it) }
            }
        }

        override fun onCharacteristicReadRequest(
            device: BluetoothDevice,
            requestId: Int,
            offset: Int,
            characteristic: BluetoothGattCharacteristic,
        ) {
            if (characteristic.uuid != INFO_UUID) {
                watch("gatt read ignored uuid")
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_FAILURE, 0, null)
                return
            }
            watch("gatt info read offset=$offset")
            val payload = JSONObject()
                .put("v", 1)
                .put("peerId", peerId)
                .put("name", displayName)
                .put("port", httpPort)
                .put("lan", lanIpv4())
                .put("canHost", !cannotHostHotspot())
            linkOffer?.let { payload.put("offer", it) }
            val json = payload.toString().toByteArray(Charsets.UTF_8)
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
            watch("gatt write in t=$type bytes=${value.size}")
            when (type) {
                "host" -> main.post { handleHostRequest(device) }
                "ap" -> main.post {
                    val json = runCatching { JSONObject(text) }.getOrNull() ?: return@post
                    joinAp(
                        json.optString("ssid"),
                        json.optString("psk"),
                        json.optString("ip").ifBlank { "192.168.49.1" },
                        json.optInt("port", httpPort),
                        readyTo = device,
                    )
                }
                "done" -> main.post {
                    stopHotspot()
                    releaseJoin()
                }
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
            lastGattStatus = status
            lastConnectNote = "gatt state=$newState status=$status try=$connectAttempt"
            watch(lastConnectNote)
            Log.i(TAG, lastConnectNote)
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                gattLinked = true
                try {
                    gatt.requestConnectionPriority(BluetoothGatt.CONNECTION_PRIORITY_HIGH)
                } catch (_: Exception) {
                }
                try {
                    gatt.requestMtu(185)
                } catch (_: Exception) {
                }
                gatt.discoverServices()
                val gen = connectGen
                main.postDelayed({
                    if (gen != connectGen || pendingConnect == null || infoRead || hostWritten) {
                        return@postDelayed
                    }
                    lastConnectNote = "discover stall — retry"
                    try {
                        gatt.discoverServices()
                    } catch (_: Exception) {
                    }
                }, 6_000)
                return
            }
            if (newState == BluetoothProfile.STATE_DISCONNECTED && pendingConnect != null) {
                retryGattOrFail(gatt, status)
            }
        }

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            lastConnectNote = "mtu=$mtu status=$status"
            watch(lastConnectNote)
        }

        @SuppressLint("MissingPermission")
        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            lastGattStatus = status
            if (status != BluetoothGatt.GATT_SUCCESS) {
                lastConnectNote = "discover_failed_$status"
                watch(lastConnectNote)
                main.post { failConnect("That device is not ready for One Drop") }
                return
            }
            watch("gatt services discovered")
            readPeerInfo(gatt)
            val gen = connectGen
            main.postDelayed({
                if (gen != connectGen || pendingConnect == null || infoRead || hostWritten) {
                    return@postDelayed
                }
                subscribeAndAskHost(gatt)
            }, 2_400)
        }

        @SuppressLint("MissingPermission")
        override fun onCharacteristicRead(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
            status: Int,
        ) {
            if (status == BluetoothGatt.GATT_SUCCESS) {
                watch("gatt info read ${value.size}b")
                handleInfoBytes(gatt, value)
            } else {
                watch("gatt info read failed status=$status")
            }
        }

        @Deprecated("Older Android")
        @SuppressLint("MissingPermission")
        override fun onCharacteristicRead(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int,
        ) {
            if (status != BluetoothGatt.GATT_SUCCESS) return
            @Suppress("DEPRECATION")
            handleInfoBytes(gatt, characteristic.value ?: return)
        }

        @SuppressLint("MissingPermission")
        override fun onDescriptorWrite(
            gatt: BluetoothGatt,
            descriptor: BluetoothGattDescriptor,
            status: Int,
        ) {
            lastConnectNote = "cccd status=$status"
            watch(lastConnectNote)
            writeHostCommand(gatt)
        }

        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
        ) {
            applyLinkOffer(runCatching { JSONObject(String(value, Charsets.UTF_8)) }.getOrNull() ?: return)
        }

        @Deprecated("Older Android")
        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
        ) {
            @Suppress("DEPRECATION")
            val value = characteristic.value ?: return
            applyLinkOffer(runCatching { JSONObject(String(value, Charsets.UTF_8)) }.getOrNull() ?: return)
        }
    }

    @SuppressLint("MissingPermission")
    private fun readPeerInfo(gatt: BluetoothGatt) {
        val info = gatt.getService(SERVICE_UUID)?.getCharacteristic(INFO_UUID)
        if (info == null) {
            subscribeAndAskHost(gatt)
            return
        }
        try {
            gatt.readCharacteristic(info)
        } catch (_: Exception) {
            subscribeAndAskHost(gatt)
        }
    }

    @SuppressLint("MissingPermission")
    private fun handleInfoBytes(gatt: BluetoothGatt, value: ByteArray) {
        val json = runCatching { JSONObject(String(value, Charsets.UTF_8)) }.getOrNull() ?: return
        val offer = json.optJSONObject("offer")
        if (offer != null) {
            applyLinkOffer(offer)
            if (pendingConnect == null) return
        }
        if (infoRead && hostWritten) return
        infoRead = true
        val lan = json.optString("lan").trim()
        val port = json.optInt("port", httpPort)
        val mine = lanIpv4()
        val sameLan = sameLan24(mine, lan)
        if (!joinStarted &&
            !swapStarted &&
            privateIpv4(lan) &&
            port > 0
        ) {
            lastConnectNote = "probing LAN $lan:$port same=$sameLan"
            watch(lastConnectNote)
            val gen = connectGen
            Thread {
                val ok = lanReachable(lan, port)
                main.post {
                    if (gen != connectGen || pendingConnect == null) return@post
                    if (ok && !joinStarted && !swapStarted) {
                        lastConnectNote = "same Wi-Fi $lan — skip hotspot"
                        watch(lastConnectNote)
                        Log.i(TAG, lastConnectNote)
                        succeedConnect(lan, port)
                    } else {
                        watch("LAN probe failed — hotspot next")
                        subscribeAndAskHost(gatt)
                    }
                }
            }.start()
            return
        }
        subscribeAndAskHost(gatt)
    }

    @SuppressLint("MissingPermission")
    private fun subscribeAndAskHost(gatt: BluetoothGatt) {
        if (hostWritten || pendingConnect == null) return
        val link = gatt.getService(SERVICE_UUID)?.getCharacteristic(LINK_UUID)
        if (link == null) {
            watch("subscribe failed — no LINK char")
            failConnect("That device is not ready for One Drop")
            return
        }
        watch("subscribe link notify")
        try {
            gatt.setCharacteristicNotification(link, true)
        } catch (_: Exception) {
        }
        val cccd = link.getDescriptor(CCCD_UUID)
        var wrote = false
        if (cccd != null) {
            val enabled = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
            wrote = try {
                if (Build.VERSION.SDK_INT >= 33) {
                    gatt.writeDescriptor(cccd, enabled) == BluetoothGatt.GATT_SUCCESS
                } else {
                    @Suppress("DEPRECATION")
                    cccd.value = enabled
                    @Suppress("DEPRECATION")
                    gatt.writeDescriptor(cccd)
                }
            } catch (_: Exception) {
                false
            }
        }
        val gen = connectGen
        // Fire OS often never fires onDescriptorWrite. Do not wait forever.
        main.postDelayed({
            if (gen != connectGen || pendingConnect == null || hostWritten) return@postDelayed
            lastConnectNote = "cccd silent — write host anyway"
            watch(lastConnectNote)
            Log.w(TAG, lastConnectNote)
            writeHostCommand(gatt)
        }, if (wrote) 1_600 else 200)
        if (!wrote) writeHostCommand(gatt)
    }

    @SuppressLint("MissingPermission")
    private fun writeHostCommand(gatt: BluetoothGatt) {
        if (hostWritten || pendingConnect == null) return
        val link = gatt.getService(SERVICE_UUID)?.getCharacteristic(LINK_UUID) ?: return
        hostWritten = true
        lastConnectNote = "write host"
        watch(lastConnectNote)
        writeLinkJson(gatt, link, JSONObject().put("t", "host"))
        main.removeCallbacks(offerPoll)
        main.post(offerPoll)
    }

    @SuppressLint("MissingPermission")
    private fun writeLinkJson(
        gatt: BluetoothGatt,
        link: BluetoothGattCharacteristic,
        json: JSONObject,
    ) {
        val payload = linkJsonBytes(json)
        try {
            if (Build.VERSION.SDK_INT >= 33) {
                gatt.writeCharacteristic(
                    link,
                    payload,
                    BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE,
                )
            } else {
                @Suppress("DEPRECATION")
                link.value = payload
                @Suppress("DEPRECATION")
                link.writeType = BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
                @Suppress("DEPRECATION")
                gatt.writeCharacteristic(link)
            }
        } catch (error: Exception) {
            Log.w(TAG, "write link", error)
        }
    }

    @SuppressLint("MissingPermission")
    private fun pollLinkOffer() {
        if (pendingConnect == null) return
        val gatt = activeGatt ?: return
        val info = gatt.getService(SERVICE_UUID)?.getCharacteristic(INFO_UUID)
        if (info != null) {
            try {
                gatt.readCharacteristic(info)
            } catch (_: Exception) {
            }
        }
        main.postDelayed(offerPoll, 450)
    }

    private fun applyLinkOffer(json: JSONObject) {
        val type = json.optString("t")
        watch("link offer t=$type")
        when (type) {
            "ap" -> main.post {
                if (joinStarted) return@post
                joinStarted = true
                joinAp(
                    json.optString("ssid"),
                    json.optString("psk"),
                    json.optString("ip").ifBlank { "192.168.49.1" },
                    json.optInt("port", httpPort),
                )
            }
            "swap" -> main.post {
                if (swapStarted) return@post
                swapStarted = true
                hostApForPeer()
            }
            "ready" -> main.post {
                succeedConnect(
                    json.optString("ip").ifBlank { "192.168.49.1" },
                    json.optInt("port", httpPort),
                )
            }
            "err" -> main.post {
                failConnect("The other device could not open Wi-Fi")
            }
        }
    }

    @SuppressLint("MissingPermission")
    private fun hostApForPeer() {
        if (cannotHostHotspot()) {
            watch("swap host blocked — neither can open AP")
            failConnect("Neither device can open the private Wi-Fi")
            return
        }
        val ctx = app ?: return failConnect("Gallery is not open")
        if (hotspot != null) {
            watch("swap host — hotspot already up")
            writeApToPeer()
            return
        }
        watch("swap host — starting hotspot")
        val wifi = ctx.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        try {
            wifi.startLocalOnlyHotspot(
                object : WifiManager.LocalOnlyHotspotCallback() {
                    override fun onStarted(reservation: WifiManager.LocalOnlyHotspotReservation) {
                        hotspot = reservation
                        watch("swap hotspot started ssidLen=${hotspotSsidLen(reservation)}")
                        main.postDelayed({ writeApToPeer() }, 400)
                    }

                    override fun onFailed(reason: Int) {
                        lastConnectNote = "sender hotspot failed $reason"
                        watch(lastConnectNote)
                        failConnect("Could not open the private Wi-Fi")
                    }
                },
                main,
            )
        } catch (error: Exception) {
            watch("swap hotspot threw ${error.javaClass.simpleName}")
            Log.w(TAG, "sender hotspot", error)
            failConnect("Could not open the private Wi-Fi")
        }
    }

    @SuppressLint("MissingPermission")
    private fun writeApToPeer() {
        val gatt = activeGatt ?: return
        val link = gatt.getService(SERVICE_UUID)?.getCharacteristic(LINK_UUID) ?: return
        val json = apJson() ?: return failConnect("Could not open the private Wi-Fi")
        linkOffer = json
        lastConnectNote = "wrote ap to peer"
        watch(lastConnectNote)
        writeLinkJson(gatt, link, json)
        main.removeCallbacks(offerPoll)
        main.post(offerPoll)
    }
}

