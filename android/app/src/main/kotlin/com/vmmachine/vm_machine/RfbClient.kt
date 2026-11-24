package com.vmmachine.vm_machine

import android.graphics.Bitmap
import android.graphics.Rect
import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.os.Handler
import android.os.Looper
import android.view.Surface
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.io.DataInputStream
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.OutputStream
import java.util.concurrent.ConcurrentHashMap

/** Raised when the VNC server cannot be reached or speaks an unsupported protocol. */
class RfbException(message: String, cause: Throwable? = null) : Exception(message, cause)

/** Pure helpers for RFB wire encoding. */
object RfbProtocol {
    const val ENC_RAW = 0
    const val ENC_COPY_RECT = 1
    const val ENC_DESKTOP_SIZE = -223

    /** Parses "RFB 003.008\n" into the minor version, or null when malformed. */
    fun parseServerMinor(banner: ByteArray): Int? {
        val s = String(banner, Charsets.US_ASCII)
        if (!Regex("RFB 003\\.\\d{3}\n").matches(s)) return null
        return s.substring(8, 11).toIntOrNull()
    }

    /** Version the client answers with: 3.3, 3.7 or 3.8. */
    fun clientMinor(serverMinor: Int): Int = when {
        serverMinor >= 8 -> 8
        serverMinor == 7 -> 7
        else -> 3
    }

    fun versionString(minor: Int): ByteArray = "RFB 003.%03d\n".format(minor).toByteArray(Charsets.US_ASCII)

    /** SetPixelFormat: 32 bpp, depth 24, little endian, true colour, R<<16 G<<8 B. */
    fun setPixelFormat(): ByteArray = byteArrayOf(
        0, 0, 0, 0,
        32, 24, 0, 1,
        0, 255.toByte(), 0, 255.toByte(), 0, 255.toByte(),
        16, 8, 0,
        0, 0, 0,
    )

    fun setEncodings(encodings: IntArray): ByteArray {
        val out = ByteArray(4 + encodings.size * 4)
        out[0] = 2
        out[2] = (encodings.size shr 8).toByte()
        out[3] = encodings.size.toByte()
        encodings.forEachIndexed { i, e -> putInt(out, 4 + i * 4, e) }
        return out
    }

    fun updateRequest(incremental: Boolean, x: Int, y: Int, w: Int, h: Int): ByteArray {
        val out = ByteArray(10)
        out[0] = 3
        out[1] = if (incremental) 1 else 0
        putShort(out, 2, x); putShort(out, 4, y); putShort(out, 6, w); putShort(out, 8, h)
        return out
    }

    fun keyEvent(keysym: Int, down: Boolean): ByteArray {
        val out = ByteArray(8)
        out[0] = 4
        out[1] = if (down) 1 else 0
        putInt(out, 4, keysym)
        return out
    }

    /** [buttons] is the RFB button mask (bit 0 left, 1 middle, 2 right, 3 wheel up, 4 wheel down). */
    fun pointerEvent(buttons: Int, x: Int, y: Int): ByteArray {
        val out = ByteArray(6)
        out[0] = 5
        out[1] = buttons.toByte()
        putShort(out, 2, x); putShort(out, 4, y)
        return out
    }

    fun clamp(v: Int, size: Int): Int = v.coerceIn(0, maxOf(size - 1, 0))

    /** Converts little-endian B,G,R,X bytes at [src] into opaque ARGB ints. */
    fun bgrxToArgb(src: ByteArray, count: Int, dst: IntArray, dstOffset: Int) {
        for (i in 0 until count) {
            val b = src[i * 4].toInt() and 0xFF
            val g = src[i * 4 + 1].toInt() and 0xFF
            val r = src[i * 4 + 2].toInt() and 0xFF
            dst[dstOffset + i] = (0xFF shl 24) or (r shl 16) or (g shl 8) or b
        }
    }

    private fun putShort(a: ByteArray, o: Int, v: Int) {
        a[o] = (v shr 8).toByte(); a[o + 1] = v.toByte()
    }

    private fun putInt(a: ByteArray, o: Int, v: Int) {
        a[o] = (v shr 24).toByte(); a[o + 1] = (v shr 16).toByte()
        a[o + 2] = (v shr 8).toByte(); a[o + 3] = v.toByte()
    }
}

