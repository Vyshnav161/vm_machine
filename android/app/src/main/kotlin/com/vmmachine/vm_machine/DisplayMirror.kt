package com.vmmachine.vm_machine

import android.app.Presentation
import android.content.Context
import android.hardware.display.DisplayManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Display
import android.view.Gravity
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.WindowManager
import android.widget.FrameLayout

/**
 * Shows the guest display on an external screen (Req 6.8) using [DisplayManager] and a
 * [Presentation].
 *
 * A Flutter texture cannot be attached to a second display, so the mirror opens its own shared
 * RFB connection (QEMU's VNC server accepts several clients) and draws onto a [SurfaceView] inside
 * the presentation. The surface is given the guest resolution and the system scales it to fit.
 *
 * All public methods must be called on the main thread.
 */
class DisplayMirror(
    private val context: Context,
    private val socketPathFor: (vmId: String) -> String?,
    private val onStateChanged: (vmId: String?, mirroring: Boolean) -> Unit = { _, _ -> },
) {
    private val displayManager = context.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
    private val main = Handler(Looper.getMainLooper())

    private var presentation: MirrorPresentation? = null
    private var vmId: String? = null

    private val listener = object : DisplayManager.DisplayListener {
        override fun onDisplayAdded(displayId: Int) {}
        override fun onDisplayChanged(displayId: Int) {}
        override fun onDisplayRemoved(displayId: Int) {
            if (presentation?.display?.displayId == displayId) stop()
        }
    }

    init {
        displayManager.registerDisplayListener(listener, main)
    }

    /** The first presentation-capable display other than the built-in one, or null. */
    fun externalDisplay(): Display? =
        displayManager.getDisplays(DisplayManager.DISPLAY_CATEGORY_PRESENTATION)
            .firstOrNull { it.displayId != Display.DEFAULT_DISPLAY }

    fun isExternalDisplayConnected(): Boolean = externalDisplay() != null

    val isMirroring: Boolean get() = presentation != null

    /** Starts mirroring [id]. Returns false when no external display is connected or no socket exists. */
    fun start(id: String): Boolean {
        val display = externalDisplay() ?: return false
        val path = socketPathFor(id) ?: return false
        stop()
        val p = MirrorPresentation(context, display, path)
        return try {
            p.show()
            presentation = p
            vmId = id
            onStateChanged(id, true)
            true
        } catch (_: WindowManager.InvalidDisplayException) {
            false
        }
    }

    fun stop() {
        val p = presentation ?: return
        val id = vmId
        presentation = null
        vmId = null
        try { p.dismiss() } catch (_: Exception) {}
        onStateChanged(id, false)
    }

    /** Releases the display listener; call when the activity is destroyed. */
    fun dispose() {
        stop()
        displayManager.unregisterDisplayListener(listener)
    }

    private class MirrorPresentation(
        outer: Context,
        display: Display,
        private val socketPath: String,
    ) : Presentation(outer, display) {
        private val ui = Handler(Looper.getMainLooper())
        private var client: RfbClient? = null
        private lateinit var surfaceView: SurfaceView

        override fun onCreate(savedInstanceState: Bundle?) {
            super.onCreate(savedInstanceState)
            surfaceView = SurfaceView(context)
            surfaceView.holder.addCallback(object : SurfaceHolder.Callback {
                override fun surfaceCreated(holder: SurfaceHolder) = connect(holder)
                override fun surfaceChanged(holder: SurfaceHolder, format: Int, w: Int, h: Int) {}
                override fun surfaceDestroyed(holder: SurfaceHolder) = disconnect()
            })
            setContentView(
                FrameLayout(context).apply {
                    setBackgroundColor(0xFF000000.toInt())
                    addView(
                        surfaceView,
                        FrameLayout.LayoutParams(
                            FrameLayout.LayoutParams.MATCH_PARENT,
                            FrameLayout.LayoutParams.MATCH_PARENT,
                            Gravity.CENTER,
                        ),
                    )
                },
            )
        }

        private fun connect(holder: SurfaceHolder) {
            val c = RfbClient(
                socketPath,
                holder.surface,
                onResize = { w, h -> ui.post { holder.setFixedSize(w, h) } },
            )
            client = c
            // Connecting can block while QEMU starts, so keep it off the main thread.
            Thread({
                try {
                    c.connect()
                } catch (_: Exception) {
                    c.close()
                }
            }, "rfb-mirror").apply { isDaemon = true; start() }
        }

        private fun disconnect() {
            client?.close()
            client = null
        }

        override fun onStop() {
            disconnect()
            super.onStop()
        }
    }
}
