package com.vmmachine.vm_machine

import android.app.ActivityManager
import android.content.Context
import android.os.Build
import android.os.StatFs
import java.io.File

/**
 * Reads host capabilities for the `vm/host` channel `probe()` call.
 *
 * Every value that cannot be read is reported as null so Dart marks it `Unknown`.
 * Result keys: arch ("arm64" | "x86_64" | null), totalRam (bytes), freeStorage (bytes),
 * cores, virt (true | false | null).
 */
class HostProbe(private val context: Context) {

    fun probe(): Map<String, Any?> = mapOf(
        "arch" to safe { readArch() },
        "totalRam" to safe { readTotalRam() },
        "freeStorage" to safe { readFreeStorage() },
        "cores" to safe { readCores() },
        "virt" to safe { readVirtualization() },
    )

    private fun readArch(): String? {
        // Prefer the primary ABI; it reflects the architecture the device runs natively.
        val abis = Build.SUPPORTED_ABIS ?: return null
        for (abi in abis) {
            when (abi) {
                "arm64-v8a" -> return "arm64"
                "x86_64" -> return "x86_64"
            }
        }
        return null
    }

    private fun readTotalRam(): Long? {
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
            ?: return null
        val info = ActivityManager.MemoryInfo()
        am.getMemoryInfo(info)
        return if (info.totalMem > 0) info.totalMem else null
    }

    private fun readFreeStorage(): Long? {
        val dir = context.filesDir ?: return null
        val bytes = StatFs(dir.absolutePath).availableBytes
        return if (bytes >= 0) bytes else null
    }

    private fun readCores(): Int? {
        val n = Runtime.getRuntime().availableProcessors()
        return if (n > 0) n else null
    }

    /**
     * True when hardware virtualization is usable: `/dev/kvm` is readable and writable,
     * or the AVF system feature is present. False when both are definitely absent.
     * Null when it cannot be determined.
     */
    private fun readVirtualization(): Boolean? {
        val kvm = File("/dev/kvm")
        if (kvm.exists() && kvm.canRead() && kvm.canWrite()) return true

        val avf = context.packageManager
            .hasSystemFeature("android.software.virtualization_framework")
        if (avf) return true

        // /dev/kvm exists but is not accessible: usable state is false, not unknown.
        return false
    }

    private inline fun <T> safe(block: () -> T?): T? =
        try {
            block()
        } catch (_: Throwable) {
            null
        }
}
