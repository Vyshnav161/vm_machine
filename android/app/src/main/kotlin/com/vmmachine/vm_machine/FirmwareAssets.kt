package com.vmmachine.vm_machine

import android.content.res.AssetManager
import java.io.File

/**
 * QEMU share directory and UEFI firmware bundled in `assets/qemu` (staged by
 * `tools/build-qemu-android.sh`). The files are copied to the app files directory because QEMU
 * needs real paths for `-L` and `-bios`.
 */
class FirmwareAssets(private val assets: AssetManager) {
    private companion object {
        const val ROOT = "qemu"
    }

    /** Contents of `assets/qemu/VERSION`, or null when no firmware is bundled. */
    fun version(): String? = try {
        assets.open("$ROOT/VERSION").bufferedReader().use { it.readText().trim() }
    } catch (_: Exception) {
        null
    }

    /**
     * Replaces [dest] with the bundled files. Copies into a sibling temp directory first, so an
     * interrupted copy never leaves a half-filled [dest] behind.
     */
    fun extractTo(dest: File) {
        val tmp = File(dest.parentFile, dest.name + ".tmp")
        tmp.deleteRecursively()
        copyDir(ROOT, tmp)
        dest.deleteRecursively()
        if (!tmp.renameTo(dest)) {
            tmp.deleteRecursively()
            throw IllegalStateException("cannot move firmware into ${dest.path}")
        }
    }

    private fun copyDir(assetPath: String, dir: File) {
        dir.mkdirs()
        for (name in assets.list(assetPath).orEmpty()) {
            val child = "$assetPath/$name"
            val sub = assets.list(child).orEmpty()
            if (sub.isNotEmpty()) {
                copyDir(child, File(dir, name))
            } else {
                assets.open(child).use { input ->
                    File(dir, name).outputStream().use { input.copyTo(it) }
                }
            }
        }
    }
}
