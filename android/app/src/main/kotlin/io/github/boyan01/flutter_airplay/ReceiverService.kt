// SPDX-License-Identifier: GPL-3.0-only
package io.github.boyan01.flutter_airplay

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** Keeps reception and its Flutter texture registry alive independently of Activity. */
class ReceiverService : Service() {
    companion object {
        private const val CHANNEL = "airplay_receiver"
        private const val CONNECTION_CHANNEL = "airplay_connection"
        private const val NOTIFICATION = 1
        private const val CONNECTION_NOTIFICATION = 2
        private const val STOP = "io.github.boyan01.flutter_airplay.STOP_RECEIVER"
        private var retainedEngine: FlutterEngine? = null
        private var retainedBridge: ReceiverBridge? = null

        // A single engine also preserves the live SurfaceTexture when Activity is
        // finished or recreated. It is retained until the application process exits.
        fun engine(context: Context): FlutterEngine {
            retainedEngine?.let { return it }
            return FlutterEngine(context.applicationContext).also {
                retainedEngine = it
                retainedBridge = ReceiverBridge(context.applicationContext, it)
            }
        }

        internal fun bridge(context: Context): ReceiverBridge {
            engine(context)
            return checkNotNull(retainedBridge)
        }

        internal fun start(context: Context) {
            context.startForegroundService(Intent(context, ReceiverService::class.java))
        }
    }

    private val receiver get() = bridge(this)
    private val notifications get() = getSystemService(NotificationManager::class.java)
    private var promoted = false
    private var lastStartId = 0
    private var lastText: String? = null
    private var connectionShown = false

    override fun onCreate() {
        super.onCreate()
        notifications.createNotificationChannel(NotificationChannel(
            CHANNEL, getString(R.string.receiver_channel), NotificationManager.IMPORTANCE_LOW))
        notifications.createNotificationChannel(NotificationChannel(
            CONNECTION_CHANNEL, getString(R.string.connection_channel), NotificationManager.IMPORTANCE_HIGH))
        receiver.service = this
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        lastStartId = startId
        if (intent?.action == STOP) {
            receiver.stop(object : MethodChannel.Result {
                override fun success(value: Any?) { finishReception() }
                override fun error(code: String, message: String?, details: Any?) {}
                override fun notImplemented() {}
            })
            return START_NOT_STICKY
        }
        val notification = notification(getString(R.string.receiver_waiting))
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIFICATION, notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE or
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        } else {
            startForeground(NOTIFICATION, notification)
        }
        promoted = true
        receiver.startPending()
        if (!receiver.isActive) finishReception()
        return START_NOT_STICKY
    }

    private fun openIntent() = Intent(this, MainActivity::class.java).apply {
        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
    }

    private fun openAction() = PendingIntent.getActivity(this, 0, openIntent(),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

    private fun notification(text: String, connection: Boolean = false): Notification {
        val open = openAction()
        val stop = PendingIntent.getService(this, 1,
            Intent(this, ReceiverService::class.java).setAction(STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        return Notification.Builder(this, if (connection) CONNECTION_CHANNEL else CHANNEL)
            .setSmallIcon(R.drawable.ic_airplay_notification)
            .setContentTitle(getString(R.string.app_name))
            .setContentText(text)
            .setContentIntent(open)
            .setCategory(if (connection) Notification.CATEGORY_EVENT else Notification.CATEGORY_SERVICE)
            .setOngoing(!connection)
            .setAutoCancel(connection)
            .setOnlyAlertOnce(!connection)
            .addAction(Notification.Action.Builder(null, getString(R.string.receiver_open), open).build())
            .addAction(Notification.Action.Builder(null, getString(R.string.receiver_stop), stop).build())
            .build()
    }

    internal fun update(data: Map<String, Any>, foreground: Boolean) {
        if (!promoted) return
        if (!receiver.isActive) { finishReception(); return }
        val status = data["status"]
        val client = (data["clientName"] as? String).orEmpty().ifBlank { "iPhone" }
        val streaming = status == "streaming"
        val text = if (streaming) getString(R.string.receiver_connected, client)
            else if (status == "error") getString(R.string.receiver_failed)
            else getString(R.string.receiver_waiting)
        if (text != lastText) {
            lastText = text
            notifications.notify(NOTIFICATION, notification(text))
        }
        if (status == "waiting" || status == "stopped" || status == "starting") {
            connectionShown = false
            notifications.cancel(CONNECTION_NOTIFICATION)
        }
        if (streaming && !connectionShown) {
            connectionShown = true
            if (!foreground) {
                notifications.notify(CONNECTION_NOTIFICATION, notification(text, connection = true))
                // A foreground service alone does not grant background Activity launches.
                if (Build.VERSION.SDK_INT < 29 || Settings.canDrawOverlays(this)) {
                    try { startActivity(openIntent()) }
                    catch (_: Exception) { /* The connection notification remains available. */ }
                }
            }
        }
        if (foreground) notifications.cancel(CONNECTION_NOTIFICATION)
    }

    private fun finishReception() {
        promoted = false
        lastText = null
        connectionShown = false
        notifications.cancel(CONNECTION_NOTIFICATION)
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelfResult(lastStartId)
    }

    override fun onDestroy() {
        receiver.onServiceDestroyed(this)
        notifications.cancel(CONNECTION_NOTIFICATION)
        super.onDestroy()
    }
}
