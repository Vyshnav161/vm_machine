/*
 * PLATFORM CHANNEL CONTRACT (consumed by the Dart channel implementations, task 9.1)
 *
 * Errors: every method failure is a PlatformException(code, message). Codes used:
 *   bad_args, not_running, engine_failed, qmp_failed, img_failed, no_activity, busy,
 *   display_failed, no_session, not_found, engine_missing.
 *   `engine_missing`: a QEMU library (libqemu-img.so, libqemu-system-*.so) is not in
 *   nativeLibraryDir. `details` is the List<String> of missing library file names. Returned by
 *   start, createDisk, imageInfo and the snapshot methods.
 * All numbers cross the channel as Int/Long (Dart int). Absent/unknown values are null.
 *
 * ---------------------------------------------------------------------------------------
 * MethodChannel "vm/host"
 *   probe()                                -> {arch: "arm64"|"x86_64"|null, totalRam: int?,
 *                                              freeStorage: int?, cores: int?, virt: bool?}
 *   requestNotificationPermission()        -> bool (POST_NOTIFICATIONS granted; always true
 *                                              below Android 13). Shows the system dialog once.
 *   firmwareVersion()                      -> String? (assets/qemu/VERSION; null when not bundled)
 *   extractFirmware {dest}                 -> null (replaces dir `dest` with a copy of assets/qemu)
 *
 * MethodChannel "vm/engine"      (VM id is a String under key "id")
 *   start {id, name, executable, args: List<String>, qmpSocketPath, vncSocketPath, logPath,
 *          vmDir?: String (default: parent of the parent dir of qmpSocketPath),
 *          vcpus?: int, cpuCap?: double (starts the duty-cycle limiter when cpuCap < vcpus)}
 *                                         -> {pid: int}. Returns right after the process is
 *                                            spawned; readiness arrives on "vm/events".
 *   pause {id} | resume {id} | powerdown {id} | reset {id}   -> null (QMP stop / cont /
 *                                            system_powerdown / system_reset)
 *   kill {id}                              -> bool (SIGKILL, true when dead within 5 s)
 *   snapshotCreate  {id, name, disk?}      -> null. Running VM: QMP savevm. Otherwise
 *   snapshotRestore {id, name, disk?}         `qemu-img snapshot` on `disk` (required then);
 *                                             restore replaces the disk only on success.
 *   snapshotDelete  {id, name, disk}       -> null. Only when the VM is not running
 *                                             (error "busy" otherwise).
 *   snapshotList    {disk}                 -> String (raw `qemu-img snapshot -l` output)
 *   stats {id}                             -> {cpuPercent: double?, memBytes: int?}
 *   setCpuLimit {id, vcpus, cap: double}   -> null (cap >= vcpus removes the limit)
 *   createDisk {path, sizeBytes}           -> String (qemu-img output; qcow2, preallocation=off)
 *   imageInfo {path}                       -> String (`qemu-img info --output=json` output)
 *   recoverStale {vmDirs: List<String>}    -> List<String> of VM dirs whose engine died with
 *                                             the app (markers and sockets cleaned up)
 *   isRunning {id}                         -> bool
 *   engineStatus()                         -> {libs: {"libqemu-img.so": bool,
 *                                              "libqemu-system-aarch64.so": bool,
 *                                              "libqemu-system-x86_64.so": bool}}
 *                                             (true = file exists in nativeLibraryDir)
 *
 * EventChannel "vm/events"  (maps; "type" selects the shape; all carry "id" except where noted)
 *   {type: "stateChanged", id, state: "running"|"paused"|"stopping"}
 *        "running" after QMP is ready (engineReady) and after resume.
 *   {type: "qmpEvent", id, event: "SHUTDOWN"|"RESET"|"STOP"|"RESUME", data: Map}
 *   {type: "startFailed", id, step: "qmp", message}      QMP not ready within 30 s; engine killed
 *   {type: "exited",  id, exitCode: int?, signal: int?, signalName: String?, kind: "clean"|"killed",
 *                     message}
 *   {type: "crashed", id, exitCode: int?, signal: int?, signalName: String?, kind: "error"|"signal",
 *                     message}
 *   {type: "copyProgress", dest, copied: int, total: int}  total is -1 when unknown
 *   {type: "mirrorChanged", id: String?, mirroring: bool}
 *   A final "exited"/"crashed" event is always sent once per engine process.
 *
 * EventChannel "vm/hostSignals"   (one map per change)
 *   {thermal: "none"|"light"|"moderate"|"severe"|"critical"|"emergency"|"shutdown"|null,
 *    batteryPercent: int?, charging: bool?, trimMemoryLevel: int? (only on the trim event),
 *    freeStorageBytes: int?, networkConnected: bool?}
 *
 * MethodChannel "vm/files"
 *   pickMedia()                            -> {uri, name, size: int?, supported: bool} or null if
 *                                             cancelled (SAF; persistable read grant taken when
 *                                             supported; result routed via onActivityResult)
 *   hasAllFilesAccess()                    -> bool (MANAGE_EXTERNAL_STORAGE granted; true below API 30)
 *   requestAllFilesAccess()                -> bool (opened the system settings screen)
 *   resolveRealPath {uri}                  -> real readable file path or null (unmappable, no access)
 *   copyMedia {uri, dest}                  -> {ok: true, path, bytes} or
 *                                             {ok: false, error: "no_space"|"cancelled"|"io",
 *                                              required: int?, available: int?, message: String?}
 *                                             Progress is sent as "copyProgress" on vm/events.
 *   cancelCopy {dest}                      -> null
 *   freeSpace {path}                       -> int? (bytes)
 *   removableVolumes()                     -> List<{description, path, freeBytes: int?}>
 *   shareLogs {path}                       -> bool
 *   openUrl {url}                          -> bool (https only)
 *
 * MethodChannel "vm/display"
 *   createTexture {id, socketPath?}        -> int (Flutter texture id; socketPath defaults to the
 *                                             vncSocketPath given to engine.start)
 *   sendPointer {id, x, y, buttons}        -> bool (guest coordinates; RFB button mask)
 *   sendKey {id, keysym, down: bool}       -> bool
 *   screenshot {id, path}                  -> bool
 *   textureSize {id}                       -> {width, height}
 *   disposeTexture {id}                    -> null
 *   mirrorStatus()                         -> {externalConnected: bool, mirroring: bool, id: String?}
 *   mirrorStart {id}                       -> bool (false: no external display or no VNC socket)
 *   mirrorStop()                           -> null
 * ---------------------------------------------------------------------------------------
 */
