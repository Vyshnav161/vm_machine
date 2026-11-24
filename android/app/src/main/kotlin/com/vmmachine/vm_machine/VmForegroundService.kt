package com.vmmachine.vm_machine

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
import androidx.core.app.NotificationCompat

/**
 * Foreground service that keeps the emulation engine process alive while VMs run
 * (Req 7.1, 7.8). It shows one persistent notification with each VM's name and state,
 * using the same "name: state" text as the Dart `NotificationText.format`.
 *
 * Usage (from EngineSupervisor / the engine channel handler):
 *  - `VmForegroundService.update(context, vmId, name, state)` when a VM starts or changes state.
 *  - `VmForegroundService.remove(context, vmId)` when a VM stops or fails.
 *  - `VmForegroundService.stopAll(context)` to tear everything down.
 * The service stops itself when no VM remains tracked.
 */
class VmForegroundService : Service() {

    private data class Entry(val name: String, val state: String)

    private val entries = LinkedHashMap<String, Entry>()

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        ensureChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_UPDATE -> {
                val id = intent.getStringExtra(EXTRA_VM_ID)
                if (id != null) {
                    entries[id] = Entry(
                        intent.getStringExtra(EXTRA_NAME) ?: id,
                        intent.getStringExtra(EXTRA_STATE) ?: "",
                    )
                }
            }
            ACTION_REMOVE -> intent.getStringExtra(EXTRA_VM_ID)?.let { entries.remove(it) }
            ACTION_STOP_ALL -> entries.clear()
        }
        // startForegroundService() requires startForeground() within a few seconds, even if
        // we are about to stop, so always post the notification first.
        promote(buildNotification())
        if (entries.isEmpty()) {
            stopForegroundCompat()
            stopSelf()
            return START_NOT_STICKY
        }
        // VM processes do not survive service death, so do not ask for a restart.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        stopForegroundCompat()
        super.onDestroy()
    }

    private fun promote(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    @Suppress("DEPRECATION")
    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            stopForeground(true)
        }
    }

    private fun buildNotification(): Notification {
        val lines = entries.values.map { "${it.name}: ${it.state}" }
        val title = when (lines.size) {
            0 -> "VM Machine"
            1 -> lines[0]
            else -> "${lines.size} virtual machines running"
        }
        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle(title)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(contentIntent())
        if (lines.size > 1) {
            val style = NotificationCompat.InboxStyle()
            lines.forEach { style.addLine(it) }
            builder.setStyle(style)
        }
        return builder.build()
    }

    private fun contentIntent(): PendingIntent? {
        val launch = packageManager.getLaunchIntentForPackage(packageName) ?: return null
        launch.flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        return PendingIntent.getActivity(
            this,
            0,
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) == null) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "Running virtual machines",
                    NotificationManager.IMPORTANCE_LOW,
                ).apply { description = "Shows the virtual machines that are currently running" },
            )
        }
    }

    companion object {
        private const val CHANNEL_ID = "vm_running"
        private const val NOTIFICATION_ID = 1001

        private const val ACTION_UPDATE = "com.vmmachine.vm_machine.action.UPDATE"
        private const val ACTION_REMOVE = "com.vmmachine.vm_machine.action.REMOVE"
        private const val ACTION_STOP_ALL = "com.vmmachine.vm_machine.action.STOP_ALL"
        private const val EXTRA_VM_ID = "vmId"
        private const val EXTRA_NAME = "name"
        private const val EXTRA_STATE = "state"

        /** Starts the service if needed and sets the notification entry for [vmId]. */
        fun update(context: Context, vmId: String, name: String, state: String) {
            send(context, Intent(context, VmForegroundService::class.java).apply {
                action = ACTION_UPDATE
                putExtra(EXTRA_VM_ID, vmId)
                putExtra(EXTRA_NAME, name)
                putExtra(EXTRA_STATE, state)
            })
        }

        /** Removes [vmId]; the service stops when no VM remains. */
        fun remove(context: Context, vmId: String) {
            send(context, Intent(context, VmForegroundService::class.java).apply {
                action = ACTION_REMOVE
                putExtra(EXTRA_VM_ID, vmId)
            })
        }

        /** Clears all entries and stops the service. */
        fun stopAll(context: Context) {
            send(context, Intent(context, VmForegroundService::class.java).apply {
                action = ACTION_STOP_ALL
            })
        }

        private fun send(context: Context, intent: Intent) {
            val app = context.applicationContext
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                app.startForegroundService(intent)
            } else {
                app.startService(intent)
            }
        }
    }
}
