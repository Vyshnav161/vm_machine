package com.vmmachine.vm_machine

import android.content.Context
import android.os.Process as AndroidProcess
import java.io.File
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

/** Why a QEMU process ended. */
data class ExitReason(
    val exitCode: Int?,
    val signal: Int?,
    val signalName: String?,
    /** `clean`, `error`, `signal` or `killed` (force stop). */
    val kind: String,
    val message: String,
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "exitCode" to exitCode,
        "signal" to signal,
        "signalName" to signalName,
        "kind" to kind,
        "message" to message,
    )
}

/** Result of running a `qemu-img` command. */
data class ImgResult(val exitCode: Int, val output: String) {
    val ok: Boolean get() = exitCode == 0
}

/** One or more QEMU `lib*.so` files are absent from `nativeLibraryDir`. */
class EngineMissingException(val missing: List<String>) :
    IOException("QEMU engine not installed: missing ${missing.joinToString(", ")}")

/**
 * Spawns and supervises QEMU child processes (design D1, D2) and runs `qemu-img`.
 *
 * Binaries are `lib*.so` files in `ApplicationInfo.nativeLibraryDir`. Each running VM has a
 * `engine.pid` marker in its VM directory so a later app launch can detect VMs whose engine
 * died with the app ([recoverStale]).
 */