package com.vmmachine.vm_machine

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

/**
 * Process-wide engine state. QEMU processes outlive the activity (foreground service), so the
 * supervisor and the QMP connections must not be tied to an activity instance.
 */
private object VmRuntime {
    val executor = Executors.newCachedThreadPool { r -> Thread(r, "vm-worker").apply { isDaemon = true } }
    private val main = Handler(Looper.getMainLooper())

    @Volatile var supervisor: EngineSupervisor? = null
    val qmp = ConcurrentHashMap<String, QmpClient>()
    val pids = ConcurrentHashMap<String, Int>()
    val vncSockets = ConcurrentHashMap<String, String>()
    val names = ConcurrentHashMap<String, String>()

    /** Set while a Dart listener is attached to `vm/events`. Always invoked on the main thread. */
    @Volatile var sink: EventChannel.EventSink? = null

    fun emit(event: Map<String, Any?>) {
        main.post { sink?.success(event) }
    }

    fun supervisor(context: android.content.Context): EngineSupervisor =
        supervisor ?: synchronized(this) {
            supervisor ?: EngineSupervisor(context.applicationContext).also { supervisor = it }
        }

    // For stats(): previous CPU sample per VM.
    private class CpuSample(val ticks: Long, val atNanos: Long)
    private val samples = ConcurrentHashMap<String, CpuSample>()