/**
 * RFB client for QEMU's `-vnc unix:` socket. Decodes Raw, CopyRect and DesktopSize updates into a
 * framebuffer that is drawn on [surface] (a Flutter SurfaceTexture surface).
 *
 * A desktop resize (Req 6.5) only reallocates the framebuffer; the VM is never restarted.
 */
class RfbClient(
    private val socketPath: String,
    private val surface: Surface,
    private val onResize: (width: Int, height: Int) -> Unit = { _, _ -> },
    private val onClosed: () -> Unit = {},
) {
    companion object {
        const val CONNECT_TIMEOUT_MS = 30_000L
        private const val RETRY_MS = 250L
    }

    private val frameLock = Any()
    private val writeLock = Any()
    private var socket: LocalSocket? = null
    private var output: OutputStream? = null
    private var reader: Thread? = null

    @Volatile private var closed = false
    private var pixels = IntArray(0)
    private var bitmap: Bitmap? = null

    @Volatile var width = 0
        private set

    @Volatile var height = 0
        private set

    /** Connects and handshakes, retrying until the socket exists (QEMU creates it at startup). */
    fun connect(timeoutMs: Long = CONNECT_TIMEOUT_MS) {
        val deadline = System.currentTimeMillis() + timeoutMs
        var last: Exception? = null
        while (System.currentTimeMillis() < deadline && !closed) {
            val s = LocalSocket()
            try {
                s.connect(LocalSocketAddress(socketPath, LocalSocketAddress.Namespace.FILESYSTEM))
                socket = s
                handshake(s)
                startReader(s)
                return
            } catch (e: Exception) {
                last = e
                try { s.close() } catch (_: IOException) {}
                socket = null
                try { Thread.sleep(RETRY_MS) } catch (_: InterruptedException) { break }
            }
        }
        throw RfbException("Could not connect to VNC at $socketPath", last)
    }

    private lateinit var input: DataInputStream

    private fun handshake(s: LocalSocket) {
        input = DataInputStream(s.inputStream.buffered())
        output = s.outputStream
        val banner = ByteArray(12).also { input.readFully(it) }
        val serverMinor = RfbProtocol.parseServerMinor(banner) ?: throw RfbException("Bad RFB banner")
        val minor = RfbProtocol.clientMinor(serverMinor)
        send(RfbProtocol.versionString(minor))

        if (minor == 3) {
            if (input.readInt() != 1) throw RfbException("VNC authentication is not supported")
        } else {
            val n = input.readUnsignedByte()
            if (n == 0) throw RfbException("VNC refused connection: ${readString()}")
            val types = ByteArray(n).also { input.readFully(it) }
            if (types.none { it.toInt() == 1 }) throw RfbException("VNC authentication is not supported")
            send(byteArrayOf(1))
            if (minor == 8 && input.readInt() != 0) throw RfbException("VNC security failed: ${readString()}")
        }

        send(byteArrayOf(1)) // ClientInit: shared
        val w = input.readUnsignedShort()
        val h = input.readUnsignedShort()
        input.skipBytes(16) // server pixel format; replaced below
        input.skipBytes(input.readInt()) // desktop name

        send(RfbProtocol.setPixelFormat())
        send(RfbProtocol.setEncodings(intArrayOf(RfbProtocol.ENC_COPY_RECT, RfbProtocol.ENC_RAW, RfbProtocol.ENC_DESKTOP_SIZE)))
        resize(w, h)
        send(RfbProtocol.updateRequest(false, 0, 0, w, h))
    }

    private fun readString(): String {
        val len = input.readInt().coerceIn(0, 4096)
        return String(ByteArray(len).also { input.readFully(it) }, Charsets.UTF_8)
    }

    private fun startReader(s: LocalSocket) {
        reader = Thread({
            try {
                readLoop()
            } catch (_: Exception) {
                // Connection ended or was closed.
            } finally {
                val wasOpen = !closed
                close()
                if (wasOpen) onClosed()
            }
        }, "rfb-reader").apply { isDaemon = true; start() }
    }

    private fun readLoop() {
        while (!closed) {
            when (input.readUnsignedByte()) {
                0 -> readFramebufferUpdate()
                1 -> { // SetColourMapEntries: ignored, true colour is used
                    input.skipBytes(1)
                    input.readUnsignedShort()
                    input.skipBytes(input.readUnsignedShort() * 6)
                }
                2 -> {} // Bell
                3 -> { // ServerCutText
                    input.skipBytes(3)
                    input.skipBytes(input.readInt())
                }
                else -> throw RfbException("Unknown server message")
            }
        }
    }

    private fun readFramebufferUpdate() {
        input.skipBytes(1)
        val rects = input.readUnsignedShort()
        var resized = false
        repeat(rects) {
            val x = input.readUnsignedShort()
            val y = input.readUnsignedShort()
            val w = input.readUnsignedShort()
            val h = input.readUnsignedShort()
            when (val enc = input.readInt()) {
                RfbProtocol.ENC_RAW -> readRaw(x, y, w, h)
                RfbProtocol.ENC_COPY_RECT -> {
                    val sx = input.readUnsignedShort()
                    val sy = input.readUnsignedShort()
                    copyRect(sx, sy, x, y, w, h)
                }
                RfbProtocol.ENC_DESKTOP_SIZE -> { resize(w, h); resized = true }
                else -> throw RfbException("Unsupported encoding $enc")
            }
        }
        draw()
        send(RfbProtocol.updateRequest(!resized, 0, 0, width, height))
    }

    private fun readRaw(x: Int, y: Int, w: Int, h: Int) {
        val row = ByteArray(w * 4)
        for (j in 0 until h) {
            input.readFully(row)
            synchronized(frameLock) {
                if (x + w <= width && y + j < height) {
                    RfbProtocol.bgrxToArgb(row, w, pixels, (y + j) * width + x)
                }
            }
        }
    }

    private fun copyRect(sx: Int, sy: Int, dx: Int, dy: Int, w: Int, h: Int) {
        synchronized(frameLock) {
            if (sx + w > width || dx + w > width || sy + h > height || dy + h > height) return
            val rows = if (dy > sy) (h - 1 downTo 0) else (0 until h)
            for (j in rows) System.arraycopy(pixels, (sy + j) * width + sx, pixels, (dy + j) * width + dx, w)
        }
    }

    private fun resize(w: Int, h: Int) {
        if (w <= 0 || h <= 0) return
        synchronized(frameLock) {
            width = w
            height = h
            pixels = IntArray(w * h)
            bitmap?.recycle()
            bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        }
        onResize(w, h)
    }

    private fun draw() {
        synchronized(frameLock) {
            val bmp = bitmap ?: return
            bmp.setPixels(pixels, 0, width, 0, 0, width, height)
            try {
                val canvas = surface.lockCanvas(Rect(0, 0, width, height))
                try {
                    canvas.drawBitmap(bmp, 0f, 0f, null)
                } finally {
                    surface.unlockCanvasAndPost(canvas)
                }
            } catch (_: Exception) {
                // Surface released or not yet sized; the next frame retries.
            }
        }
    }

    private fun send(bytes: ByteArray) {
        synchronized(writeLock) {
            val out = output ?: throw IOException("Not connected")
            out.write(bytes)
            out.flush()
        }
    }

    /** Sends a pointer event in guest coordinates, clamped to the framebuffer. Returns false if disconnected. */
    fun sendPointer(x: Int, y: Int, buttons: Int): Boolean = trySend(
        RfbProtocol.pointerEvent(buttons, RfbProtocol.clamp(x, width), RfbProtocol.clamp(y, height)),
    )

    /** Sends an X11 keysym press or release. Returns false if disconnected. */
    fun sendKey(keysym: Int, down: Boolean): Boolean = trySend(RfbProtocol.keyEvent(keysym, down))

    private fun trySend(bytes: ByteArray): Boolean = try {
        send(bytes); true
    } catch (_: IOException) {
        false
    }

    /** Writes the current framebuffer as a PNG. Returns false when no frame exists or writing fails. */
    fun screenshot(path: String): Boolean = try {
        synchronized(frameLock) {
            val bmp = bitmap
            if (bmp == null || width == 0) {
                false
            } else {
                bmp.setPixels(pixels, 0, width, 0, 0, width, height)
                val file = File(path)
                file.parentFile?.mkdirs()
                FileOutputStream(file).use { bmp.compress(Bitmap.CompressFormat.PNG, 100, it) }
            }
        }
    } catch (_: Exception) {
        false
    }

    fun close() {
        if (closed) return
        closed = true
        try { socket?.close() } catch (_: IOException) {}
        synchronized(frameLock) {
            bitmap?.recycle()
            bitmap = null
        }
    }
}