class EngineSupervisor(
    context: Context,
    private val nativeLibDir: File = File(context.applicationInfo.nativeLibraryDir),
    private val qemuImgName: String = "libqemu-img.so",
) {
    private class Running(
        val process: Process,
        val pid: Int,
        val socketPaths: List<File>,
        val pidFile: File,
        @Volatile var forceKilled: Boolean = false,
        @Volatile var limiter: Thread? = null,
    )

    private val running = ConcurrentHashMap<String, Running>()

    // ---- Spawn -------------------------------------------------------------------------

    /**
     * Starts QEMU for [vmId]. [binaryName] is the `lib*.so` name (e.g. `libqemu-system-aarch64.so`),
     * [args] the argv after the binary. stdout/stderr (including `-serial stdio` output) are
     * appended to [logFile]. [onExit] runs once on a background thread when the process ends.
     * Returns the pid.
     */
    fun start(
        vmId: String,
        binaryName: String,
        args: List<String>,
        vmDir: File,
        logFile: File,
        socketPaths: List<File> = emptyList(),
        onExit: (ExitReason) -> Unit,
    ): Int {
        check(!running.containsKey(vmId)) { "VM $vmId already has a running engine" }
        val binary = File(nativeLibDir, binaryName)
        if (!binary.exists()) throw EngineMissingException(listOf(binaryName))
        if (!binary.canExecute()) throw IOException("Engine binary not executable: ${binary.path}")

        socketPaths.forEach { it.delete() }
        logFile.parentFile?.mkdirs()
        val builder = ProcessBuilder(listOf(binary.path) + args)
            .directory(vmDir)
            .redirectErrorStream(true)
            .redirectOutput(ProcessBuilder.Redirect.appendTo(logFile))
        val process = builder.start()
        val pid = pidOf(process)
        val pidFile = File(vmDir, PID_FILE)
        pidFile.writeText(pid.toString())
        val entry = Running(process, pid, socketPaths, pidFile)
        running[vmId] = entry

        Thread({
            val code = try {
                process.waitFor()
            } catch (_: InterruptedException) {
                -1
            }
            entry.limiter?.interrupt()
            running.remove(vmId)
            cleanupArtifacts(pidFile, socketPaths)
            onExit(mapExit(code, entry.forceKilled))
        }, "engine-wait-$vmId").apply { isDaemon = true }.start()
        return pid
    }

    /** Library file name -> present in [nativeLibDir], for `engineStatus`. */
    fun engineStatus(): Map<String, Boolean> =
        listOf(qemuImgName, "libqemu-system-aarch64.so", "libqemu-system-x86_64.so")
            .associateWith { File(nativeLibDir, it).exists() }

    fun isRunning(vmId: String): Boolean = running[vmId]?.process?.isAlive == true

    // ---- Force stop --------------------------------------------------------------------

    /** Sends SIGKILL and returns true if the process is dead within [timeoutMs] (default 5 s). */
    fun forceStop(vmId: String, timeoutMs: Long = 5_000L): Boolean {
        val entry = running[vmId] ?: return true
        entry.forceKilled = true
        entry.limiter?.interrupt()
        AndroidProcess.sendSignal(entry.pid, SIGKILL)
        return try {
            entry.process.waitFor(timeoutMs, TimeUnit.MILLISECONDS) && !pidAlive(entry.pid)
        } catch (_: InterruptedException) {
            false
        }
    }

    // ---- Exit mapping ------------------------------------------------------------------

    companion object {
        const val PID_FILE = "engine.pid"
        private const val SIGKILL = 9
        private const val SIGSTOP = 19
        private const val SIGCONT = 18

        private val SIGNAL_NAMES = mapOf(
            1 to "SIGHUP", 2 to "SIGINT", 3 to "SIGQUIT", 4 to "SIGILL", 6 to "SIGABRT",
            7 to "SIGBUS", 8 to "SIGFPE", 9 to "SIGKILL", 11 to "SIGSEGV", 13 to "SIGPIPE",
            14 to "SIGALRM", 15 to "SIGTERM",
        )

        /**
         * Maps a `Process.waitFor()` value to a reason. The JVM reports death by signal N as
         * 128 + N, so values above 128 are treated as signals.
         */
        fun mapExit(code: Int, forceKilled: Boolean = false): ExitReason {
            if (forceKilled) {
                return ExitReason(null, SIGKILL, "SIGKILL", "killed", "Engine was force stopped")
            }
            if (code == 0) return ExitReason(0, null, null, "clean", "Engine exited normally")
            if (code in 129..192) {
                val sig = code - 128
                val name = SIGNAL_NAMES[sig] ?: "signal $sig"
                return ExitReason(null, sig, name, "signal", "Engine was terminated by $name")
            }
            return ExitReason(code, null, null, "error", "Engine exited with code $code")
        }

        private fun pidAlive(pid: Int): Boolean = File("/proc/$pid").exists() && !isZombie(pid)

        private fun isZombie(pid: Int): Boolean = try {
            File("/proc/$pid/stat").readText().substringAfterLast(')').trim().startsWith("Z")
        } catch (_: IOException) {
            true
        }

        private fun pidOf(process: Process): Int {
            // java.lang.Process.pid() is not in the Android SDK stubs, so read ProcessImpl.pid.
            val field = process.javaClass.getDeclaredField("pid")
            field.isAccessible = true
            return field.getInt(process)
        }

        /** CPU time slices for a duty cycle: run for [cap]/[vcpus] of each [periodMs]. */
        fun dutyRunMs(vcpus: Int, cap: Double, periodMs: Long): Long {
            if (vcpus <= 0 || cap >= vcpus) return periodMs
            val fraction = (cap / vcpus).coerceIn(0.05, 1.0)
            return (periodMs * fraction).toLong().coerceAtLeast(1L)
        }
    }

    private fun cleanupArtifacts(pidFile: File, sockets: List<File>) {
        pidFile.delete()
        sockets.forEach { it.delete() }
    }

    // ---- Duty-cycle CPU limiter (Req 7.7) ----------------------------------------------

    /**
     * Limits the engine to [cap] of [vcpus] cores by alternating SIGSTOP/SIGCONT each
     * [periodMs]. Pass `cap >= vcpus` (or call [clearCpuLimit]) to remove the limit.
     */
    fun setCpuLimit(vmId: String, vcpus: Int, cap: Double, periodMs: Long = 100L) {
        val entry = running[vmId] ?: return
        clearCpuLimit(vmId)
        val runMs = dutyRunMs(vcpus, cap, periodMs)
        if (runMs >= periodMs) return
        val thread = Thread({
            try {
                while (entry.process.isAlive) {
                    Thread.sleep(runMs)
                    AndroidProcess.sendSignal(entry.pid, SIGSTOP)
                    Thread.sleep(periodMs - runMs)
                    AndroidProcess.sendSignal(entry.pid, SIGCONT)
                }
            } catch (_: InterruptedException) {
                // fall through to resume
            } finally {
                if (entry.process.isAlive) AndroidProcess.sendSignal(entry.pid, SIGCONT)
            }
        }, "engine-limiter-$vmId")
        thread.isDaemon = true
        entry.limiter = thread
        thread.start()
    }

    fun clearCpuLimit(vmId: String) {
        val entry = running[vmId] ?: return
        entry.limiter?.interrupt()
        entry.limiter?.join(500)
        entry.limiter = null
    }

    // ---- Stale state after app termination (Req 5.8) -----------------------------------

    /**
     * For each VM directory with an `engine.pid` marker whose process is not alive, removes
     * the marker and stale sockets and returns the VM directory. Dart marks those VMs `Error`.
     * An orphaned live engine is killed first. Disk images are never touched.
     */
    fun recoverStale(vmDirs: List<File>, socketNames: List<String> = listOf("qmp.sock", "vnc.sock")): List<File> {
        val stale = mutableListOf<File>()
        for (dir in vmDirs) {
            val marker = File(dir, PID_FILE)
            if (!marker.exists()) continue
            val pid = marker.readText().trim().toIntOrNull()
            if (pid != null && running.values.any { it.pid == pid }) continue // ours, healthy
            // Orphaned engine from a previous app process: kill it so the VM can restart.
            if (pid != null && pidAlive(pid)) AndroidProcess.sendSignal(pid, SIGKILL)
            marker.delete()
            socketNames.forEach { File(dir, it).delete() }
            stale.add(dir)
        }
        return stale
    }

    // ---- qemu-img ----------------------------------------------------------------------

    private fun qemuImg(vararg args: String, timeoutSec: Long = 600): ImgResult {
        val bin = File(nativeLibDir, qemuImgName)
        if (!bin.exists()) throw EngineMissingException(listOf(qemuImgName))
        if (!bin.canExecute()) return ImgResult(127, "qemu-img not executable: ${bin.path}")
        val p = ProcessBuilder(listOf(bin.path) + args).redirectErrorStream(true).start()
        val out = StringBuilder()
        val reader = Thread { out.append(p.inputStream.bufferedReader().readText()) }
        reader.start()
        if (!p.waitFor(timeoutSec, TimeUnit.SECONDS)) {
            p.destroyForcibly()
            reader.join(1000)
            return ImgResult(124, out.toString() + "\nqemu-img timed out")
        }
        reader.join(2000)
        return ImgResult(p.exitValue(), out.toString())
    }

    /** Creates a qcow2 disk without preallocation (Req 8.1). */
    fun createDisk(path: String, sizeBytes: Long): ImgResult =
        qemuImg("create", "-f", "qcow2", "-o", "preallocation=off", path, sizeBytes.toString())

    /** `qemu-img info --output=json`. */
    fun info(path: String): ImgResult = qemuImg("info", "--output=json", path)

    fun snapshotCreate(disk: String, tag: String): ImgResult = qemuImg("snapshot", "-c", tag, disk)

    fun snapshotList(disk: String): ImgResult = qemuImg("snapshot", "-l", disk)

    fun snapshotDelete(disk: String, tag: String): ImgResult = qemuImg("snapshot", "-d", tag, disk)

    /**
     * Restores [tag] against a temporary copy, and replaces the live disk only on success
     * (Req 9.5). On failure the live disk is untouched and the copy is removed.
     */
    fun snapshotRestore(disk: String, tag: String): ImgResult {
        val live = File(disk)
        val temp = File(live.parentFile, live.name + ".restore.tmp")
        temp.delete()
        return try {
            live.copyTo(temp, overwrite = true)
            val result = qemuImg("snapshot", "-a", tag, temp.path)
            if (!result.ok) {
                temp.delete()
                result
            } else if (!temp.renameTo(live)) {
                temp.delete()
                ImgResult(1, "Could not replace disk with restored copy")
            } else {
                result
            }
        } catch (e: IOException) {
            temp.delete()
            ImgResult(1, "Restore failed: ${e.message}")
        }
    }
}