    fun stats(id: String): Map<String, Any?> {
        val pid = pids[id] ?: return mapOf("cpuPercent" to null, "memBytes" to null)
        var cpu: Double? = null
        var mem: Long? = null
        try {
            val stat = File("/proc/$pid/stat").readText()
            val fields = stat.substringAfterLast(')').trim().split(' ')
            // After ')' the fields start at index 3 (state); utime=14, stime=15 (1-based).
            val ticks = fields[11].toLong() + fields[12].toLong()
            val now = System.nanoTime()
            val prev = samples.put(id, CpuSample(ticks, now))
            if (prev != null && now > prev.atNanos) {
                val clkTck = 100.0 // Linux USER_HZ on Android
                val cpuSeconds = (ticks - prev.ticks) / clkTck
                val wall = (now - prev.atNanos) / 1e9
                cpu = (cpuSeconds / wall * 100.0).coerceAtLeast(0.0)
            }
        } catch (_: Exception) {
        }
        try {
            val pages = File("/proc/$pid/statm").readText().trim().split(' ')[1].toLong()
            mem = pages * 4096L
        } catch (_: Exception) {
        }
        return mapOf("cpuPercent" to cpu, "memBytes" to mem)
    }

    fun forget(id: String) {
        pids.remove(id)
        vncSockets.remove(id)
        names.remove(id)
        samples.remove(id)
        qmp.remove(id)?.close()
    }
}

class MainActivity : FlutterActivity() {

    private companion object {
        const val REQ_NOTIFICATIONS = 4102
    }

    private val main = Handler(Looper.getMainLooper())

    private lateinit var storage: StorageAccess
    private var displayChannel: DisplayChannel? = null
    private var mirror: DisplayMirror? = null

    private var pendingPick: MethodChannel.Result? = null
    private var pendingNotification: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        storage = StorageAccess(this)
        val probe = HostProbe(this)
        val firmware = FirmwareAssets(assets)
        val supervisor = VmRuntime.supervisor(this)

        // ---- vm/host ----
        MethodChannel(messenger, "vm/host").setMethodCallHandler { call, result ->
            when (call.method) {
                "probe" -> async(result) { probe.probe() }
                "requestNotificationPermission" -> requestNotificationPermission(result)
                "firmwareVersion" -> async(result) { firmware.version() }
                "extractFirmware" -> {
                    val dest = call.argument<String>("dest")
                    if (dest == null) result.error("bad_args", "dest required", null)
                    else async(result) { firmware.extractTo(File(dest)); null }
                }
                else -> result.notImplemented()
            }
        }

        // ---- vm/events ----
        EventChannel(messenger, "vm/events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                VmRuntime.sink = events
            }

