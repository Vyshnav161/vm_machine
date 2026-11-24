package com.vmmachine.vm_machine

import android.net.LocalSocket
import android.net.LocalSocketAddress
import org.json.JSONObject
import java.io.BufferedReader
import java.io.IOException
import java.io.InputStreamReader
import java.io.OutputStream
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import java.util.concurrent.atomic.AtomicLong

/** Raised when QMP cannot be reached, the handshake fails, or QEMU returns an error. */
class QmpException(message: String, cause: Throwable? = null) : Exception(message, cause)

/** Pure helpers for QMP wire encoding and parsing. */
object QmpProtocol {
    /** Events forwarded to Dart (design: SHUTDOWN, RESET, STOP, RESUME). */
    val forwardedEvents: Set<String> = setOf("SHUTDOWN", "RESET", "STOP", "RESUME")

    fun encodeCommand(command: String, id: Long, arguments: JSONObject? = null): String {
        val obj = JSONObject()
        obj.put("execute", command)
        if (arguments != null) obj.put("arguments", arguments)
        obj.put("id", id)
        return obj.toString() + "\n"
    }

    /** `savevm` and `loadvm` are HMP-only, so they go through `human-monitor-command`. */
    fun encodeHuman(commandLine: String, id: Long): String =
        encodeCommand("human-monitor-command", id, JSONObject().put("command-line", commandLine))

    /** Rejects names that could inject extra HMP syntax. */
    fun isSafeSnapshotName(name: String): Boolean =
        name.isNotEmpty() && name.all { it.isLetterOrDigit() || it == '_' || it == '-' || it == '.' }

    /** Returns the event name when [message] is an event that should be forwarded, otherwise null. */
    fun forwardedEventName(message: JSONObject): String? {
        val name = message.optString("event", "")
        return if (name in forwardedEvents) name else null
    }
}

/**
 * Minimal QMP client over a Unix domain socket.
 *
 * Usage: [connect] (blocks up to 30 s), then call command methods. Events are delivered on the
 * reader thread through [onEvent]; [onClosed] fires once when the connection ends.
 */
