package com.vmmachine.vm_machine

import android.content.BroadcastReceiver
import android.content.ComponentCallbacks2
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.res.Configuration
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.StatFs
import io.flutter.plugin.common.EventChannel

/**
 * Streams host signals on the `vm/hostSignals` EventChannel.
 *
 * Each event is a map with keys: thermal (ThermalStatus name or null), batteryPercent,
 * charging, trimMemoryLevel (only on the event caused by onTrimMemory, null otherwise so
 * the policy does not act on a stale level), freeStorageBytes, networkConnected.
 * Unknown values are null. Register with `EventChannel("vm/hostSignals").setStreamHandler(monitor)`.
 */
class HostSignalMonitor(
    context: Context,
    private val storagePollIntervalMs: Long = 30_000L,
) : EventChannel.StreamHandler {

    private val appContext: Context = context.applicationContext
    private val main = Handler(Looper.getMainLooper())

    private var sink: EventChannel.EventSink? = null

    private var thermal: String? = null
    private var batteryPercent: Int? = null
    private var charging: Boolean? = null
    private var freeStorageBytes: Long? = null
    private var networkConnected: Boolean? = null

    private var thermalListener: PowerManager.OnThermalStatusChangedListener? = null
    private var batteryReceiver: BroadcastReceiver? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private val trimCallbacks = object : ComponentCallbacks2 {
        override fun onTrimMemory(level: Int) {
            emit(trimLevel = level)
        }

        override fun onConfigurationChanged(newConfig: Configuration) {}

        @Deprecated("Required by ComponentCallbacks")
        override fun onLowMemory() {
            emit(trimLevel = ComponentCallbacks2.TRIM_MEMORY_COMPLETE)
        }
    }
    private val storagePoll = object : Runnable {
        override fun run() {
            freeStorageBytes = readFreeStorage()
            emit()
            main.postDelayed(this, storagePollIntervalMs)
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        startListening()
    }

    override fun onCancel(arguments: Any?) {
        stopListening()
        sink = null
    }

    private fun startListening() {
        stopListening()
        registerThermal()
        registerBattery()
        registerNetwork()
        appContext.registerComponentCallbacks(trimCallbacks)
        main.post(storagePoll)
    }

    private fun stopListening() {
        main.removeCallbacks(storagePoll)
        try {
            appContext.unregisterComponentCallbacks(trimCallbacks)
        } catch (_: Throwable) {
        }
        thermalListener?.let { l ->
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                (appContext.getSystemService(Context.POWER_SERVICE) as? PowerManager)
                    ?.removeThermalStatusListener(l)
            }
        }
        thermalListener = null
        batteryReceiver?.let { r ->
            try {
                appContext.unregisterReceiver(r)
            } catch (_: Throwable) {
            }
        }
        batteryReceiver = null
        networkCallback?.let { cb ->
            try {
                (appContext.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager)
                    ?.unregisterNetworkCallback(cb)
            } catch (_: Throwable) {
            }
        }
        networkCallback = null
    }

    private fun registerThermal() {
        // Thermal status listener needs API 29; older devices report null (unknown).
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        try {
            val pm = appContext.getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return
            val listener = PowerManager.OnThermalStatusChangedListener { status ->
                thermal = thermalName(status)
                emit()
            }
            thermalListener = listener
            pm.addThermalStatusListener(listener)
            thermal = thermalName(pm.currentThermalStatus)
        } catch (_: Throwable) {
        }
    }

    private fun registerBattery() {
        try {
            val receiver = object : BroadcastReceiver() {
                override fun onReceive(context: Context?, intent: Intent?) {
                    if (intent != null) {
                        applyBattery(intent)
                        emit()
                    }
                }
            }
            batteryReceiver = receiver
            // ACTION_BATTERY_CHANGED is sticky: the return value is the current state.
            val sticky = appContext.registerReceiver(receiver, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            if (sticky != null) applyBattery(sticky)
        } catch (_: Throwable) {
        }
    }

    private fun applyBattery(intent: Intent) {
        val level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
        val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
        batteryPercent = if (level >= 0 && scale > 0) (level * 100) / scale else null
        val status = intent.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
        charging = when (status) {
            BatteryManager.BATTERY_STATUS_CHARGING, BatteryManager.BATTERY_STATUS_FULL -> true
            BatteryManager.BATTERY_STATUS_DISCHARGING, BatteryManager.BATTERY_STATUS_NOT_CHARGING -> false
            else -> null
        }
    }

    private fun registerNetwork() {
        try {
            val cm = appContext.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
                ?: return
            networkConnected = hasInternet(cm)
            val cb = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    networkConnected = true
                    postEmit()
                }

                override fun onLost(network: Network) {
                    networkConnected = hasInternet(cm)
                    postEmit()
                }
            }
            networkCallback = cb
            cm.registerDefaultNetworkCallback(cb)
        } catch (_: Throwable) {
        }
    }

    private fun hasInternet(cm: ConnectivityManager): Boolean? {
        return try {
            val caps = cm.getNetworkCapabilities(cm.activeNetwork)
            caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true
        } catch (_: Throwable) {
            null
        }
    }

    private fun readFreeStorage(): Long? = try {
        val dir = appContext.filesDir
        if (dir == null) null else StatFs(dir.absolutePath).availableBytes.takeIf { it >= 0 }
    } catch (_: Throwable) {
        null
    }

    private fun thermalName(status: Int): String? = when (status) {
        PowerManager.THERMAL_STATUS_NONE -> "none"
        PowerManager.THERMAL_STATUS_LIGHT -> "light"
        PowerManager.THERMAL_STATUS_MODERATE -> "moderate"
        PowerManager.THERMAL_STATUS_SEVERE -> "severe"
        PowerManager.THERMAL_STATUS_CRITICAL -> "critical"
        PowerManager.THERMAL_STATUS_EMERGENCY -> "emergency"
        PowerManager.THERMAL_STATUS_SHUTDOWN -> "shutdown"
        else -> null
    }

    /** Network callbacks run on a binder thread; hop to main before touching the sink. */
    private fun postEmit() {
        main.post { emit() }
    }

    private fun emit(trimLevel: Int? = null) {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            main.post { emit(trimLevel) }
            return
        }
        val s = sink ?: return
        s.success(
            mapOf(
                "thermal" to thermal,
                "batteryPercent" to batteryPercent,
                "charging" to charging,
                "trimMemoryLevel" to trimLevel,
                "freeStorageBytes" to freeStorageBytes,
                "networkConnected" to networkConnected,
            )
        )
    }
}