            override fun onCancel(arguments: Any?) {
                VmRuntime.sink = null
            }
        })

        // ---- vm/hostSignals ----
        EventChannel(messenger, "vm/hostSignals").setStreamHandler(HostSignalMonitor(this))

        // ---- vm/engine ----
        MethodChannel(messenger, "vm/engine").setMethodCallHandler { call, result ->
            handleEngine(supervisor, call, result)
        }

        // ---- vm/files ----
        MethodChannel(messenger, "vm/files").setMethodCallHandler { call, result ->
            handleFiles(call, result)
        }

        // ---- vm/display (+ mirror methods) ----
        val display = DisplayChannel(flutterEngine.renderer, { id -> VmRuntime.vncSockets[id] })
        displayChannel = display
        val mirrorImpl = DisplayMirror(
            this,
            socketPathFor = { id -> VmRuntime.vncSockets[id] },
            onStateChanged = { id, on ->
                VmRuntime.emit(mapOf("type" to "mirrorChanged", "id" to id, "mirroring" to on))
            },
        )
        mirror = mirrorImpl
        MethodChannel(messenger, DisplayChannel.CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "mirrorStatus" -> result.success(
                    mapOf(
                        "externalConnected" to mirrorImpl.isExternalDisplayConnected(),
                        "mirroring" to mirrorImpl.isMirroring,
                        "id" to null,
                    ),
                )
                "mirrorStart" -> {
                    val id = call.argument<String>("id")
                    if (id == null) result.error("bad_args", "Missing id", null)
                    else result.success(mirrorImpl.start(id))
                }
                "mirrorStop" -> {
                    mirrorImpl.stop()
                    result.success(null)
                }
                else -> display.onMethodCall(call, result)
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        mirror?.dispose()
        mirror = null
        displayChannel?.disposeAll()
        displayChannel = null
        pendingPick?.success(null)
        pendingPick = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    // ---- Activity results ------------------------------------------------------------------

    @Deprecated("Flutter's activity-result plumbing still uses the legacy callback")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == StorageAccess.PICK_MEDIA_REQUEST) {
            val result = pendingPick
            pendingPick = null
            if (result != null) {
                async(result) { storage.onPickResult(resultCode, data) }
            }
            return
        }
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        if (requestCode == REQ_NOTIFICATIONS) {
            val result = pendingNotification
            pendingNotification = null
            result?.success(grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED)
            return
        }
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(true)
            return
        }
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) {
            result.success(true)
            return
        }
        if (pendingNotification != null) {
            result.error("busy", "A notification permission request is already pending", null)
            return
        }
        pendingNotification = result
        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQ_NOTIFICATIONS)
    }

    // ---- vm/files --------------------------------------------------------------------------

    private fun handleFiles(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pickMedia" -> {
                if (pendingPick != null) {
                    result.error("busy", "A file picker is already open", null)
                    return
                }
                pendingPick = result
                try {
                    @Suppress("DEPRECATION")
                    startActivityForResult(storage.createPickMediaIntent(), StorageAccess.PICK_MEDIA_REQUEST)
                } catch (e: Exception) {
                    pendingPick = null
                    result.error("no_activity", e.message, null)
                }
            }
            "hasAllFilesAccess" -> result.success(storage.hasAllFilesAccess())
            "requestAllFilesAccess" -> result.success(storage.requestAllFilesAccess())
            "resolveRealPath" -> {
                val uri = call.argument<String>("uri") ?: return badArgs(result, "uri")
                async(result) { storage.resolveRealPath(uri) }
            }
            "copyMedia" -> {
                val uri = call.argument<String>("uri") ?: return badArgs(result, "uri")
                val dest = call.argument<String>("dest") ?: return badArgs(result, "dest")
                async(result) {
                    storage.copyMedia(uri, dest) { copied, total ->
                        VmRuntime.emit(
                            mapOf("type" to "copyProgress", "dest" to dest, "copied" to copied, "total" to total),
                        )
                    }
                }
            }
            "cancelCopy" -> {
                val dest = call.argument<String>("dest") ?: return badArgs(result, "dest")
                storage.cancelCopy(dest)
                result.success(null)
            }
            "freeSpace" -> {
                val path = call.argument<String>("path") ?: return badArgs(result, "path")
                async(result) { storage.freeSpace(path) }
            }
            "removableVolumes" -> async(result) { storage.removableVolumes() }
            "shareLogs" -> {
                val path = call.argument<String>("path") ?: return badArgs(result, "path")
                result.success(storage.shareLogs(path))
            }
            "openUrl" -> {
                val url = call.argument<String>("url") ?: return badArgs(result, "url")
                result.success(storage.openUrl(url))
            }
            else -> result.notImplemented()
        }
    }

    // ---- vm/engine -------------------------------------------------------------------------

    private fun handleEngine(sup: EngineSupervisor, call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<String>("id")
        when (call.method) {
            "start" -> startEngine(sup, call, result)
            "createDisk" -> {
                val path = call.argument<String>("path") ?: return badArgs(result, "path")
                val size = call.argument<Number>("sizeBytes")?.toLong() ?: return badArgs(result, "sizeBytes")
                async(result) { imgOutput(sup.createDisk(path, size)) }
            }
            "imageInfo" -> {
                val path = call.argument<String>("path") ?: return badArgs(result, "path")
                async(result) { imgOutput(sup.info(path)) }
            }
            "snapshotList" -> {
                val disk = call.argument<String>("disk") ?: return badArgs(result, "disk")
                async(result) { imgOutput(sup.snapshotList(disk)) }
            }
            "engineStatus" -> async(result) { mapOf("libs" to sup.engineStatus()) }
            "recoverStale" -> {
                val dirs = call.argument<List<String>>("vmDirs") ?: return badArgs(result, "vmDirs")
                async(result) { sup.recoverStale(dirs.map(::File)).map { it.path } }
            }
            else -> {
                if (id == null) return badArgs(result, "id")
                handleEngineForVm(sup, id, call, result)
            }
        }
    }

    private fun handleEngineForVm(
        sup: EngineSupervisor,
        id: String,
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        when (call.method) {
            "isRunning" -> result.success(sup.isRunning(id))
            "pause" -> qmpCall(id, result) { it.stop(); setState(id, "Paused", "paused") }
            "resume" -> qmpCall(id, result) { it.cont(); setState(id, "Running", "running") }
            "powerdown" -> qmpCall(id, result) { it.systemPowerdown(); setState(id, "Stopping", "stopping") }
            "reset" -> qmpCall(id, result) { it.systemReset() }
            "kill" -> async(result) { sup.forceStop(id) }
            "stats" -> async(result) { VmRuntime.stats(id) }
            "setCpuLimit" -> {
                val vcpus = call.argument<Number>("vcpus")?.toInt() ?: return badArgs(result, "vcpus")
                val cap = call.argument<Number>("cap")?.toDouble() ?: return badArgs(result, "cap")
                async(result) { sup.setCpuLimit(id, vcpus, cap); null }
            }
            "snapshotCreate", "snapshotRestore", "snapshotDelete" -> snapshot(sup, id, call, result)
            else -> result.notImplemented()
        }
    }

    private fun snapshot(sup: EngineSupervisor, id: String, call: MethodCall, result: MethodChannel.Result) {
        val name = call.argument<String>("name") ?: return badArgs(result, "name")
        val disk = call.argument<String>("disk")
        val client = VmRuntime.qmp[id]
        val live = client != null && sup.isRunning(id)
        when (call.method) {
            "snapshotCreate" -> if (live) {
                qmpCall(id, result) { it.savevm(name) }
            } else {
                if (disk == null) return badArgs(result, "disk")
                async(result) { imgOk(sup.snapshotCreate(disk, name)) }
            }
            "snapshotRestore" -> if (live) {
                qmpCall(id, result) { it.loadvm(name) }
            } else {
                if (disk == null) return badArgs(result, "disk")
                async(result) { imgOk(sup.snapshotRestore(disk, name)) }
            }
            else -> {
                if (live) {
                    result.error("busy", "Snapshots can only be deleted while the VM is powered off", null)
                    return
                }
                if (disk == null) return badArgs(result, "disk")
                async(result) { imgOk(sup.snapshotDelete(disk, name)) }
            }
        }
    }

    private fun startEngine(sup: EngineSupervisor, call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<String>("id") ?: return badArgs(result, "id")
        val executable = call.argument<String>("executable") ?: return badArgs(result, "executable")
        val args = call.argument<List<String>>("args") ?: return badArgs(result, "args")
        val qmpPath = call.argument<String>("qmpSocketPath") ?: return badArgs(result, "qmpSocketPath")
        val vncPath = call.argument<String>("vncSocketPath") ?: return badArgs(result, "vncSocketPath")
        val logPath = call.argument<String>("logPath") ?: return badArgs(result, "logPath")
        val name = call.argument<String>("name") ?: id
        val vmDir = call.argument<String>("vmDir")?.let(::File)
            ?: File(qmpPath).parentFile?.parentFile
            ?: return badArgs(result, "vmDir")
        val vcpus = call.argument<Number>("vcpus")?.toInt()
        val cpuCap = call.argument<Number>("cpuCap")?.toDouble()
        val appContext = applicationContext

        VmRuntime.executor.execute {
            try {
                vmDir.mkdirs()
                File(qmpPath).parentFile?.mkdirs()
                VmRuntime.names[id] = name
                VmRuntime.vncSockets[id] = vncPath
                val pid = sup.start(
                    vmId = id,
                    binaryName = executable,
                    args = args,
                    vmDir = vmDir,
                    logFile = File(logPath),
                    socketPaths = listOf(File(qmpPath), File(vncPath)),
                    onExit = { reason ->
                        val type = if (reason.kind == "clean" || reason.kind == "killed") "exited" else "crashed"
                        VmRuntime.forget(id)
                        VmForegroundService.remove(appContext, id)
                        VmRuntime.emit(mapOf("type" to type, "id" to id) + reason.toMap())
                    },
                )
                VmRuntime.pids[id] = pid
                VmForegroundService.update(appContext, id, name, "Starting")
                if (vcpus != null && cpuCap != null) sup.setCpuLimit(id, vcpus, cpuCap)
                main.post { result.success(mapOf("pid" to pid)) }
                connectQmp(id, qmpPath, name, appContext, sup)
            } catch (e: Exception) {
                VmRuntime.forget(id)
                VmForegroundService.remove(appContext, id)
                if (e is EngineMissingException) {
                    main.post { result.error("engine_missing", e.message, e.missing) }
                } else {
                    main.post { result.error("engine_failed", e.message, null) }
                }
            }
        }
    }

    /** Runs on a worker thread after spawn: connects QMP and announces readiness. */
    private fun connectQmp(
        id: String,
        qmpPath: String,
        name: String,
        appContext: android.content.Context,
        sup: EngineSupervisor,
    ) {
        val client = QmpClient(
            qmpPath,
            onEvent = { event, data ->
                VmRuntime.emit(mapOf("type" to "qmpEvent", "id" to id, "event" to event, "data" to jsonToMap(data)))
            },
        )
        try {
            client.connect()
            if (!sup.isRunning(id)) {
                client.close()
                return
            }
            VmRuntime.qmp[id] = client
            VmForegroundService.update(appContext, id, name, "Running")
            VmRuntime.emit(mapOf("type" to "stateChanged", "id" to id, "state" to "running"))
        } catch (e: QmpException) {
            client.close()
            if (sup.isRunning(id)) {
                VmRuntime.emit(
                    mapOf("type" to "startFailed", "id" to id, "step" to "qmp", "message" to (e.message ?: "QMP failed")),
                )
                sup.forceStop(id)
            }
        }
    }

    private fun setState(id: String, notificationState: String, eventState: String) {
        VmRuntime.names[id]?.let { VmForegroundService.update(applicationContext, id, it, notificationState) }
        VmRuntime.emit(mapOf("type" to "stateChanged", "id" to id, "state" to eventState))
    }

    // ---- helpers ---------------------------------------------------------------------------

    private fun badArgs(result: MethodChannel.Result, key: String) {
        result.error("bad_args", "Missing argument '$key'", null)
    }

    /** Runs [block] on a worker thread and replies on the main thread. */
    private fun async(result: MethodChannel.Result, block: () -> Any?) {
        VmRuntime.executor.execute {
            try {
                val value = block()
                main.post { result.success(value) }
            } catch (e: EngineMissingException) {
                main.post { result.error("engine_missing", e.message, e.missing) }
            } catch (e: ImgFailure) {
                main.post { result.error("img_failed", e.message, null) }
            } catch (e: Exception) {
                main.post { result.error("engine_failed", e.message, null) }
            }
        }
    }

    private fun qmpCall(id: String, result: MethodChannel.Result, block: (QmpClient) -> Unit) {
        val client = VmRuntime.qmp[id]
        if (client == null) {
            result.error("not_running", "No QMP connection for $id", null)
            return
        }
        VmRuntime.executor.execute {
            try {
                block(client)
                main.post { result.success(null) }
            } catch (e: QmpException) {
                main.post { result.error("qmp_failed", e.message, null) }
            } catch (e: IllegalArgumentException) {
                main.post { result.error("bad_args", e.message, null) }
            }
        }
    }

    /** `qemu-img` helpers: success returns output, failure becomes an `img_failed` error. */
    private fun imgOutput(r: ImgResult): String {
        if (!r.ok) throw ImgFailure(r.output.trim().ifEmpty { "qemu-img exit ${r.exitCode}" })
        return r.output
    }

    private fun imgOk(r: ImgResult): Any? {
        imgOutput(r)
        return null
    }

    private fun jsonToMap(o: JSONObject): Map<String, Any?> {
        val map = HashMap<String, Any?>()
        val keys = o.keys()
        while (keys.hasNext()) {
            val k = keys.next()
            val v = o.opt(k)
            map[k] = if (v == null || v == JSONObject.NULL) null else if (v is JSONObject) jsonToMap(v) else v.toString().let { s ->
                when (v) {
                    is Boolean, is Int, is Long, is Double, is String -> v
                    else -> s
                }
            }
        }
        return map
    }
}

private class ImgFailure(message: String) : Exception(message)