class QmpClient(
    private val socketPath: String,
    private val onEvent: (name: String, data: JSONObject) -> Unit = { _, _ -> },
    private val onClosed: () -> Unit = {},
) {
    companion object {
        const val CONNECT_TIMEOUT_MS = 30_000L
        const val COMMAND_TIMEOUT_MS = 10_000L
        /** savevm can take a long time on large guests. */
        const val SNAPSHOT_TIMEOUT_MS = 10 * 60_000L
        private const val RETRY_DELAY_MS = 200L
    }

    private val nextId = AtomicLong(1)
    private val pending = ConcurrentHashMap<Long, CompletableFuture<JSONObject>>()
    private val writeLock = Any()

    @Volatile private var socket: LocalSocket? = null
    @Volatile private var out: OutputStream? = null
    @Volatile private var readerThread: Thread? = null
    @Volatile private var closed = false

    val isConnected: Boolean get() = socket != null && !closed

    /**
     * Connects and completes the QMP capabilities handshake.
     * Retries while the socket does not exist yet (QEMU is still starting).
     * @throws QmpException when not ready within [timeoutMs].
     */
    fun connect(timeoutMs: Long = CONNECT_TIMEOUT_MS) {
        val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMs)
        var lastError: Throwable? = null
        while (System.nanoTime() < deadline) {
            val s = LocalSocket()
            try {
                s.connect(LocalSocketAddress(socketPath, LocalSocketAddress.Namespace.FILESYSTEM))
                val remainingMs = TimeUnit.NANOSECONDS.toMillis(deadline - System.nanoTime())
                s.soTimeout = remainingMs.coerceIn(1L, timeoutMs).toInt()
                val reader = BufferedReader(InputStreamReader(s.inputStream, Charsets.UTF_8))
                val output = s.outputStream

                val greeting = JSONObject(reader.readLine() ?: throw IOException("EOF before greeting"))
                if (!greeting.has("QMP")) throw IOException("Unexpected greeting")

                output.write(encodeLine("qmp_capabilities", 0))
                output.flush()
                // Events may precede the reply; skip them until the return arrives.
                while (true) {
                    val line = reader.readLine() ?: throw IOException("EOF during handshake")
                    val msg = JSONObject(line)
                    if (msg.has("error")) throw QmpException(errorText(msg))
                    if (msg.has("return")) break
                }

                s.soTimeout = 0 // reader thread blocks indefinitely
                socket = s
                out = output
                startReader(reader)
                return
            } catch (e: QmpException) {
                runCatching { s.close() }
                throw e
            } catch (e: Exception) {
                lastError = e
                runCatching { s.close() }
                try {
                    Thread.sleep(RETRY_DELAY_MS)
                } catch (ie: InterruptedException) {
                    Thread.currentThread().interrupt()
                    throw QmpException("Interrupted while connecting to QMP", ie)
                }
            }
        }
        throw QmpException("QMP not ready within ${timeoutMs / 1000} s", lastError)
    }

    private fun encodeLine(command: String, id: Long): ByteArray =
        QmpProtocol.encodeCommand(command, id).toByteArray(Charsets.UTF_8)

    private fun startReader(reader: BufferedReader) {
        val t = Thread({
            try {
                while (true) {
                    val line = reader.readLine() ?: break
                    handleLine(line)
                }
            } catch (_: Exception) {
                // Socket closed or broken; fall through to cleanup.
            } finally {
                shutdown()
            }
        }, "qmp-reader")
        t.isDaemon = true
        readerThread = t
        t.start()
    }

    private fun handleLine(line: String) {
        val msg = try {
            JSONObject(line)
        } catch (_: Exception) {
            return
        }
        val eventName = msg.optString("event", "")
        if (eventName.isNotEmpty()) {
            if (QmpProtocol.forwardedEventName(msg) != null) {
                onEvent(eventName, msg.optJSONObject("data") ?: JSONObject())
            }
            return
        }
        val id = msg.optLong("id", -1)
        pending.remove(id)?.complete(msg)
    }

    private fun errorText(msg: JSONObject): String {
        val err = msg.optJSONObject("error")
        return err?.optString("desc") ?: "QMP error"
    }

    // Command helpers. Each builds the line with its own id and waits for the reply.

    private fun call(
        command: String,
        arguments: JSONObject? = null,
        timeoutMs: Long = COMMAND_TIMEOUT_MS,
        human: String? = null,
    ): JSONObject {
        val output = out ?: throw QmpException("QMP not connected")
        if (closed) throw QmpException("QMP connection closed")
        val id = nextId.getAndIncrement()
        val line = if (human != null) QmpProtocol.encodeHuman(human, id)
        else QmpProtocol.encodeCommand(command, id, arguments)
        val future = CompletableFuture<JSONObject>()
        pending[id] = future
        try {
            synchronized(writeLock) {
                output.write(line.toByteArray(Charsets.UTF_8))
                output.flush()
            }
            val reply = future.get(timeoutMs, TimeUnit.MILLISECONDS)
            if (reply.has("error")) throw QmpException(errorText(reply))
            return reply
        } catch (e: TimeoutException) {
            throw QmpException("QMP command '$command' timed out", e)
        } catch (e: ExecutionException) {
            throw QmpException("QMP command '$command' failed", e)
        } catch (e: IOException) {
            throw QmpException("QMP write failed", e)
        } finally {
            pending.remove(id)
        }
    }

    fun stop() { call("stop") }
    fun cont() { call("cont") }
    fun systemReset() { call("system_reset") }
    fun systemPowerdown() { call("system_powerdown") }

    /** QEMU may close the socket before replying to `quit`; that is treated as success. */
    fun quit() {
        try {
            call("quit")
        } catch (_: QmpException) {
            // Expected when QEMU exits immediately.
        }
    }

    fun savevm(name: String) {
        require(QmpProtocol.isSafeSnapshotName(name)) { "Invalid snapshot name" }
        checkHumanResult(call("human-monitor-command", timeoutMs = SNAPSHOT_TIMEOUT_MS, human = "savevm $name"))
    }

    fun loadvm(name: String) {
        require(QmpProtocol.isSafeSnapshotName(name)) { "Invalid snapshot name" }
        checkHumanResult(call("human-monitor-command", timeoutMs = SNAPSHOT_TIMEOUT_MS, human = "loadvm $name"))
    }

    /** HMP reports failures as plain text in the return value, not as a QMP error. */
    private fun checkHumanResult(reply: JSONObject) {
        val text = reply.optString("return", "").trim()
        if (text.isNotEmpty()) throw QmpException(text)
    }

    /** Returns the `return` object, e.g. `{"status":"running","running":true}`. */
    fun queryStatus(): JSONObject = call("query-status").optJSONObject("return") ?: JSONObject()

    /** Returns the per-vCPU info array as a JSON string-compatible [org.json.JSONArray]. */
    fun queryCpusFast(): org.json.JSONArray =
        call("query-cpus-fast").optJSONArray("return") ?: org.json.JSONArray()

    /** Closes the connection and fails outstanding commands. Safe to call repeatedly. */
    fun close() = shutdown()

    private fun shutdown() {
        val wasClosed: Boolean
        synchronized(this) {
            wasClosed = closed
            closed = true
        }
        if (wasClosed) return
        runCatching { socket?.close() }
        val failure = QmpException("QMP connection closed")
        pending.values.forEach { it.completeExceptionally(failure) }
        pending.clear()
        readerThread?.interrupt()
        onClosed()
    }
}