/**
 * Handler for the `vm/display` MethodChannel.
 *
 * - `createTexture {id, socketPath?}` -> texture id (Long). The socket path falls back to [socketPathFor].
 * - `sendPointer {id, x, y, buttons}` -> Boolean
 * - `sendKey {id, keysym, down}` -> Boolean
 * - `screenshot {id, path}` -> Boolean
 * - `textureSize {id}` -> `{width, height}`
 * - `disposeTexture {id}` -> null
 *
 * Task 8.10 registers it: `DisplayChannel(registry, resolver).register(messenger)`.
 */
class DisplayChannel(
    private val textures: TextureRegistry,
    private val socketPathFor: (vmId: String) -> String?,
) : MethodChannel.MethodCallHandler {
    companion object {
        const val CHANNEL = "vm/display"
    }

    private class Session(
        val entry: TextureRegistry.SurfaceTextureEntry,
        val surface: Surface,
        val client: RfbClient,
    )

    private val sessions = ConcurrentHashMap<String, Session>()
    private val main = Handler(Looper.getMainLooper())

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<String>("id")
        if (id == null) {
            result.error("bad_args", "Missing id", null)
            return
        }
        when (call.method) {
            "createTexture" -> {
                val path = call.argument<String>("socketPath") ?: socketPathFor(id)
                if (path == null) {
                    result.error("bad_args", "No VNC socket for $id", null)
                    return
                }
                // Texture creation and every Flutter reply must run on the main thread.
                val session = try {
                    open(id, path)
                } catch (e: Exception) {
                    result.error("display_failed", e.message, null)
                    return
                }
                // Connecting can block while QEMU starts, so keep only that part off the main thread.
                Thread({
                    val failure: Exception? = try {
                        session.client.connect()
                        null
                    } catch (e: Exception) {
                        e
                    }
                    main.post {
                        val current = sessions[id]
                        if (current !== session) {
                            session.client.close()
                            result.error("display_failed", "Display was closed while connecting", null)
                        } else if (failure != null) {
                            dispose(id)
                            result.error("display_failed", failure.message, null)
                        } else {
                            result.success(session.entry.id())
                        }
                    }
                }, "rfb-connect").apply { isDaemon = true; start() }
            }
            "sendPointer" -> {
                val c = sessions[id]?.client
                result.success(
                    c != null && c.sendPointer(
                        call.argument<Number>("x")?.toInt() ?: 0,
                        call.argument<Number>("y")?.toInt() ?: 0,
                        call.argument<Number>("buttons")?.toInt() ?: 0,
                    ),
                )
            }
            "sendKey" -> {
                val c = sessions[id]?.client
                val keysym = call.argument<Number>("keysym")?.toInt()
                result.success(c != null && keysym != null && c.sendKey(keysym, call.argument<Boolean>("down") ?: true))
            }
            "screenshot" -> {
                val c = sessions[id]?.client
                val path = call.argument<String>("path")
                result.success(c != null && path != null && c.screenshot(path))
            }
            "textureSize" -> {
                val c = sessions[id]?.client
                if (c == null) result.error("no_session", "No display for $id", null)
                else result.success(mapOf("width" to c.width, "height" to c.height))
            }
            "disposeTexture" -> {
                dispose(id)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /** Creates the texture and an unconnected client. Main thread only. */
    private fun open(id: String, socketPath: String): Session {
        dispose(id)
        val entry = textures.createSurfaceTexture()
        val surface = Surface(entry.surfaceTexture())
        val holder = arrayOfNulls<Session>(1)
        val client = RfbClient(
            socketPath,
            surface,
            // Called from the RFB reader thread; texture calls belong on the main thread.
            onResize = { w, h ->
                main.post {
                    if (holder[0]?.let { sessions[id] === it } == true) {
                        entry.surfaceTexture().setDefaultBufferSize(w, h)
                    }
                }
            },
            onClosed = {
                main.post { holder[0]?.let { if (sessions[id] === it) dispose(id) } }
            },
        )
        val session = Session(entry, surface, client)
        holder[0] = session
        sessions[id] = session
        return session
    }

    fun dispose(id: String) {
        val s = sessions.remove(id) ?: return
        s.client.close()
        s.surface.release()
        s.entry.release()
    }

    fun disposeAll() = sessions.keys.toList().forEach(::dispose)
}
