package one.aml.onedrop

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.lifecycle.Lifecycle

class OneDropListenService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        running = this
        OneDropP2p.ensurePresence(this)
        OneDropEngine.get(this)
        acquireIdleLocks()
        syncHotLocks()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        ensureChannels(this)
        applyForeground()
        OneDropP2p.ensurePresence(this)
        return START_STICKY
    }

    override fun onDestroy() {
        if (running === this) running = null
        OneDropP2p.onListenServiceStopped()
        releaseHotLocks()
        releaseIdleLocks()
        super.onDestroy()
    }

    fun applyForeground() {
        val notification = listenNotification()
        if (Build.VERSION.SDK_INT < 34) {
            startForeground(LISTEN_ID, notification)
            return
        }
        val wanted = foregroundTypes()
        try {
            startForeground(LISTEN_ID, notification, wanted)
            return
        } catch (error: Exception) {
            Log.w(TAG, "startForeground types=$wanted", error)
        }
        if (cameraWatch) {
            try {
                startForeground(
                    LISTEN_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE or
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA or
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
                )
                return
            } catch (error: Exception) {
                Log.w(TAG, "startForeground camera fallback", error)
            }
        }
        startForeground(
            LISTEN_ID,
            notification,
            ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
        )
    }

    private fun foregroundTypes(): Int {
        var types = ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
        if (Build.VERSION.SDK_INT >= 29) {
            types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
        }
        if (cameraWatch) {
            types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
        }
        return types
    }

    private fun acquireIdleLocks() {
        val wifi = applicationContext.getSystemService(WIFI_SERVICE) as WifiManager
        multicastLock = wifi.createMulticastLock("gallery:onedrop").apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    private fun releaseIdleLocks() {
        try {
            if (multicastLock?.isHeld == true) multicastLock?.release()
        } catch (_: Exception) {
        }
        multicastLock = null
    }

    fun syncHotLocks() {
        if (cameraWatch) acquireHotLocks() else releaseHotLocks()
    }

    private fun acquireHotLocks() {
        if (wakeLock?.isHeld == true && wifiLock?.isHeld == true) return
        val power = getSystemService(POWER_SERVICE) as PowerManager
        if (wakeLock?.isHeld != true) {
            wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "gallery:onedrop").apply {
                setReferenceCounted(false)
                acquire()
            }
        }
        val wifi = applicationContext.getSystemService(WIFI_SERVICE) as WifiManager
        if (wifiLock?.isHeld != true) {
            @Suppress("DEPRECATION")
            wifiLock = wifi.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "gallery:onedrop").apply {
                setReferenceCounted(false)
                acquire()
            }
        }
    }

    private fun releaseHotLocks() {
        try {
            if (wakeLock?.isHeld == true) wakeLock?.release()
        } catch (_: Exception) {
        }
        try {
            if (wifiLock?.isHeld == true) wifiLock?.release()
        } catch (_: Exception) {
        }
        wakeLock = null
        wifiLock = null
    }

    private fun listenNotification(): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            pendingFlags(),
        )
        return NotificationCompat.Builder(this, CHANNEL_LISTEN)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("OneDrop is listening")
            .setContentText("Nearby phones can find this Gallery over Bluetooth")
            .setOngoing(true)
            .setSilent(true)
            .setContentIntent(open)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }

    companion object {
        private const val TAG = "OneDropListen"
        const val LISTEN_ID = 4071
        const val INCOMING_BASE = 40720
        const val RECEIVED_ID = 4073
        const val CATCH_ID = 4074
        const val CHANNEL_LISTEN = "onedrop_listen"
        const val CHANNEL_INCOMING = "onedrop_incoming"
        const val ACTION_ACCEPT = "one.aml.gallery.DROP_ACCEPT"
        const val ACTION_DECLINE = "one.aml.gallery.DROP_DECLINE"
        const val EXTRA_OFFER = "offerId"

        @Volatile
        var cameraWatch = false
        @Volatile
        private var catchArmed = false
        private var running: OneDropListenService? = null
        private val main = Handler(Looper.getMainLooper())

        fun setCameraWatch(context: Context, on: Boolean) {
            cameraWatch = on
            val svc = running
            if (svc != null) {
                svc.applyForeground()
                svc.syncHotLocks()
                return
            }
            if (on) start(context)
        }

        fun isRunning(): Boolean = running != null

        fun start(context: Context) {
            val intent = Intent(context, OneDropListenService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, OneDropListenService::class.java))
        }

        fun notifyIncoming(context: Context, offerId: String, peerName: String, summary: String) {
            if (offerId.isBlank()) return
            context.applicationContext.let { app ->
                ensureChannels(app)
                val accept = actionPending(app, ACTION_ACCEPT, offerId, 1)
                val decline = actionPending(app, ACTION_DECLINE, offerId, 2)
                val open = PendingIntent.getActivity(
                    app,
                    offerId.hashCode(),
                    Intent(app, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                    pendingFlags(),
                )
                val who = peerName.ifBlank { "Someone" }
                val notification = NotificationCompat.Builder(app, CHANNEL_INCOMING)
                    .setSmallIcon(R.mipmap.ic_launcher)
                    .setContentTitle("$who wants to send")
                    .setContentText(summary.ifBlank { "Photos over OneDrop" })
                    .setPriority(NotificationCompat.PRIORITY_HIGH)
                    .setAutoCancel(true)
                    .setContentIntent(open)
                    .addAction(0, "Decline", decline)
                    .addAction(0, "Accept", accept)
                    .build()
                NotificationManagerCompat.from(app).notify(incomingId(offerId), notification)
            }
        }

        fun cancelIncoming(context: Context, offerId: String) {
            if (offerId.isBlank()) return
            NotificationManagerCompat.from(context.applicationContext)
                .cancel(incomingId(offerId))
        }

        fun notifyReceived(context: Context, message: String) {
            val app = context.applicationContext
            ensureChannels(app)
            val open = PendingIntent.getActivity(
                app,
                RECEIVED_ID,
                Intent(app, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                pendingFlags(),
            )
            val notification = NotificationCompat.Builder(app, CHANNEL_INCOMING)
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentTitle("OneDrop")
                .setContentText(message.ifBlank { "Photos received" })
                .setAutoCancel(true)
                .setContentIntent(open)
                .build()
            NotificationManagerCompat.from(app).notify(RECEIVED_ID, notification)
        }

        fun notifyAirGrabCatch(context: Context, message: String, locked: Boolean = false) {
            val app = context.applicationContext
            NotificationManagerCompat.from(app).cancel(CATCH_ID)
            if (catchArmed) {
                AirGrabGlowOverlay.setLocked(locked)
                return
            }
            catchArmed = true
            val overlayOk = Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
                Settings.canDrawOverlays(app)
            val host = DeviceBridge.activity()
            if (!overlayOk) {
                host?.requestAirGrabOverlay()
            }
            val honor = AirGrabTracker.needsOnScreenPreview()
            val resumed = host?.lifecycle?.currentState?.isAtLeast(Lifecycle.State.RESUMED) == true
            // Honor Recents needs a real PreviewView. Overlay hosts it.
            // Bringing Gallery forward on every UDP packet ANRs MagicOS.
            val bringForward = honor && !resumed && !overlayOk &&
                !AirGrabTracker.cameraBusy()
            if (bringForward) {
                try {
                    app.startActivity(
                        Intent(app, MainActivity::class.java).addFlags(
                            Intent.FLAG_ACTIVITY_NEW_TASK or
                                Intent.FLAG_ACTIVITY_SINGLE_TOP or
                                Intent.FLAG_ACTIVITY_REORDER_TO_FRONT,
                        ),
                    )
                } catch (error: Exception) {
                    Log.w("AirGrab", "bring OneDrop forward for catch camera", error)
                }
                main.postDelayed({ startCatchCamera(app, locked) }, 400)
            } else {
                startCatchCamera(app, locked)
            }
        }

        fun setAirGrabCatchLocked(context: Context, locked: Boolean) {
            if (!catchArmed) return
            AirGrabGlowOverlay.show(context, locked)
        }

        private fun startCatchCamera(app: Context, locked: Boolean = false) {
            // Hands only. Face Landmarker on Snapdragon 888 kills Recents.
            AirGrabTracker.setWantGaze(false)
            AirGrabGlowOverlay.prepareCameraPreview(app)
            AirGrabGlowOverlay.show(app, locked)
            AirGrabTracker.ensureRunning()
        }

        fun hideAirGrabCatch(context: Context) {
            catchArmed = false
            val app = context.applicationContext
            AirGrabTracker.setWantGaze(false)
            AirGrabGlowOverlay.hide(app)
            NotificationManagerCompat.from(app).cancel(CATCH_ID)
        }

        private fun incomingId(offerId: String): Int {
            return INCOMING_BASE + (offerId.hashCode() and 0x0fff)
        }

        private fun actionPending(
            context: Context,
            action: String,
            offerId: String,
            request: Int,
        ): PendingIntent {
            val intent = Intent(context, OneDropActionReceiver::class.java).apply {
                this.action = action
                putExtra(EXTRA_OFFER, offerId)
            }
            return PendingIntent.getBroadcast(
                context,
                offerId.hashCode() * 10 + request,
                intent,
                pendingFlags(),
            )
        }

        private fun pendingFlags(): Int {
            return PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        }

        fun ensureChannels(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val manager = context.getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_LISTEN,
                    "OneDrop listening",
                    NotificationManager.IMPORTANCE_LOW,
                ).apply { setShowBadge(false) },
            )
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_INCOMING,
                    "Incoming OneDrop",
                    NotificationManager.IMPORTANCE_HIGH,
                ),
            )
        }
    }
}

class OneDropActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val offerId = intent.getStringExtra(OneDropListenService.EXTRA_OFFER).orEmpty()
        if (offerId.isBlank()) return
        val accept = intent.action == OneDropListenService.ACTION_ACCEPT
        OneDropListenService.cancelIncoming(context, offerId)
        DeviceBridge.decideDrop(offerId, accept)
    }
}

class OneDropBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action
        if (
            action != Intent.ACTION_BOOT_COMPLETED &&
            action != Intent.ACTION_MY_PACKAGE_REPLACED
        ) {
            return
        }
        if (!DeviceBridge.listenEnabled(context)) return
        OneDropListenService.start(context)
    }
}

